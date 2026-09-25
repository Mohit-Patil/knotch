#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"
[[ "$MODE" == all || "$MODE" == harness || "$MODE" == overlay ]] || { printf 'usage: %s [all|harness|overlay]\n' "$0" >&2; exit 1; }
APP="$ROOT/.build/test-app/Build/Products/Release/Knotch.app/Contents/MacOS/Knotch"
[[ -x "$APP" ]] || { printf 'First run scripts/build.sh --test\n' >&2; exit 1; }
mkdir -p "$ROOT/.evidence"
run_fixture() {
  local name="$1" flag="$2"
  printf 'Running native %s qualification; the harness includes a 60-second hidden fixture.\n' "$name"
  KNOTCH_EVIDENCE="$ROOT/.evidence/$name-results.json" "$APP" "$flag" > "$ROOT/.evidence/$name-run.log" 2>&1
  python3 - "$ROOT/.evidence/$name-results.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    report = json.load(source)
assert report['engine'] == '982fe90d941e4b4aab4905ffcbcfdea60bd83343'
assert report['results'] and all(row['result'] == 'PASSED' for row in report['results']), report
print(f"Passed {len(report['results'])} native checks; evidence: {sys.argv[1]}")
PY
}
if [[ "$MODE" == all || "$MODE" == harness ]]; then run_fixture harness --self-test; fi
if [[ "$MODE" == all || "$MODE" == overlay ]]; then run_fixture overlay --overlay-self-test; fi
