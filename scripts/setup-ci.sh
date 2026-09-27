#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?Run on a GitHub Actions macOS runner}"
sudo xcode-select -s /Applications/Xcode_27.app
[[ "$(xcrun --show-sdk-version)" == 27.0 ]]
command -v xcodegen >/dev/null || brew install xcodegen
curl --fail --location --retry 3 --silent --show-error \
  https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz -o "$RUNNER_TEMP/zig.tar.xz"
printf '%s  %s\n' b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 "$RUNNER_TEMP/zig.tar.xz" | shasum -a 256 -c -
tar -xf "$RUNNER_TEMP/zig.tar.xz" -C "$RUNNER_TEMP"
printf '%s\n' "$RUNNER_TEMP/zig-aarch64-macos-0.16.0" >> "$GITHUB_PATH"
