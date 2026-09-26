#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macosx26.0 \
  "$repo_dir/Sources/Tools/FocusTools.swift" "$repo_dir/Tests/FocusToolsTests.swift" \
  -o "$test_dir/focus-tests"
"$test_dir/focus-tests"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macosx26.0 \
  "$repo_dir/Sources/Tools/ToolsContext.swift" "$repo_dir/Sources/Tools/FileShelfTools.swift" \
  "$repo_dir/Tests/FileShelfToolsTests.swift" -o "$test_dir/file-tests"
"$test_dir/file-tests"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macosx26.0 \
  -D QUICKTOOLS_PROCESS_FIXTURE "$repo_dir/Sources/Tools/QuickTools.swift" \
  "$repo_dir/Tests/QuickToolsTests.swift" -o "$test_dir/quick-tests"
"$test_dir/quick-tests"
