#!/bin/sh
#
# Rebuild the app bundle in build/.
#
# Use this, not Xcode's Cmd-R, if you keep the app in the Dock. Cmd-R builds
# into DerivedData and leaves build/AINews.app untouched, so the Dock would
# quietly keep launching the old binary.

set -eu
cd "$(dirname "$0")"

echo "Building Release into build/ ..."
rm -rf build
xcodebuild -project AINews.xcodeproj \
           -scheme AINews \
           -configuration Release \
           CONFIGURATION_BUILD_DIR="$PWD/build" \
           build \
  | grep -E "error:|warning:|BUILD" | grep -v appintentsmetadata || true

if [ -d build/AINews.app ]; then
  echo
  echo "Built: $PWD/build/AINews.app"
  echo "Quit the running copy and relaunch it from the Dock to pick this up."
else
  echo "Build failed - build/AINews.app was not produced." >&2
  exit 1
fi
