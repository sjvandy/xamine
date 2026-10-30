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

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Xamine.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/Packaging/README.txt" "$STAGING/README.txt"

hdiutil create -volname "Xamine $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "$DMG"
