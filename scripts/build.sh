#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
[[ -z "$MODE" || "$MODE" == --test ]] || { printf 'usage: %s [--test]\n' "$0" >&2; exit 1; }
die() { printf 'build: %s\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen is required; install it separately"
command -v xcodebuild >/dev/null || die "Xcode is required"
"$ROOT/scripts/bootstrap-engine.sh" --verify
"$ROOT/scripts/bootstrap-sparkle.sh"

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
  BUNDLE_ID="dev.personal.Knotch.qualification"
else
  DERIVED="$ROOT/.build/app"
  CONDITIONS=""
  BUNDLE_ID="dev.personal.Knotch"
fi

(
  cd "$ROOT"
  xcodegen generate --spec project.yml
  xcodebuild -project Knotch.xcodeproj -scheme Knotch -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" build
)

APP="$DERIVED/Build/Products/Release/Knotch.app"
[[ -d "$APP/Contents/MacOS" ]] || die "Xcode did not produce $APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built and ad-hoc signed %s\n' "$APP"
