#!/bin/bash
set -euo pipefail
VERSION="${1:-0.0.0-dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if swift build -c release --arch arm64 --arch x86_64 --product Motas 2>/tmp/motas-universal-err.log; then
    BINARY=".build/apple/Products/Release/Motas"
else
    echo "warning: universal build failed (xcbuild missing under CLT); falling back to host arch (arm64 only)" >&2
    tail -5 /tmp/motas-universal-err.log >&2 || true
    swift build -c release --product Motas
    BINARY="$(swift build -c release --show-bin-path)/Motas"
fi

rm -rf dist/Motas.app
mkdir -p dist/Motas.app/Contents/MacOS dist/Motas.app/Contents/Resources
cp "$BINARY" dist/Motas.app/Contents/MacOS/Motas

cat > dist/Motas.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.motas.app</string>
    <key>CFBundleName</key>
    <string>Motas</string>
    <key>CFBundleExecutable</key>
    <string>Motas</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 dinhkarate. MIT licensed.</string>
</dict>
</plist>
EOF
plutil -lint dist/Motas.app/Contents/Info.plist

if [ ! -f dist/AppIcon.icns ]; then
    scripts/make-icon.sh
fi
cp dist/AppIcon.icns dist/Motas.app/Contents/Resources/

codesign --force --options runtime --timestamp=none --sign - dist/Motas.app
codesign --verify --strict dist/Motas.app
echo "built dist/Motas.app ($VERSION)"
