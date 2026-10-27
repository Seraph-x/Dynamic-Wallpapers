#!/usr/bin/env python3
"""Offline checks for the non-GUI public build preparation path."""

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name('prepare-public-build.py')


def load_module():
    spec = importlib.util.spec_from_file_location('prepare_public_build', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PreparePublicBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / '.build/dependencies'
        self.cache.mkdir(parents=True)

    def archive(self, members):
        path = self.cache / 'cef/source.tar.bz2'
        path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, 'w:bz2') as archive:
            for name, content, kind in members:
                entry = tarfile.TarInfo(name)
                if kind == 'file':
                    entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
                else:
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = content.decode()
                    archive.addfile(entry)
        return path

    def test_cef_extraction_rejects_escape_and_symlink(self):
        module = load_module()
        destination = self.cache / 'cef/stage'
        destination.mkdir(parents=True)
        for name, content, kind in [('../outside', b'bad', 'file'),
                                    ('cef_binary_1_macosarm64_minimal/link', b'../outside', 'symlink')]:
            archive = self.archive([(name, content, kind)])
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'CEF archive'):
                module.extract_cef(archive, destination, '1')
        self.assertEqual(list(destination.iterdir()), [])

    def test_cef_extraction_accepts_expected_regular_members_only(self):
        module = load_module()
        destination = self.cache / 'cef/stage'
        destination.mkdir(parents=True)
        archive = self.archive([
            ('cef_binary_1_macosarm64_minimal/include/cef_app.h', b'header', 'file'),
            ('cef_binary_1_macosarm64_minimal/CMakeLists.txt', b'cmake', 'file'),
        ])
        module.extract_cef(archive, destination, '1')
        self.assertEqual((destination / 'cef_binary_1_macosarm64_minimal/include/cef_app.h').read_bytes(),
                         b'header')

    def test_failed_cef_wrapper_build_does_not_publish_partial_source(self):
        module = load_module()
        archive = self.archive([
            ('cef_binary_1_macosarm64_minimal/include/cef_app.h', b'header', 'file'),
            ('cef_binary_1_macosarm64_minimal/CMakeLists.txt', b'cmake', 'file'),
        ])
        lock = {'modules': {'cef': {'version': '1', 'architecture': 'arm64',
                                   'minimum_macos': '13.0',
                                   'artifacts': [{'path': str(archive.relative_to(self.cache))}]}}}
        target = SimpleNamespace(architecture='arm64', minimum_macos='14.0')
        with mock.patch.object(module.subprocess, 'run', side_effect=RuntimeError('cmake failed')):
            with self.assertRaisesRegex(RuntimeError, 'cmake failed'):
                module.prepare_cef(self.root, lock, target)
        extracted = self.cache / 'cef/cef_binary_1_macosarm64_minimal'
        self.assertFalse(extracted.exists())
        self.assertFalse((self.cache / 'cef/wrapper-make').exists())

        def build(command, **_kwargs):
            destination = Path(command[command.index('-B') + 1]) if '-B' in command else None
            if destination is not None:
                wrapper = destination / 'libcef_dll_wrapper/libcef_dll_wrapper.a'
                wrapper.parent.mkdir(parents=True)
                wrapper.write_bytes(b'archive fixture')

        with mock.patch.object(module.subprocess, 'run', side_effect=build), \
             mock.patch.object(module, 'verify_cef_prepared'):
            module.prepare_cef(self.root, lock, target)
        self.assertTrue(extracted.is_dir())
        self.assertTrue((self.cache / 'cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a').is_file())

    def test_mpv_preparation_requires_source_build_and_rejects_historical_cache(self):
        module = load_module()
        source = self.cache / 'mpv/lib/libmpv.2.dylib'
        source.parent.mkdir(parents=True)
        source.write_bytes(b'locked original')
        lock = {'modules': {'mpv': {'version': 'test', 'architecture': 'arm64',
                                    'minimum_macos': '12.0', 'artifacts': [
                                        {'path': 'mpv/lib/libmpv.2.dylib',
                                         'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}]}}}
        target = SimpleNamespace(architecture='arm64', minimum_macos='14.0')
        with self.assertRaisesRegex(ValueError, 'historical binaries'):
            module.prepare_mpv(self.root, lock, target)
        self.assertEqual(source.read_bytes(), b'locked original')
        self.assertFalse((self.cache / 'mpv/runtime-lib').exists())
        lock['modules']['mpv']['source_build'] = {'output': '.build/media-source-complete/mpv'}
        with mock.patch('mpv_source_build.build') as build, \
                mock.patch.object(module, 'verify_mpv_prepared') as verify:
            module.prepare_mpv(self.root, lock, target)
        build.assert_called_once_with(self.root)
        verify.assert_called_once_with(lock, self.cache, product_target=target)

    def test_failed_input_download_is_exposed_without_product_build(self):
        module = load_module()
        artifact = {'path': 'cef/source.tar.bz2', 'url': 'https://example.invalid/archive',
                    'sha256': '0' * 64}
        lock = {'modules': {'cef': {'version': '1', 'artifacts': [artifact]}}}
        with mock.patch.object(module, 'load_lock', return_value=lock), \
             mock.patch.object(module, 'prepare_artifact', side_effect=RuntimeError('download failed')), \
             mock.patch.object(module, 'prepare_cef') as cef:
            with self.assertRaisesRegex(RuntimeError, 'download failed'):
                module.prepare(self.root, modules=('cef',))
        cef.assert_not_called()

    def test_existing_ffmpeg_requires_complete_record_without_rebuilding(self):
        module = load_module()
        install = self.cache / 'ffmpeg/install'
        install.mkdir(parents=True)
        with mock.patch.object(module, 'verify_record', side_effect=ValueError('stale record')), \
             mock.patch.object(module, 'subprocess') as process:
            with self.assertRaisesRegex(ValueError, 'stale record'):
                module.prepare_ffmpeg(self.root, {'modules': {'ffmpeg': {}}},
                                      sdk_version='27.0', toolchain_version='clang test')
        process.run.assert_not_called()

    def test_ffmpeg_recipe_does_not_inherit_parent_project_git_history(self):
        project_root = Path(__file__).resolve().parents[1]
        recipe = project_root / 'scripts/feasibility/ffmpeg/build.sh'
        fake_project = self.root / 'fake-project'
        fake_recipe = fake_project / 'scripts/feasibility/ffmpeg/build.sh'
        fake_recipe.parent.mkdir(parents=True)
        shutil.copyfile(recipe, fake_recipe)
        # This test isolates configure's Git ancestry from the independently
        # built codec prerequisite. Actual codec compilation has native acceptance.
        (fake_project / 'scripts/ffmpeg_codec_build.py').write_text(
            '# Owned prerequisite boundary for the configure/Git ancestry test.\n')
        subprocess.run(['git', 'init', '-q', str(fake_project)], check=True)
        archive_path = self.root / 'fixture.tar.gz'
        configure = (b'#!/bin/sh\n'
                     b'git -C "$(dirname "$0")" rev-parse --show-toplevel '
                     b'> ../visible-git-root 2>/dev/null || :\n'
                     b'exit 23\n')
        with tarfile.open(archive_path, 'w:gz') as archive:
            entry = tarfile.TarInfo('ffmpeg-fixture/configure')
            entry.mode = 0o755
            entry.size = len(configure)
            archive.addfile(entry, io.BytesIO(configure))
        checksum = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        dependency_root = fake_project / '.build/dependencies/ffmpeg'
        dependency_root.mkdir(parents=True, exist_ok=True)
        environment = os.environ.copy()
        environment.pop('GIT_CEILING_DIRECTORIES', None)
        baseline = subprocess.run(['git', '-C', str(dependency_root), 'rev-parse', '--show-toplevel'],
                                  capture_output=True, text=True, check=True, env=environment)
        self.assertEqual(Path(baseline.stdout.strip()).resolve(), fake_project.resolve())
        with tempfile.TemporaryDirectory(prefix='.build-test-version-', dir=dependency_root) as stage:
            result = subprocess.run(['bash', str(fake_recipe), str(archive_path), checksum, stage],
                                    capture_output=True, text=True, check=False, env=environment)
            self.assertNotEqual(result.returncode, 0)
            visible_git_root = Path(stage) / 'visible-git-root'
            self.assertTrue(visible_git_root.is_file(), result.stderr)
            self.assertEqual(visible_git_root.read_text(), '')


if __name__ == '__main__':
    unittest.main()
