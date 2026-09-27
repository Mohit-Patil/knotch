#!/bin/bash
# Build and verify distributable artifacts. Publishing is a separate step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
MODE="${2:-}"
die() { printf 'release: %s\n' "$*" >&2; exit 1; }
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'usage: release.sh X.Y.Z [--archive-only]'
[[ -z "$MODE" || "$MODE" == --archive-only ]] || die 'unknown mode'
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
REPOSITORY="${GITHUB_REPOSITORY:-Mohit-Patil/knotch}"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'invalid GitHub repository'
if [[ -z "$MODE" ]]; then
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die 'commit the release tree before packaging sources'
  [[ "${ZIG_GLOBAL_CACHE_DIR:-}" == "$ROOT/.build/zig-cache" ]] || die 'use the repository-local .build/zig-cache for release source packaging'
fi
"$ROOT/scripts/bootstrap-engine.sh" --verify
"$ROOT/scripts/bootstrap-sparkle.sh"
STAGING="$ROOT/.build/release/$VERSION"
mkdir -p "$STAGING"
ARCHIVE="$STAGING/Knotch.xcarchive"
EXPORT="$STAGING/export"
FEED="https://raw.githubusercontent.com/$REPOSITORY/updates/appcast.xml"
export APPLE_TEAM_ID
python3 - "$STAGING/ExportOptions.plist" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'method':'developer-id', 'signingStyle':'manual',
                  'signingCertificate':'Developer ID Application', 'teamID':os.environ['APPLE_TEAM_ID']}, f)
PY
(
  cd "$ROOT"
  xcodegen generate --spec project.yml
  xcodebuild -project Knotch.xcodeproj -scheme Knotch -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$ROOT/.build/release-derived" \
    -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    KNOTCH_UPDATES_ENABLED=YES SPARKLE_FEED_URL="$FEED" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS= archive
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$STAGING/ExportOptions.plist"
)
APP="$EXPORT/Knotch.app"
codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/verify-release.py" "$APP" "$VERSION" "$REPOSITORY"
if [[ "$MODE" == --archive-only ]]; then
  printf 'Signed archive ready for inspection: %s\n' "$APP"
  exit 0
fi
ditto -c -k --keepParent "$APP" "$STAGING/notarization.zip"
xcrun notarytool submit "$STAGING/notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
OUT="$STAGING/artifacts"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/Knotch.zip"
KEY_ARGS=(--account dev.personal.Knotch.updates)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"); fi
"$ROOT/.build/sparkle/bin/generate_appcast" "${KEY_ARGS[@]}" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  --link "https://github.com/$REPOSITORY" "$OUT"
"$ROOT/.build/sparkle/bin/sign_update" "${KEY_ARGS[@]}" --verify "$OUT/appcast.xml"
"$ROOT/scripts/package-sources.sh" "$OUT/Knotch-sources.tar.gz"
(cd "$OUT" && shasum -a 256 Knotch.zip Knotch-sources.tar.gz appcast.xml > SHA256SUMS)
printf 'Verified release artifacts: %s\n' "$OUT"
