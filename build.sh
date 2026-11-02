#!/bin/zsh
# Builds "iMessage Checker.app" (universal: Apple Silicon + Intel) next to this script.
# VERSION env var overrides the VERSION file.
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-$(cat VERSION)}"
APP="iMessage Checker.app"
BUILD=".build"
rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target $arch-apple-macos14 Sources/main.swift -o "$BUILD/iMessageChecker-$arch"
done
lipo -create "$BUILD"/iMessageChecker-* -output "$APP/Contents/MacOS/iMessageChecker"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>iMessage Checker</string>
    <key>CFBundleDisplayName</key><string>iMessage Checker</string>
    <key>CFBundleIdentifier</key><string>local.imessagechecker</string>
    <key>CFBundleExecutable</key><string>iMessageChecker</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP ($VERSION)"
