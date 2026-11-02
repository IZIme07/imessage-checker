#!/bin/zsh
# Builds "iMessage Checker.app" next to this script.
set -e
cd "$(dirname "$0")"

APP="iMessage Checker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macos14 Sources/main.swift -o "$APP/Contents/MacOS/iMessageChecker"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>iMessage Checker</string>
    <key>CFBundleDisplayName</key><string>iMessage Checker</string>
    <key>CFBundleIdentifier</key><string>local.imessagechecker</string>
    <key>CFBundleExecutable</key><string>iMessageChecker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
