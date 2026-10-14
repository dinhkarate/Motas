#!/bin/bash
# Builds Motas.app (with the widget extension) using SwiftPM only — no Xcode.
#
#   scripts/build-app.sh [VERSION]
#   MOTAS_BUNDLE_ID=dev.motas.widgettest MOTAS_OUT=dist/test scripts/build-app.sh   # side-by-side test build
set -euo pipefail
VERSION="${1:-0.0.0-dev}"
BUNDLE_ID="${MOTAS_BUNDLE_ID:-dev.motas.app}"
OUT="${MOTAS_OUT:-dist}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

swift build -c release --product Motas
swift build -c release --product MotasWidget
BIN="$(swift build -c release --show-bin-path)"

APP="$OUT/Motas.app"
APPEX="$APP/Contents/PlugIns/MotasWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$BIN/Motas" "$APP/Contents/MacOS/Motas"
cp "$BIN/MotasWidget" "$APPEX/Contents/MacOS/MotasWidget"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Motas</string>
    <key>CFBundleDisplayName</key><string>Motas</string>
    <key>CFBundleExecutable</key><string>Motas</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 dinhkarate. MIT licensed.</string>
</dict>
</plist>
EOF

cat > "$APPEX/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}.widget</string>
    <key>CFBundleName</key><string>MotasWidget</string>
    <key>CFBundleDisplayName</key><string>Motas</string>
    <key>CFBundleExecutable</key><string>MotasWidget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist" >/dev/null

if [ ! -f dist/AppIcon.icns ]; then
    scripts/make-icon.sh
fi
cp dist/AppIcon.icns "$APP/Contents/Resources/"

# Sign inside-out: extension first (sandboxed, app group), then the app.
codesign --force --options runtime --timestamp=none --sign - \
    --entitlements packaging/entitlements/widget.entitlements "$APPEX"
codesign --force --options runtime --timestamp=none --sign - \
    --entitlements packaging/entitlements/app.entitlements "$APP"
codesign --verify --strict --deep "$APP"
echo "built $APP ($VERSION, $BUNDLE_ID)"
