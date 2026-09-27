#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 -o "$test_dir/ssh-tests" \
  "$repo_dir/Sources/Terminal/SSHConnection.swift" "$repo_dir/Tests/SSHConnectionTests.swift"
"$test_dir/ssh-tests"
