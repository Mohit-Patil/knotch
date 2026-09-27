#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -swift-version 6 -o "$test_dir/clipboard-storage-tests" \
  "$repo_dir/Sources/Clipboard/ClipboardHistory.swift" \
  "$repo_dir/Sources/Clipboard/ClipboardStorage.swift" \
  "$repo_dir/Sources/Clipboard/ClipboardThumbnail.swift" \
  "$repo_dir/Tests/ClipboardStorageTests.swift"
"$test_dir/clipboard-storage-tests"
