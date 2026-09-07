#!/usr/bin/env bash
# Usage: ./Tools/hldgen.sh <ModuleDir> [-o output.json]
# Example: ./Tools/hldgen.sh PTPassModule
# Example: ./Tools/hldgen.sh PTPassModule -o /tmp/ptpass.json
#
# Auto-discovers: scene dirs, API router, API service dir, flow file.
# Run from repo root.

set -euo pipefail

MODULE_DIR="${1:?Usage: $0 <ModuleDir> [-o output.json]}"
OUTPUT="${3:-/tmp/hld_bundle.json}"

# Module name = last path component without trailing slash
MODULE_NAME="$(basename "$MODULE_DIR")"

# ── Build tool (fast no-op if already built) ─────────────────────────────────
swift build -c release --package-path Tools/HLDGen 2>&1 | tail -2

# ── Auto-discover scene dirs ──────────────────────────────────────────────────
# Prefer <Module>/<Module>/Scenes/ (CleanSwift), fall back to whole module dir (MVC/MVVM/SwiftUI)
SCENE_ROOT="$MODULE_DIR/$MODULE_NAME/Scenes"
if [ ! -d "$SCENE_ROOT" ]; then
  # No Scenes/ folder — treat whole module dir as one "scene"
  SCENE_ROOT="$MODULE_DIR"
  echo "No Scenes/ folder found — scanning $SCENE_ROOT directly"
fi

SCENE_DIRS=()
while IFS= read -r vc; do
  SCENE_DIRS+=("$(dirname "$vc")")
done < <(find "$SCENE_ROOT" -maxdepth 4 -name "*ViewController.swift" -o -name "*ViewModel.swift" -o -name "*View.swift" | sort | uniq)

# Deduplicate dirs
SCENE_DIRS=($(printf '%s\n' "${SCENE_DIRS[@]}" | sort -u))

if [ ${#SCENE_DIRS[@]} -eq 0 ]; then
  # Last resort: pass the module dir itself
  SCENE_DIRS=("$MODULE_DIR")
  echo "No ViewController/ViewModel found — passing $MODULE_DIR as scene"
fi

echo "Found ${#SCENE_DIRS[@]} scene(s):"
for s in "${SCENE_DIRS[@]}"; do echo "  $s"; done

# ── Auto-discover API router ──────────────────────────────────────────────────
API_FLAGS=()
API_BASE="$MODULE_DIR/$MODULE_NAME/API"
ROUTER="$(find "$API_BASE" -maxdepth 1 -name "*Router.swift" 2>/dev/null | head -1)"
if [ -n "$ROUTER" ]; then
  API_FLAGS+=(--api-router "$ROUTER")
  # Service dir: prefer API/Service, else API itself
  if [ -d "$API_BASE/Service" ]; then
    API_FLAGS+=(--api-dir "$API_BASE/Service")
  else
    API_FLAGS+=(--api-dir "$API_BASE")
  fi
  echo "API router: $ROUTER"
else
  echo "No API router found (skipping --api-router)"
fi

# ── Auto-discover flow file ───────────────────────────────────────────────────
FLOW_FLAGS=()
FLOW_DIR="$MODULE_DIR/$MODULE_NAME/Flow"
FLOW_FILE="$(find "$FLOW_DIR" -maxdepth 1 -name "*.swift" 2>/dev/null | head -1)"
if [ -n "$FLOW_FILE" ]; then
  FLOW_FLAGS+=(--flow-file "$FLOW_FILE")
  echo "Flow file:  $FLOW_FILE"
else
  echo "No flow file found (skipping --flow-file)"
fi

# ── Run ───────────────────────────────────────────────────────────────────────
echo ""
echo "Generating → $OUTPUT"
swift run --package-path Tools/HLDGen hldgen \
  "${SCENE_DIRS[@]}" \
  --module "$MODULE_NAME" \
  "${API_FLAGS[@]}" \
  "${FLOW_FLAGS[@]}" \
  -o "$OUTPUT"

echo ""
echo "✓ Done: $OUTPUT"
echo "  Paste into Figma plugin (Plugins → Development → HLDGen Scene Importer)"

# ── Auto-add output file to .gitignore ───────────────────────────────────────
OUTPUT_BASENAME="$(basename "$OUTPUT")"
GITIGNORE=".gitignore"
if [ -f "$GITIGNORE" ] && ! grep -qF "$OUTPUT_BASENAME" "$GITIGNORE"; then
  echo "" >> "$GITIGNORE"
  echo "# HLDGen output" >> "$GITIGNORE"
  echo "$OUTPUT_BASENAME" >> "$GITIGNORE"
  echo "  Added '$OUTPUT_BASENAME' to .gitignore"
fi
