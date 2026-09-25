#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
[[ -z "$MODE" || "$MODE" == --test ]] || { printf 'usage: %s [--test]\n' "$0" >&2; exit 1; }
die() { printf 'build: %s\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen is required; install it separately"
command -v xcodebuild >/dev/null || die "Xcode is required"
"$ROOT/scripts/bootstrap-engine.sh" --verify

ENGINE="$ROOT/.build/ghostty"
FRAMEWORK="$ENGINE/macos/GhosttyKit.xcframework"
RESOURCE_SOURCE="$ENGINE/zig-out/share"
[[ -d "$FRAMEWORK" ]] || die "GhosttyKit is missing; run scripts/bootstrap-engine.sh --build first"
[[ -f "$FRAMEWORK/Info.plist" ]] || die "GhosttyKit Info.plist is missing"
[[ -d "$RESOURCE_SOURCE/ghostty/shell-integration" ]] || die "Ghostty shell integration is missing"
[[ -f "$RESOURCE_SOURCE/terminfo/78/xterm-ghostty" ]] || die "Ghostty terminfo is missing"
[[ -f "$ROOT/Resources/terminal.conf" ]] || die "Resources/terminal.conf is missing"
[[ -f "$ROOT/ThirdParty/Notices/Ghostty-LICENSE" ]] || die "Ghostty license notice is missing"

if [[ "$MODE" == --test ]]; then
  DERIVED="$ROOT/.build/test-app"
  CONDITIONS="HARNESS_TESTS"
else
  DERIVED="$ROOT/.build/app"
  CONDITIONS=""
fi

(
  cd "$ROOT"
  xcodegen generate --spec project.yml
  xcodebuild -project Knotch.xcodeproj -scheme Knotch -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" build
)

APP="$DERIVED/Build/Products/Release/Knotch.app"
[[ -d "$APP/Contents/MacOS" ]] || die "Xcode did not produce $APP"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$RESOURCES/ThirdParty"
# Xcode can leave prior resource copies in an incremental product. Replace just
# the generated engine directories, so removed upstream files cannot linger.
rm -rf "$RESOURCES/ghostty" "$RESOURCES/terminfo" "$RESOURCES/ThirdParty/Ghostty-LICENSE"
ditto "$RESOURCE_SOURCE/ghostty" "$RESOURCES/ghostty"
ditto "$RESOURCE_SOURCE/terminfo" "$RESOURCES/terminfo"
ditto "$ROOT/ThirdParty/Notices/Ghostty-LICENSE" "$RESOURCES/ThirdParty/Ghostty-LICENSE"
printf '%s\n' '982fe90d941e4b4aab4905ffcbcfdea60bd83343' > "$RESOURCES/engine-revision.txt"
[[ -f "$RESOURCES/terminfo/78/xterm-ghostty" ]] || die "bundled terminfo copy failed"
[[ -d "$RESOURCES/ghostty/shell-integration" ]] || die "bundled shell integration copy failed"

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built and ad-hoc signed %s\n' "$APP"
