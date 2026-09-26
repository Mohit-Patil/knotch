#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/knotch-notification-test.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
swiftc -swift-version 6 -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Notifications/AgentNotificationController.swift" \
  "$ROOT/Tests/NotificationCommandFixture.swift" -o "$FIXTURE/commands"
"$FIXTURE/commands" > "$FIXTURE/commands.json"
python3 - "$FIXTURE/commands.json" <<'PY'
import json, shlex, subprocess, sys
commands=json.load(open(sys.argv[1]))
args=shlex.split(commands['claude'])
assert args[:2] == ['claude', '--settings'] and len(args) == 3
settings=json.loads(args[2])
hook=settings['hooks']['Stop'][0]['hooks'][0]
assert hook['type'] == 'command'
output=json.loads(subprocess.check_output(['/bin/sh', '-c', hook['command']], text=True, timeout=5))
assert output == {'terminalSequence': '\x1b]777;notify;Claude Code;Response complete\x07'}
assert shlex.split(commands['codex']) == ['codex', '-c', 'tui.notifications=["agent-turn-complete"]', '-c', 'tui.notification_method="osc9"']
print('PASS: launch-command quoting and actual Claude hook JSON/OSC output; no agent launched')
PY
