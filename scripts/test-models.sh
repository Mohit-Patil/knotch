#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -swift-version 6 -o "$test_dir/model-tests" \
  "$repo_dir/Sources/Model/OverlayMotionCurve.swift" \
  "$repo_dir/Sources/Model/OverlayState.swift" \
  "$repo_dir/Sources/Model/DisplayGeometry.swift" \
  "$repo_dir/Tests/ModelTests.swift"
"$test_dir/model-tests"
