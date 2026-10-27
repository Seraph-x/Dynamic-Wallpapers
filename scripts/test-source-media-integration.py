#!/usr/bin/env python3
"""Source-build selection and stale-cache rejection in public prepare/release paths."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import media_dependencies
import media_release


ROOT = Path(__file__).resolve().parents[1]


class SourceMediaIntegrationTests(unittest.TestCase):
    def fixture(self, root):
        scripts = root / 'scripts'; scripts.mkdir()
        source = scripts / 'mpv-source-lock.json'
        source.write_bytes((ROOT / 'scripts/mpv-source-lock.json').read_bytes())
        module = {'version': 'controlled test', 'architecture': 'arm64', 'minimum_macos': '14.0',
                  'source': 'https://example.com/source', 'license_status': 'source controlled',
                  'artifacts': [], 'source_build': {
                      'path': 'scripts/mpv-source-lock.json',
                      'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                      'output': '.build/media-source-complete/mpv'}}
        path = scripts / 'media-dependencies.json'
        path.write_text(json.dumps({'schema_version': 1, 'modules': {'mpv': module}}))
        return path

    def test_source_lock_selects_built_library_set_without_legacy_binary_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = self.fixture(root)
            lock = media_dependencies.load_lock(path, root)
            names = media_dependencies.expected_mpv_library_names(lock)
            self.assertEqual(len(names), 14)
            self.assertNotIn('libvulkan.1.dylib', names)
            self.assertEqual(media_dependencies.mpv_prepared_root(root, lock),
                             root / '.build/media-source-complete/mpv')

    def test_changed_source_lock_or_output_location_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = self.fixture(root)
            (root / 'scripts/mpv-source-lock.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                media_dependencies.load_lock(path, root)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = self.fixture(root)
            value = json.loads(path.read_text())
            value['modules']['mpv']['source_build']['output'] = '.build/dependencies/mpv'
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'output'):
                media_dependencies.load_lock(path, root)

    def test_prepared_source_products_require_actual_matching_record(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = self.fixture(root)
            lock = media_dependencies.load_lock(path, root)
            target = SimpleNamespace(architecture='arm64', minimum_macos='14.0')
            with mock.patch('mpv_source_build.verify_built', side_effect=ValueError('stale record')):
                with self.assertRaisesRegex(ValueError, 'stale record'):
                    media_dependencies.verify_mpv_prepared(
                        lock, root / '.build/dependencies', product_target=target)

    def test_release_names_follow_active_source_lock(self):
        self.assertTrue(hasattr(media_release, 'active_library_names'),
                        'release still reads the historical binary manifest')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root)
            self.assertEqual(len(media_release.active_library_names(root)), 14)


if __name__ == '__main__':
    unittest.main()
