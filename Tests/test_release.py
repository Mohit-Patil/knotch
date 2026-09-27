import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).resolve().parents[1] / 'scripts/publish-release.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def feed(version):
    return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>{version}</sparkle:version><enclosure /></item></channel></rss>'.encode()


class ReleaseTests(unittest.TestCase):
    def test_numeric_version_ordering(self):
        self.assertGreater(publisher.version(feed('1.10.0')), publisher.version(feed('1.9.9')))

    def test_invalid_feed_fails_closed(self):
        for value in ('', '1.0-beta', '1.2'):
            with self.assertRaises(ValueError):
                publisher.version(feed(value))

    def test_mismatched_tag_never_calls_github(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ('Knotch.zip', 'Knotch-sources.tar.gz', 'SHA256SUMS'):
                (directory / name).touch()
            (directory / 'appcast.xml').write_bytes(feed('1.0.1'))
            with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'owner/repo'}), patch.object(publisher, 'gh') as gh:
                with self.assertRaisesRegex(ValueError, 'does not match'):
                    publisher.publish('v1.0.0', directory)
                gh.assert_not_called()

    def test_upload_precedes_feed_publication(self):
        import json
        calls = []
        def github(*args, data=None):
            calls.append(args)
            if args[:2] == ('release', 'list'):
                return '[]'
            if args[0] == 'api':
                if 'matching-refs' in args[1]:
                    return '[]'
                return json.dumps({'sha': 'new-object'})
            return ''
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ('Knotch.zip', 'Knotch-sources.tar.gz', 'SHA256SUMS'):
                (directory / name).touch()
            (directory / 'appcast.xml').write_bytes(feed('1.0.0'))
            with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'owner/repo'}), patch.object(publisher, 'gh', side_effect=github):
                publisher.publish('v1.0.0', directory)
        upload = next(i for i, call in enumerate(calls) if call[:2] == ('release', 'upload'))
        publish = next(i for i, call in enumerate(calls) if call == ('api', 'repos/owner/repo/git/refs'))
        self.assertLess(upload, publish)

    def test_downgrade_never_uploads(self):
        import base64
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ('Knotch.zip', 'Knotch-sources.tar.gz', 'SHA256SUMS'):
                (directory / name).touch()
            (directory / 'appcast.xml').write_bytes(feed('1.0.0'))
            responses = [[{'ref': 'refs/heads/updates', 'object': {'sha': 'parent'}}],
                         {'content': base64.b64encode(feed('1.1.0')).decode()}]
            with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'owner/repo'}), patch.object(publisher, 'api', side_effect=responses), patch.object(publisher, 'gh') as gh:
                with self.assertRaisesRegex(ValueError, 'equal or newer'):
                    publisher.publish('v1.0.0', directory)
                gh.assert_not_called()


if __name__ == '__main__':
    unittest.main()
