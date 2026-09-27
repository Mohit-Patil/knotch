#!/bin/bash
# Include rebuildable sources alongside binaries (including the static libintl dependency).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?Pass the output tar.gz path}"
[[ "${ZIG_GLOBAL_CACHE_DIR:-}" == "$ROOT/.build/zig-cache" ]]
[[ -d "$ZIG_GLOBAL_CACHE_DIR/p" ]]
STAGING="$(mktemp -d "$ROOT/.build/source-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Knotch-sources/application" "$STAGING/Knotch-sources/ghostty" "$STAGING/Knotch-sources/zig-cache"
git -C "$ROOT" archive HEAD | tar -xf - -C "$STAGING/Knotch-sources/application"
git -C "$ROOT/.build/ghostty" archive HEAD | tar -xf - -C "$STAGING/Knotch-sources/ghostty"
ditto "$ZIG_GLOBAL_CACHE_DIR/p" "$STAGING/Knotch-sources/zig-cache/p"
cat > "$STAGING/Knotch-sources/BUILD.txt" <<'TXT'
Application and native dependency sources for this release.

Use the Xcode, SDK and Zig versions in application/ThirdParty/dependency-lock.json.
Copy zig-cache/p into an empty Zig global cache and set ZIG_GLOBAL_CACHE_DIR to it.
From application/, run scripts/bootstrap-engine.sh --build, then scripts/build.sh.
The bootstrap fetches/verifies the engine commit recorded in dependency-lock.json.
The same engine source is included in ghostty/ for inspection or modification.
To relink a modified engine, build the supplied ghostty/ with the recorded build
options, copy its GhosttyKit.xcframework and zig-out/share into application's
.build/ghostty locations, and adjust the source-verification guard for your fork.
No Developer ID or Sparkle private key is required for local ad-hoc builds.
TXT
tar -czf "$OUT" -C "$STAGING" Knotch-sources
