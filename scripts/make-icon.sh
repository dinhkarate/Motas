#!/bin/bash
# Renders the app icon and packs dist/AppIcon.icns.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
OUT="${1:-dist/AppIcon-1024.png}"
mkdir -p dist
swift scripts/dev/make-icon.swift "$OUT"

rm -rf dist/AppIcon.iconset
mkdir -p dist/AppIcon.iconset
for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -z $s $s "$OUT" --out "dist/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $d $d "$OUT" --out "dist/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns dist/AppIcon.iconset -o dist/AppIcon.icns
echo "wrote dist/AppIcon.icns"
