#!/usr/bin/env python3
"""Upload immutable artifacts, then atomically advance the stable update feed."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def gh(*args, data=None):
    command = ['gh', *args]
    if data is not None:
        command += ['--input', '-']
    return subprocess.check_output(command, input=json.dumps(data) if data is not None else None, text=True)


def api(path, data=None):
    return json.loads(gh('api', path, data=data))


def version(feed):
    root = ET.fromstring(feed)
    values = [item.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
              or item.find('enclosure').get('{http://www.andymatuschak.org/xml-namespaces/sparkle}version', '')
              for item in root.findall('./channel/item')]
    if not values or any(not re.fullmatch(r'\d+\.\d+\.\d+', value) for value in values):
        raise ValueError('feed must contain numeric release versions')
    return max(tuple(map(int, value.split('.'))) for value in values)


def publish(tag, directory):
    if not re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag):
        raise ValueError('expected stable vX.Y.Z tag')
    repo = os.environ['GITHUB_REPOSITORY']
    prefix = f'repos/{repo}'
    files = [directory / name for name in ('Knotch.dmg', 'Knotch.zip', 'Knotch-sources.tar.gz', 'appcast.xml', 'SHA256SUMS')]
    for file in files:
        if not file.is_file():
            raise ValueError(f'missing artifact: {file}')
    feed = (directory / 'appcast.xml').read_bytes()
    expected = tuple(map(int, tag[1:].split('.')))
    if version(feed) != expected:
        raise ValueError('feed version does not match tag')
    # An empty repository has no updates branch. Other API errors must fail closed.
    refs = api(f'{prefix}/git/matching-refs/heads/updates')
    ref = next((ref for ref in refs if ref['ref'] == 'refs/heads/updates'), None)
    parent = ref['object']['sha'] if ref else None
    if parent:
        previous = api(f'{prefix}/contents/appcast.xml?ref={parent}')
        if version(base64.b64decode(previous['content'])) >= expected:
            raise ValueError('refusing to replace an equal or newer update feed')
    releases = json.loads(gh('release', 'list', '--repo', repo, '--limit', '1000', '--json', 'tagName'))
    if any(release['tagName'] == tag for release in releases):
        release = api(f'{prefix}/releases/tags/{tag}')
        if release['draft'] or release['prerelease']:
            raise ValueError('only published stable releases can update the feed')
        if release['assets']:
            raise ValueError('release already has assets; refusing to overwrite published downloads')
    else:
        gh('release', 'create', tag, '--repo', repo, '--verify-tag', '--title', tag, '--generate-notes')
    gh('release', 'upload', tag, *(str(file) for file in files), '--repo', repo)
    # All downloads exist before the feed becomes visible. Preserve any other branch files.
    blob = api(f'{prefix}/git/blobs', {'content': base64.b64encode(feed).decode(), 'encoding': 'base64'})
    tree_data = {'tree': [{'path': 'appcast.xml', 'mode': '100644', 'type': 'blob', 'sha': blob['sha']}]}
    if parent:
        tree_data['base_tree'] = api(f'{prefix}/git/commits/{parent}')['tree']['sha']
    tree = api(f'{prefix}/git/trees', tree_data)
    commit = api(f'{prefix}/git/commits', {'message': f'Publish {tag} update feed', 'tree': tree['sha'], 'parents': [parent] if parent else []})
    if parent:
        gh('api', '--method', 'PATCH', f'{prefix}/git/refs/heads/updates', data={'sha': commit['sha'], 'force': False})
    else:
        api(f'{prefix}/git/refs', {'ref': 'refs/heads/updates', 'sha': commit['sha']})
    print(f'Published {repo} {tag} and signed update feed')


if __name__ == '__main__':
    publish(sys.argv[1], Path(sys.argv[2]))
