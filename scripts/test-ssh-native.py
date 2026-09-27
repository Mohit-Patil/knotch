#!/usr/bin/env python3
"""Disposable loopback SSH qualification; no personal SSH files are changed."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
app = root / '.build/test-app/Build/Products/Release/Knotch.app/Contents/MacOS/Knotch'
evidence = root / '.evidence'
evidence.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='knotch-ssh-native-') as temp:
    folder = Path(temp)
    for name in ('host', 'client'):
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(folder / name)], check=True)
    (folder / 'authorized_keys').write_bytes((folder / 'client.pub').read_bytes())
    (folder / 'authorized_keys').chmod(0o600)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    server_config = folder / 'sshd_config'
    server_config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {folder}/host
PidFile {folder}/pid
AuthorizedKeysFile {folder}/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
LogLevel VERBOSE
''')
    client_config = folder / 'ssh_config'
    client_config.write_text(f'''Host *
    IdentityFile {folder}/client
    IdentitiesOnly yes
    UserKnownHostsFile {folder}/known_hosts
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking ask
    ConnectTimeout 5
    ControlMaster no
    ControlPath none
''')
    remote_directory = folder / "Project space ' 日本語"
    remote_directory.mkdir()
    with (evidence / 'ssh-server.log').open('w') as log:
        daemon = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(server_config)], stdout=log, stderr=log)
        try:
            time.sleep(0.3)
            if daemon.poll() is not None:
                raise RuntimeError((evidence / 'ssh-server.log').read_text())
            env = dict(os.environ, KNOTCH_SSH_FIXTURE_PORT=str(port),
                       KNOTCH_SSH_FIXTURE_CONFIG=str(client_config),
                       KNOTCH_SSH_FIXTURE_DIRECTORY=str(remote_directory),
                       KNOTCH_EVIDENCE=str(evidence / 'ssh-native-results.json'))
            with (evidence / 'ssh-native-run.log').open('w') as output:
                subprocess.run([str(app), '--ssh-self-test'], env=env, stdout=output, stderr=output, timeout=45, check=True)
            report = json.loads((evidence / 'ssh-native-results.json').read_text())
            assert report['passed'], report
            print(f"Passed {len(report['results'])} native SSH checks")
        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()
