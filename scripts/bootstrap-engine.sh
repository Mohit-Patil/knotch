#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/.build/ghostty"
PIN="982fe90d941e4b4aab4905ffcbcfdea60bd83343"
ARCHIVE_SHA256="0d0a3d9337fcb562bc43483b5bad97ba8fe0f08e000629502f6e7d130808b8b7"
MODE="${1:---build}"

die() { printf 'bootstrap-engine: %s\n' "$*" >&2; exit 1; }
case "$MODE" in --verify|--build) ;; *) die "usage: $0 [--verify|--build]" ;; esac

[[ "$(uname -s)" == Darwin ]] || die "GhosttyKit build requires macOS"
[[ "$(uname -m)" == arm64 ]] || die "this native GhosttyKit pin is configured for arm64"
for tool in git zig xcodebuild xcrun shasum; do
  command -v "$tool" >/dev/null || die "missing $tool; install it separately before building"
done
if [[ "$MODE" == --build ]]; then
  for tool in curl python3; do
    command -v "$tool" >/dev/null || die "missing $tool; install it separately before building"
  done
fi
[[ "$(zig version)" == 0.16.0 ]] || die "Ghostty $PIN requires Zig 0.16.0; found $(zig version)"
[[ "$(xcrun --show-sdk-version)" == 27.0 ]] || die "expected macOS SDK 27.0; found $(xcrun --show-sdk-version)"

if [[ ! -d "$ENGINE/.git" ]]; then
  [[ ! -e "$ENGINE" ]] || die "$ENGINE exists but is not a Git checkout"
  mkdir -p "$ROOT/.build"
  git init -q "$ENGINE"
  git -C "$ENGINE" remote add origin https://github.com/ghostty-org/ghostty.git
  git -C "$ENGINE" fetch --depth=1 origin "$PIN"
  git -C "$ENGINE" checkout --detach -q "$PIN"
fi

[[ "$(git -C "$ENGINE" rev-parse HEAD)" == "$PIN" ]] || die "Ghostty checkout is not the pinned revision $PIN"
[[ -z "$(git -C "$ENGINE" status --porcelain)" ]] || die "Ghostty checkout has local changes; refusing an ambiguous build"
actual_archive_sha="$(git -C "$ENGINE" archive --format=tar "$PIN" | shasum -a 256 | awk '{print $1}')"
[[ "$actual_archive_sha" == "$ARCHIVE_SHA256" ]] || die "Ghostty source archive digest mismatch: $actual_archive_sha"

if [[ "$MODE" == --verify ]]; then
  printf 'Ghostty source verified: %s (archive SHA-256 %s)\n' "$PIN" "$ARCHIVE_SHA256"
  exit 0
fi

# Use the same Zig cache for prefetch and build (Zig's default cache unless the
# caller sets ZIG_GLOBAL_CACHE_DIR). Download archives remain under .build.
# Build only on an explicit --build request; app builds never compile the core.
if [[ -n "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
  mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
  export ZIG_GLOBAL_CACHE_DIR="$(cd "$ZIG_GLOBAL_CACHE_DIR" && pwd)"
fi
"$ROOT/scripts/prefetch-dependencies.py"
(
  cd "$ENGINE"
  zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
    -Dxcframework-target=native -Demit-macos-app=false \
    -Demit-docs=false -Demit-webdata=false
)

[[ -d "$ENGINE/macos/GhosttyKit.xcframework" ]] || die "Zig succeeded without GhosttyKit.xcframework"
[[ -d "$ENGINE/zig-out/share/ghostty" ]] || die "Zig succeeded without share/ghostty"
[[ -f "$ENGINE/zig-out/share/terminfo/78/xterm-ghostty" ]] || die "Zig succeeded without compiled xterm-ghostty terminfo"
printf 'Built GhosttyKit at %s\n' "$ENGINE/macos/GhosttyKit.xcframework"
