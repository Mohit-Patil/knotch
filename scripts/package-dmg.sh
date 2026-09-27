#!/bin/bash
# Package an already notarized app for manual installation.
set -euo pipefail
APP="${1:?Pass the notarized Knotch.app path}"
OUT="${2:?Pass the output DMG path}"
: "${NOTARY_PROFILE:?Set a notarytool Keychain profile}"
[[ "$APP" = /* ]] || APP="$PWD/$APP"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
[[ ! -e "$OUT" ]] || { echo 'Refusing to replace an existing DMG' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Knotch.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$(dirname "$OUT")"
hdiutil create -volname Knotch -srcfolder "$STAGING" -format UDZO -fs HFS+ "$OUT"
codesign --force --sign "${DEVELOPER_ID_IDENTITY:-Developer ID Application}" --timestamp "$OUT"
codesign --verify --strict "$OUT"
xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT"
xcrun stapler validate "$OUT"
hdiutil verify "$OUT"
spctl --assess --type open --context context:primary-signature --verbose "$OUT"
printf 'Verified signed and notarized DMG: %s\n' "$OUT"
