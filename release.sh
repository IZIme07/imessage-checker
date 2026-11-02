#!/bin/zsh
# Publishes a GitHub release for the version in VERSION:
#   iMessage-Checker-<v>.dmg      — for users (drag to Applications)
#   iMessage-Checker-<v>.zip/.sig — for the in-app updater (Ed25519-signed)
# Needs: gh (logged in) and the signing key from `swift Scripts/sign-update.swift generate`.
set -e
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
TAG="v$VERSION"
NAME="iMessage-Checker-$VERSION"

[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first"; exit 1; }
git push -q origin HEAD

./build.sh
rm -rf dist && mkdir -p dist/dmg

ditto -c -k --keepParent "iMessage Checker.app" "dist/$NAME.zip"
swift Scripts/sign-update.swift sign "dist/$NAME.zip" > "dist/$NAME.zip.sig"

ditto "iMessage Checker.app" "dist/dmg/iMessage Checker.app"
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "iMessage Checker" -srcfolder dist/dmg -ov -format UDZO "dist/$NAME.dmg"

gh release create "$TAG" "dist/$NAME.dmg" "dist/$NAME.zip" "dist/$NAME.zip.sig" \
    --title "iMessage Checker $VERSION" --notes-file - <<NOTES
Скачайте **$NAME.dmg**, откройте и перетащите iMessage Checker в «Программы».

При первом запуске macOS предупредит, что приложение от неустановленного разработчика: откройте «Системные настройки → Конфиденциальность и безопасность» и нажмите «Всё равно открыть». Дальше приложение обновляется само.
NOTES
