#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DEST="$ROOT/.build/sparkle"
if [[ -f "$DEST/.verified-version" && "$(cat "$DEST/.verified-version")" == "$VERSION:$SHA256" && -x "$DEST/bin/generate_appcast" && -d "$DEST/Sparkle.framework" ]]; then
  exit 0
fi
mkdir -p "$ROOT/.build"
STAGING="$(mktemp -d "$ROOT/.build/sparkle-download.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
curl --fail --location --retry 3 --connect-timeout 20 --max-time 180 --silent --show-error "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$STAGING/sparkle.tar.xz"
printf '%s  %s\n' "$SHA256" "$STAGING/sparkle.tar.xz" | shasum -a 256 --check --status
mkdir "$STAGING/unpacked"
tar -xf "$STAGING/sparkle.tar.xz" -C "$STAGING/unpacked"
[[ -d "$STAGING/unpacked/Sparkle.framework" && -x "$STAGING/unpacked/bin/generate_appcast" ]]
printf '%s\n' "$VERSION:$SHA256" > "$STAGING/unpacked/.verified-version"
rm -rf "$DEST"
mv "$STAGING/unpacked" "$DEST"
