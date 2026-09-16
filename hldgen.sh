#!/usr/bin/env bash
# Usage: ./Tools/hldgen.sh <ModuleDir> [-o output.json]
# Example: ./Tools/hldgen.sh Calendar
# Example: ./Tools/hldgen.sh Calendar -o Tools/bundle.json
#
# Auto-discovers: scene dirs, API router, API service dir, flow file.
# Run from repo root.

set -euo pipefail

MODULE_DIR="${1:?Usage: $0 <ModuleDir> [-o output.json]}"
shift
OUTPUT="/tmp/hld_bundle.json"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUTPUT="${2:?-o needs a path}"; shift 2 ;;
    *)  echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Module name = last path component without trailing slash
MODULE_NAME="$(basename "$MODULE_DIR")"

# Package path is resolved from this script's own location, so the checkout can be named
# anything (Tools/, PaotangPay/HLDGen/, …) without the caller passing a path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$SCRIPT_DIR/HLDGen"

# ── Build tool (fast no-op if already built) ─────────────────────────────────
swift build --package-path "$PKG" 2>&1 | tail -2

# ── Auto-discover scene dirs ──────────────────────────────────────────────────
# Prefer <Module>/<Module>/Scenes/ (CleanSwift), fall back to whole module dir (MVC/MVVM/SwiftUI)
SCENE_ROOT="$MODULE_DIR/$MODULE_NAME/Scenes"
if [ ! -d "$SCENE_ROOT" ]; then
  # No Scenes/ folder — treat whole module dir as one "scene"
  SCENE_ROOT="$MODULE_DIR"
  echo "No Scenes/ folder found — scanning $SCENE_ROOT directly"
fi

# One scene = one directory holding a *ViewController.swift. Nested folders each count separately:
# a container like Scenes/Home holds its own VC *and* a subfolder per sibling screen, and collapsing
# those into one entry is what turns ten screens into a single unreadable card.
# Read line-by-line (never `$( )` word-splitting) so directory names containing spaces survive.
SCENE_DIRS=()
while IFS= read -r d; do
  SCENE_DIRS+=("$d")
done < <(find "$SCENE_ROOT" -name "*ViewController.swift" -exec dirname {} \; | sort -u)

# SwiftUI / MVVM modules have no ViewControllers — fall back to View / ViewModel files
if [ ${#SCENE_DIRS[@]} -eq 0 ]; then
  while IFS= read -r d; do
    SCENE_DIRS+=("$d")
  done < <(find "$SCENE_ROOT" \( -name "*ViewModel.swift" -o -name "*View.swift" \) -exec dirname {} \; | sort -u)
fi

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
ROUTER="$(find "$API_BASE" -maxdepth 1 -name "*Router.swift" 2>/dev/null | head -1 || true)"
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
FLOW_FILE="$(find "$FLOW_DIR" -maxdepth 1 -name "*.swift" 2>/dev/null | head -1 || true)"
if [ -n "$FLOW_FILE" ]; then
  FLOW_FLAGS+=(--flow-file "$FLOW_FILE")
  echo "Flow file:  $FLOW_FILE"
else
  echo "No flow file found (skipping --flow-file)"
fi

# ── Run ───────────────────────────────────────────────────────────────────────
echo ""
echo "Generating → $OUTPUT"
swift run --package-path "$PKG" hldgen \
  "${SCENE_DIRS[@]}" \
  --module "$MODULE_NAME" \
  "${API_FLAGS[@]}" \
  "${FLOW_FLAGS[@]}" \
  -o "$OUTPUT"

echo ""
echo "✓ Done: $OUTPUT"
echo "  Paste into Figma plugin (Plugins → Development → HLDGen Scene Importer)"

# ── Keep the host repo clean ─────────────────────────────────────────────────
# Both the generated bundle and this checkout itself (~50MB once .build exists) are
# throwaway, so neither should ever end up in the host repo's history.
GITIGNORE=".gitignore"
IGNORE_ENTRIES=("$(basename "$OUTPUT")")

# The checkout's path relative to the repo root, when it sits inside this repo at all
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
case "$SCRIPT_DIR/" in
  # Leading slash anchors the pattern, so a bare `Tools/` cannot also swallow
  # an unrelated `SomeModule/Tools/` elsewhere in the repo.
  "$REPO_ROOT"/*) IGNORE_ENTRIES+=("/${SCRIPT_DIR#"$REPO_ROOT"/}/") ;;
esac

if [ -n "$REPO_ROOT" ] && [ -f "$GITIGNORE" ]; then
  for entry in "${IGNORE_ENTRIES[@]}"; do
    grep -qxF "$entry" "$GITIGNORE" && continue
    printf '\n# HLDGen\n%s\n' "$entry" >> "$GITIGNORE"
    echo "  Added '$entry' to .gitignore"
  done
fi
