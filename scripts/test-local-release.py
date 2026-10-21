#!/usr/bin/env python3
"""Local archive transaction tests; no app launch, media, SwiftPM or signing."""
import importlib
from pathlib import Path
import tempfile
import unittest

release = importlib.import_module('media_release')


class LocalReleaseTests(unittest.TestCase):
    def test_release_directory_is_new_and_inside_worktree_dist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'dist/releases/0.3.0-build3'
            self.assertEqual(release.validate_release_output(root, target), target)
            for invalid in (root / 'Applications', root / 'dist/../outside', root / 'dist'):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    release.validate_release_output(root, invalid)
            target.mkdir(parents=True)
            with self.assertRaises(FileExistsError):
                release.validate_release_output(root, target)

    def test_release_directory_rejects_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'elsewhere').mkdir()
            (root / 'dist').symlink_to(root / 'elsewhere', target_is_directory=True)
            with self.assertRaises(ValueError):
                release.validate_release_output(root, root / 'dist/new')

    def test_manifest_observes_executable_permissions_and_file_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / 'tool'; tool.write_bytes(b'original'); tool.chmod(0o755)
            original = release.tree_manifest(root)
            tool.chmod(0o644)
            self.assertNotEqual(release.tree_manifest(root), original)
            tool.chmod(0o755); tool.write_bytes(b'changed')
            self.assertNotEqual(release.tree_manifest(root), original)

    def test_manifest_rejects_escaping_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); payload = root / 'payload'; payload.mkdir()
            (root / 'outside').write_bytes(b'outside')
            (payload / 'link').symlink_to('../outside')
            with self.assertRaises(ValueError):
                release.tree_manifest(payload)

    def test_zip_roundtrip_preserves_bytes_permissions_symlinks_and_empty_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); payload = root / 'Dynamic Wallpaper.app'; payload.mkdir()
            (payload / 'empty').mkdir()
            tool = payload / 'tool'; tool.write_bytes(b'archive fixture'); tool.chmod(0o755)
            (payload / 'tool-link').symlink_to('tool')
            archive = root / 'fixture.zip'
            restored, manifest = release.archive_application(payload, archive, root / 'unpacked')
            self.assertEqual(release.tree_manifest(restored), manifest)
            self.assertEqual(manifest, release.tree_manifest(payload))
            self.assertEqual((restored / 'tool').read_bytes(), b'archive fixture')
            with self.assertRaises(FileExistsError):
                release.archive_application(payload, archive, root / 'another-unpack')


if __name__ == '__main__':
    unittest.main()
