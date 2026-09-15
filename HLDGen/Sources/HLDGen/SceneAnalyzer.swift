import Foundation

/// Everything discoverable about one function body: what it calls, one level of indirection resolved.
private struct CallInfo {
    var services: [(serviceOrVar: String, method: String)] = []
    var workers: [(varName: String, method: String)] = []
    var routes: [String] = []
}

/// Resolves calls made by `functionName`, following plain same-file helper calls (e.g. a public method that
/// just delegates to a private `callFoo()`) up to `maxDepth` levels deep. This is the one deliberate improvement
/// over analyze_ios.py's single-level lookup: this codebase's Interactors very commonly do
/// `func getX() { ...; callX() }` / `private func callX() { service.execute(...) }`, and without following that
/// hop, the VC-action -> service-call chain silently comes back empty.
private func resolveCalls(
    functionName: String,
    allFunctions: [String: String],
    visited: inout Set<String>,
    depth: Int = 0,
    maxDepth: Int = 3
) -> CallInfo {
    var info = CallInfo()
    guard depth <= maxDepth, !visited.contains(functionName), let body = allFunctions[functionName] else { return info }
    visited.insert(functionName)

    info.services.append(contentsOf: extractServiceCalls(body))
    info.workers.append(contentsOf: extractWorkerCalls(body))
    info.routes.append(contentsOf: extractRouteCalls(body))

    // Follow any bare `helperName(` call that resolves to another function in this same file.
    for m in body.matches(#"\b(\w+)\s*\("#) {
        let callee = m[1]
        guard callee != functionName, allFunctions[callee] != nil, !visited.contains(callee) else { continue }
        let nested = resolveCalls(functionName: callee, allFunctions: allFunctions, visited: &visited, depth: depth + 1, maxDepth: maxDepth)
        info.services.append(contentsOf: nested.services)
        info.workers.append(contentsOf: nested.workers)
        info.routes.append(contentsOf: nested.routes)
    }
    return info
}

/// Dispatches to the appropriate architecture analyzer based on what files are found in sceneDir,
/// then falls through to the CleanSwift implementation for VIP scenes.
func analyzeScene(module: String, sceneName: String, sceneDir: URL, serviceEndpoints: [String: ApiEndpoint],
                   flowBindings: [FlowScreenBinding] = []) -> SceneResult {
    let arch = detectArchitecture(in: sceneDir)
    switch arch {
    case .mvc:
        return analyzeMVC(module: module, sceneName: sceneName, sceneDir: sceneDir, serviceEndpoints: serviceEndpoints)
    case .mvvm:
        return analyzeMVVM(module: module, sceneName: sceneName, sceneDir: sceneDir, serviceEndpoints: serviceEndpoints)
    case .swiftUI:
        return analyzeSwiftUI(module: module, sceneName: sceneName, sceneDir: sceneDir, serviceEndpoints: serviceEndpoints)
    case .cleanSwift, .unknown:
        break  // fall through to existing CleanSwift implementation below
    }
    return analyzeCleanSwift(module: module, sceneName: sceneName, sceneDir: sceneDir,
                              serviceEndpoints: serviceEndpoints, flowBindings: flowBindings)
}

/// CleanSwift/VIP scene analyzer (original implementation).
/// Parses *ViewController, *Interactor, *Router, *Presenter, *Worker + storyboard/xib.
private func analyzeCleanSwift(module: String, sceneName: String, sceneDir: URL, serviceEndpoints: [String: ApiEndpoint],
                   flowBindings: [FlowScreenBinding] = []) -> SceneResult {
    var viewControllers: Set<String> = []
    var interactors: Set<String> = []
    var presenters: Set<String> = []
    var routers: Set<String> = []
    var workers: Set<String> = []
    var routesTo: Set<String> = []
    var servicesUsed: Set<String> = []

    var interactorFunctions: [String: String] = [:] // funcName -> body, across all Interactor/Worker files
    // Stored-property service instances, e.g. `private var fooService = SomeService()` — this codebase's most
    // common pattern of all, and one a per-function-body scan can never see since the declaration lives at
    // class scope, not inside any single function. Scanned once per file, applied wherever a call site uses
    // the property name instead of the class name directly.
    var propertyServiceMap: [String: String] = [:]
    let swiftFiles = findSceneFiles(under: sceneDir, extensions: ["swift"])

    for file in swiftFiles {
        let fname = file.lastPathComponent
        let src = readFile(file)

        if fname.contains("ViewController") || fname.contains("VC") {
            viewControllers.formUnion(src.matches(#"class\s+(\w+(?:ViewController|VC))\b"#).map { $0[1] })
        }
        if fname.contains("Interactor") {
            interactors.formUnion(src.matches(#"class\s+(\w+Interactor)\b"#).map { $0[1] })
            workers.formUnion(src.matches(#"(\w+Worker)\b"#).map { $0[1] })
            for fn in extractFunctionBodies(src) { interactorFunctions[fn.name] = fn.body }
            for m in src.matches(#"(?:var|let)\s+(\w+)\s*:\s*(\w+Service)\b"#) { propertyServiceMap[m[1]] = m[2] }
            for m in src.matches(#"(?:var|let)\s+(\w+)\s*=\s*(\w+Service)\s*\("#) { propertyServiceMap[m[1]] = m[2] }
        }
        if fname.contains("Presenter") {
            presenters.formUnion(src.matches(#"class\s+(\w+Presenter)\b"#).map { $0[1] })
        }
        if fname.contains("Router") && !fname.contains("Routing") {
            routers.formUnion(src.matches(#"class\s+(\w+Router)\b"#).map { $0[1] })
            routesTo.formUnion(src.matches(#"func\s+routeTo(\w+)\b"#).map { $0[1] })
        }
        if fname.contains("Worker") {
            servicesUsed.formUnion(src.matches(#"(\w+Service)\b(?!\s*\{)"#).map { $0[1] })
            for fn in extractFunctionBodies(src) { interactorFunctions[fn.name] = fn.body }
        }
    }

    // Merge every case->destination map from Flow bindings whose VC class this scene actually defines —
    // that's the cross-file join that lets an Output-emitting action resolve to a real destination screen.
    var caseToDestination: [String: String] = [:]
    for binding in flowBindings where viewControllers.contains(binding.vcClass) {
        for c in binding.cases {
            for name in c.caseNames { caseToDestination[name] = c.destinationHint }
        }
    }

    func resolvedClassName(_ raw: String) -> String { propertyServiceMap[raw] ?? raw }

    func resolveInteractorCalls(_ icMethods: [String]) -> ([ResolvedInteractorCall], [String]) {
        var resolved: [ResolvedInteractorCall] = []
        var services: [String] = []
        for icMethod in icMethods {
            var visited = Set<String>()
            let info = resolveCalls(functionName: icMethod, allFunctions: interactorFunctions, visited: &visited)
            let directServices = info.services.map { "\(resolvedClassName($0.serviceOrVar)).\($0.method)" }
            var workerEntries: [ResolvedWorkerCall] = []
            for (workerVar, workerMethod) in info.workers {
                var wVisited = Set<String>()
                let wInfo = resolveCalls(functionName: workerMethod, allFunctions: interactorFunctions, visited: &wVisited)
                workerEntries.append(ResolvedWorkerCall(call: "\(workerVar).\(workerMethod)",
                                                         services: wInfo.services.map { "\(resolvedClassName($0.serviceOrVar)).\($0.method)" }))
            }
            resolved.append(ResolvedInteractorCall(interactorMethod: icMethod, services: directServices,
                                                    workers: workerEntries, routes: info.routes))
            services.append(contentsOf: info.services.map { resolvedClassName($0.serviceOrVar) })
        }
        return (resolved, services)
    }

    func makeActionChain(action: String, kind: String, file: String, body: String) -> ActionChain? {
        let icMethods = extractInteractorCalls(body)
        let vcRoutes = extractRouteCalls(body)
        let emittedCases = extractEmittedCaseTokens(body)
        guard !icMethods.isEmpty || !vcRoutes.isEmpty || !emittedCases.isEmpty else { return nil }

        let (resolved, services) = resolveInteractorCalls(icMethods)
        servicesUsed.formUnion(services)
        var seenDest = Set<String>()
        let resolvedDestinations = emittedCases.compactMap { caseToDestination[$0] }.filter { seenDest.insert($0).inserted }
        return ActionChain(action: action, kind: kind, file: file, calls: resolved, vcRoutes: vcRoutes,
                            emittedCases: emittedCases, resolvedDestinations: resolvedDestinations)
    }

    var actionChains: [ActionChain] = []
    for file in swiftFiles {
        let fname = file.lastPathComponent
        if fname.contains("Interactor") || fname.contains("Worker") || fname.contains("Presenter") { continue }
        let src = readFile(file)
        let rel = file.path

        // Pass 1: every function on the VC — not just @IBAction/@objc. Plenty of real entry points here are
        // plain protocol/delegate callbacks (e.g. a QR-scanner delegate's `onQRCodeDetected`), invisible to a
        // target-action-only scan. makeActionChain() still discards anything with no interactor/route/case
        // signal, so this mainly adds genuine triggers rather than every private helper.
        for fn in extractFunctionBodies(src) {
            if let chain = makeActionChain(action: fn.name, kind: fn.kind, file: rel, body: fn.body) {
                actionChains.append(chain)
            }
        }

        // Pass 2: RxSwift-bound controls (`someButton.rx.tap`, `.rx.modelSelected(...)`, `.rx.controlEvent(...)`)
        // — the dominant action-wiring pattern in this codebase, and invisible to a plain @IBAction/@objc scan.
        // Each occurrence's body is windowed from the match up to its `.disposed(by:` (or a line cap) and fed
        // through the same call-extraction as a real function body.
        let ns = src as NSString
        if let re = try? NSRegularExpression(pattern: #"(\w+)\.rx\.(tap\b|modelSelected|controlEvent)"#) {
            for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let owner = ns.substring(with: m.range(at: 1))
                let kindWord = ns.substring(with: m.range(at: 2))
                let start = m.range.location
                let disposedRange = ns.range(of: ".disposed(by:", options: [], range: NSRange(location: start, length: ns.length - start))
                let cap = 4000
                let end = disposedRange.location != NSNotFound
                    ? min(disposedRange.location + disposedRange.length, start + cap)
                    : min(start + cap, ns.length)
                let body = ns.substring(with: NSRange(location: start, length: end - start))
                if let chain = makeActionChain(action: "\(owner).rx.\(kindWord)", kind: "rxBinding", file: rel, body: body) {
                    actionChains.append(chain)
                }
            }
        }
    }

    let resolvedEndpoints = servicesUsed.compactMap { serviceEndpoints[$0] }

    return SceneResult(
        id: "\(module)/\(sceneName)", name: sceneName, module: module,
        viewControllers: viewControllers.sorted(), interactors: interactors.sorted(),
        presenters: presenters.sorted(), routers: routers.sorted(), workers: workers.sorted(),
        routesTo: routesTo.sorted(), servicesUsed: servicesUsed.sorted(),
        actionChains: actionChains, xibs: parseSceneStoryboards(in: sceneDir),
        apiEndpoints: resolvedEndpoints
    )
}
