#!/bin/bash
# Xcode build phase: resources must be in place before the app is code signed.
set -euo pipefail
ROOT="${SRCROOT:?Run as an Xcode build phase}"
RESOURCES="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
SOURCE="$ROOT/.build/ghostty/zig-out/share"
mkdir -p "$RESOURCES/ThirdParty"
rm -rf "$RESOURCES/ghostty" "$RESOURCES/terminfo" "$RESOURCES/ThirdParty/Notices"
mkdir -p "$RESOURCES/ghostty"
ditto "$SOURCE/ghostty/themes" "$RESOURCES/ghostty/themes"
ditto "$SOURCE/ghostty/shell-integration" "$RESOURCES/ghostty/shell-integration"
ditto "$SOURCE/terminfo" "$RESOURCES/terminfo"
ditto "$ROOT/ThirdParty/Notices" "$RESOURCES/ThirdParty/Notices"
cp "$ROOT/ThirdParty/README.md" "$RESOURCES/ThirdParty/README.md"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"
printf '%s\n' '982fe90d941e4b4aab4905ffcbcfdea60bd83343' > "$RESOURCES/engine-revision.txt"
