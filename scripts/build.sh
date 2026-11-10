#!/usr/bin/env bash
# Builds "Claude Profiles.app" into dist/ (release config, ad-hoc signed).
# Usage: scripts/build.sh            # universal (arm64 + x86_64) when possible
#        ARCHS=arm64 scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP_NAME="Claude Profiles"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ARCHS="${ARCHS:-arm64 x86_64}"

echo "==> Building Claude Profiles $VERSION ($BUILD) for: $ARCHS"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}" --product ClaudeProfiles
swift build -c release "${ARCH_FLAGS[@]}" --product claude-profiles-cli
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> Icon"
mkdir -p "$ROOT/build"
ICON_SRC="$ROOT/Resources/AppIcon-source.png"
if [[ ! -f "$ROOT/build/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$ROOT/build/AppIcon.icns" || "$ICON_SRC" -nt "$ROOT/build/AppIcon.icns" ]]; then
  swift "$ROOT/scripts/make-icon.swift" "$ICON_SRC" "$ROOT/build/AppIcon.icns"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeProfiles" "$APP/Contents/MacOS/ClaudeProfiles"
cp "$BIN_DIR/claude-profiles-cli" "$APP/Contents/MacOS/claude-profiles-cli"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD/g" "$ROOT/Resources/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/claude-profiles-cli"
codesign --force --sign - --timestamp=none --identifier com.claudeprofiles.manager "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "==> Built $APP"
