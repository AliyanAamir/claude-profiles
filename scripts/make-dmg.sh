#!/usr/bin/env bash
# Packages dist/Claude Profiles.app into dist/ClaudeProfiles-<version>.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="dist/Claude Profiles.app"
DMG="dist/ClaudeProfiles-$VERSION.dmg"
[[ -d "$APP" ]] || { echo "Missing $APP. Run scripts/build.sh first." >&2; exit 1; }

STAGE="$(mktemp -d)/Claude Profiles"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Claude Profiles.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Claude Profiles $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
