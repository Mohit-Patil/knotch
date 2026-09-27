#!/usr/bin/env python3
"""Reject incomplete updater configuration before signing an appcast."""
import base64
from pathlib import Path
import plistlib
import subprocess
import sys


def verify(app: Path, version: str, repository: str) -> None:
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    assert info['CFBundleIdentifier'] == 'dev.personal.Knotch', 'unexpected bundle identity'
    assert info['CFBundleShortVersionString'] == version
    assert info['CFBundleVersion'] == version
    assert info['KnotchUpdatesEnabled'] == 'YES', 'updates disabled in distribution build'
    assert info['SUFeedURL'] == f'https://raw.githubusercontent.com/{repository}/updates/appcast.xml'
    assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
    assert info['SUVerifyUpdateBeforeExtraction'] and info['SURequireSignedFeed']
    assert not info['SUAutomaticallyUpdate'] and not info['SUAllowsAutomaticUpdates']
    assert (app / 'Contents/Frameworks/Sparkle.framework/Sparkle').exists()
    assert (app / 'Contents/Resources/ThirdParty/Notices/Sparkle-LICENSE').is_file()
    assert (app / 'Contents/Resources/ghostty/shell-integration/zsh/ghostty-integration').exists()
    signature = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(app)], stderr=subprocess.STDOUT, text=True)
    assert 'Authority=Developer ID Application:' in signature, 'not Developer ID signed'
    assert 'runtime' in signature and 'Timestamp=' in signature, 'missing hardened runtime or secure timestamp'
    print('Verified release identity, versions, signing, resources and Sparkle configuration')


if __name__ == '__main__':
    verify(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
