# hldgen

A Swift static analyzer for this monorepo's CleanSwift/VIP scenes. Given one scene directory, it produces a
structured JSON description of: the scene's components (ViewController/Interactor/Presenter/Router), its
storyboard/xib UI tree (real positions and labels, parsed straight from the IB XML — not guessed), every
button/row/delegate-callback action found and what it calls, and — when given the module's API router file —
the concrete backend endpoint (path + HTTP method) each action resolves to.

It exists so "explain this screen to a new engineer" doesn't require a human (or an LLM) to re-read and
re-trace the same Swift source from scratch every time. Run it, get ground-truth JSON, build whatever
documentation/diagram you want on top — see `.claude/skills/ios-hld/SKILL.md` for the paired Claude Code skill
that turns this into a rendered HLD.

## Build & run

```bash
cd Tools/HLDGen
swift build
```

```bash
swift run --package-path Tools/HLDGen hldgen \
  PTPassModule/PTPassModule/Scenes/PTPassHome/Home --module PTPassModule \
  --api-dir PTPassModule/PTPassModule/API/Service \
  --api-router PTPassModule/PTPassModule/API/PTPassRouter.swift \
  --flow-file PTPassModule/PTPassModule/Flow/PTPassHomeFlow.swift \
  -o /tmp/ptpass_home.json
```

All paths are relative to wherever you run the command from (typically the monorepo root). Only `<sceneDir>`
and `--module` are required — the other three flags each unlock one more layer of resolution:

| Flag | Unlocks |
|---|---|
| *(none)* | Components, storyboard UI tree, raw action list, `router?.routeToX()` calls made directly in the scene. |
| `--flow-file` | Resolves actions that only emit an Output enum case (`onRouteNext.onNext(.X)`) to the real destination screen, by parsing the sibling `Flow/*.swift` coordinator's `switch model.caseOutput` and `showNext(type:)` calls. |
| `--api-dir` + `--api-router` | Resolves every `SomeService` used by this scene to a concrete `path` + HTTP method, by joining `Service.swift → <Router>.<case>(` → the router's `static func <case>() -> ApiModel { return X(path: "...", method: .x) }`. |

## What it actually understands

This targets the idioms actually used across `PTPassModule` (and, per a scan of `KPayCustomerEkycService`, the
wider app): `@IBAction`/`@objc` target-actions, RxSwift `.rx.tap` / `.rx.modelSelected(...)` / `.rx.controlEvent(...)`
bindings, plain delegate-callback methods (`onQRCodeDetected(qrVal:)` and friends), service calls via a stored
property (`private var fooService = SomeService()`), a local `let`/`var`, or inline instantiation
(`SomeService().execute(...)`), and up to 3 hops of same-file helper-function delegation (`func getX() { callX() }`).

## Known limitations (v1 — deliberately scoped)

- **One scene at a time.** It does not walk all ~145 scenes in the monorepo in one pass, and doesn't build a
  cross-module route graph. Call it once per scene you want documented.
- **Regex/brace-counting, not a real Swift parser.** Same trade-off `wiki/tools/analyze_ios.py` (a Python
  prototype of this same idea, on branch `cop/wiki-fe`) made — fast and dependency-free, but it can be fooled by
  sufficiently unusual formatting. Validated against `PTPassModule/Scenes/PTPassHome/Home` and `.../QRScanner`
  against hand-verified ground truth; not yet run against the rest of the monorepo.
- **Flow-case resolution assumes the `switch model.caseOutput { case .X: ...; showNext(type: Y.self) }` shape.**
  Flows that branch differently (a nested flow object, a directly-called router method instead of `showNext`)
  will show up as `vcRoutes` (if the scene calls `router?.routeToX()` itself) or as an unresolved `emittedCases`
  entry (if the destination truly only lives in the Flow and doesn't match the regex) rather than a wrong answer —
  it will not fabricate a destination it can't find.
- **No deeplink, request-model-field, or stubby-mock analysis** — the Python prototype has all three; this port
  intentionally left them out of scope to keep this one useful without becoming another 1700-line file. Worth
  porting later if the skill's output proves the concept.
