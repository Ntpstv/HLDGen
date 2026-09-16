# HLDGen

Automated High-Level Design (HLD) generator for iOS projects.  
Analyzes Swift source code and generates a Figma canvas with screens, stickies, API clouds, and arrows — in minutes, not hours.

Supports **CleanSwift / VIP**, **MVC**, **MVVM**, and **SwiftUI** architectures.

---

## How to Use

### Step 1 — Clone the tools into your project

```bash
git clone https://github.com/Ntpstv/HLDGen.git Tools
```

Run this once from your project root. The `Tools/` folder is safe to add to `.gitignore`.

---

### Step 2 — Run the analyzer

```bash
bash Tools/hldgen.sh <ModuleDir> -o Tools/bundle.json
```

`<ModuleDir>` is your module folder — `Calendar`, `PaotangPay`, `tungngern-ios`.
That is the only thing you supply. The script finds every screen in the module, the
module name, and the API router on its own, then builds and runs the analyzer.

**Example:**
```bash
bash Tools/hldgen.sh PaotangPay -o Tools/bundle.json
```
```
Found 99 scene(s)
API router: PaotangPay/PaotangPay/API/PTPRouter.swift
wrote 99 scene(s) → Tools/bundle.json
```

<details>
<summary>Running the analyzer directly, without the script</summary>

Every screen directory has to be listed explicitly — one directory produces one screen,
so passing a parent folder gives you a single card instead of the whole module:

```bash
swift run --package-path Tools/HLDGen hldgen \
  <sceneDir> [<sceneDir> ...] \
  --module <ModuleName> \
  -o Tools/bundle.json
```

Type `--module` by hand rather than pasting it from a slide or doc — editors turn
a double hyphen into an en dash, and `—module` fails with an unhelpful error.
</details>

---

### Step 3 — Load the plugin in Figma

The plugin is not on the Figma marketplace, so load it from disk. This needs the
**Figma desktop app** — the browser version has no Development menu.

1. Figma desktop → **menu → Plugins → Development → Import plugin from manifest…**
2. Choose `Tools/HLDFigmaPlugin/manifest.json`

One time only. After that it lives under **Plugins → Development → HLDGen Scene Importer**.

---

### Step 4 — Generate

1. Run **Plugins → Development → HLDGen Scene Importer**
2. Paste the contents of `Tools/bundle.json`
3. Click **Generate**

Your canvas now holds one card per screen, grouped into labelled journeys, with
sticky notes for each action, API clouds, and arrows between screens in the same journey.

Re-running clears the previous output first, so the board never stacks two generations
on top of each other. Anything you drew on the page yourself is left alone.

---

## Requirements

- Xcode with Swift toolchain
- Figma **desktop app** (free account is fine — the browser version cannot load local plugins)

## Repository Structure

```
Tools/
├── HLDGen/          # Swift package — the analyzer
│   └── Sources/HLDGen/
├── HLDFigmaPlugin/  # Figma plugin
│   ├── code.js
│   └── ui.html
└── hldgen.sh        # Optional convenience wrapper script
```
