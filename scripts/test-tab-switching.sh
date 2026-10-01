#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 \
  "$ROOT/Sources/Overlay/TerminalTabStrip.swift" \
  "$ROOT/Tests/TerminalTabStripTests.swift" \
  -o "$TEST_DIR/tab-switching-tests"
"$TEST_DIR/tab-switching-tests"
