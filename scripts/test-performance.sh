#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
app="$repo_dir/.build/test-app/Build/Products/Release/Knotch.app/Contents/MacOS/Knotch"
[[ -x "$app" ]] || { print -u2 'Run scripts/build.sh --test first'; exit 1; }
mkdir -p "$repo_dir/.evidence"
print 'Running isolated performance fixture (about 5 minutes).'
print 'During UI_READY, browse the synthetic image library in the qualification window.'
KNOTCH_EVIDENCE="$repo_dir/.evidence/stress-results.json" "$app" --performance-self-test > "$repo_dir/.evidence/stress-run.log" 2>&1
python3 - "$repo_dir/.evidence/stress-results.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report['checks'] and all(row['passed'] for row in report['checks']), report['checks']
assert any(row['phase'] == 'final_idle' for row in report['records'])
print(f"Passed {len(report['checks'])} stress checks; inspect phase metrics in {sys.argv[1]}")
PY
