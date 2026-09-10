#!/bin/bash
# Builds ClaudeUsage.app. Pass --install to replace the copy in /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeUsage"
BUNDLE_ID="com.claudeusage.menubar"
STAGE="build/${APP_NAME}.app"

swift build -c release --product "$APP_NAME"

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp ".build/release/$APP_NAME" "$STAGE/Contents/MacOS/$APP_NAME"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock tile, no app switcher entry. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a stable keychain identity across rebuilds, so
# macOS does not re-prompt for access every time the app is rebuilt.
codesign --force --deep --sign - "$STAGE" 2>/dev/null || \
    echo "warning: could not codesign; macOS may re-prompt for keychain access"

echo "built $STAGE"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$STAGE" "/Applications/${APP_NAME}.app"
    echo "installed /Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
    echo "launched"
fi
