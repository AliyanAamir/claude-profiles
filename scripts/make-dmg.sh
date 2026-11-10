#!/usr/bin/env bash
# Packages dist/Claude Profiles.app into dist/ClaudeProfiles-<version>.dmg
# (drag-to-Applications layout, app icon as the volume icon).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="dist/Claude Profiles.app"
DMG="dist/ClaudeProfiles-$VERSION.dmg"
VOLNAME="Claude Profiles $VERSION"
[[ -d "$APP" ]] || { echo "Missing $APP. Run scripts/build.sh first." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Claude Profiles.app"
ln -s /Applications "$STAGE/Applications"

# Writable image first so the volume icon can be set, then compress.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
mkdir -p "$WORK/mnt"
hdiutil attach "$WORK/rw.dmg" -nobrowse -noautoopen -mountpoint "$WORK/mnt" >/dev/null
cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/mnt/.VolumeIcon.icns"
if SETFILE="$(xcrun -f SetFile 2>/dev/null)"; then
  "$SETFILE" -a C "$WORK/mnt"
else
  # FinderInfo with the kHasCustomIcon (0x0400) flag.
  xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$WORK/mnt"
fi
hdiutil detach "$WORK/mnt" -quiet

rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
