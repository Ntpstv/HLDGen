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
swift run --package-path Tools/HLDGen hldgen <ModuleDir> \
  --module <ModuleName> \
  -o Tools/bundle.json
```

**Replace:**
- `<ModuleDir>` — path to your module folder (e.g. `Calendar`, `PTPass/PTPass`)
- `<ModuleName>` — your module name (e.g. `CalendarApp`, `PTPass`)

**Example (CalendarApp):**
```bash
swift run --package-path Tools/HLDGen hldgen Calendar \
  --module CalendarApp \
  -o Tools/bundle.json
```

---

### Step 3 — Open Figma plugin

1. Open Figma
2. Go to **Plugins → HLDFigmaPlugin**
3. Paste the contents of `Tools/bundle.json`
4. Click **Generate**

---

### Step 4 — Done

Your Figma canvas is ready with screens, stickies, API clouds, and arrows.

---

## Requirements

- Xcode with Swift toolchain
- Figma (free account is enough)

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
