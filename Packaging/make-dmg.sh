#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
VERSION="$(grep -E '^\s*MARKETING_VERSION:' "$ROOT/project.yml" | sed -E 's/.*"(.*)".*/\1/')"
DERIVED_DATA="/tmp/xamine-build"
APP="$DERIVED_DATA/Build/Products/Release/Xamine.app"
STAGING="$BUILD/dmg"
DMG="$BUILD/Xamine-$VERSION.dmg"

cd "$ROOT"
xcodegen generate
xcodebuild -project Xamine.xcodeproj -scheme Xamine -configuration Release -derivedDataPath "$DERIVED_DATA" build

codesign --verify --strict "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q "^Authority=Developer ID Application: .*(2R8MRUP265)" <<< "$SIGNATURE"; then
    echo "Xamine.app isn't signed with Developer ID (2R8MRUP265); install the certificate and retry." >&2
    exit 1
fi

# The xamine helper is how AI agents and scripts reach Xamine; a release without it can't be driven.
HELPER="$APP/Contents/Helpers/xamine"
if [[ ! -x "$HELPER" ]] || ! codesign --verify --strict "$HELPER"; then
    echo "Xamine.app is missing a signed Contents/Helpers/xamine; check the xamine-cli target in project.yml." >&2
    exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Xamine.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/Packaging/README.txt" "$STAGING/README.txt"

hdiutil create -volname "Xamine $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "$DMG"
