#!/usr/bin/env bash
# Clean checkout -> tested, built, packaged DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
scripts/build.sh
scripts/make-dmg.sh
