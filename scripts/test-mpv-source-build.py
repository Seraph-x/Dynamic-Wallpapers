#!/usr/bin/env python3
"""Offline source-input and build-record regressions; no native playback."""
import copy
import hashlib
import importlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest


def digest(data):
    return hashlib.sha256(data).hexdigest()


class SourceInputTests(unittest.TestCase):
    def module(self):
        self.assertIsNotNone(importlib.util.find_spec('mpv_source_inputs'),
                             'source input verification is not implemented')
        return importlib.import_module('mpv_source_inputs')

    def archive(self, root, name='source/COPYING', *, link=None):
        archive = root / 'source.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            entry = tarfile.TarInfo(name)
            if link is None:
                entry.size = 7
                output.addfile(entry, io.BytesIO(b'license'))
            else:
                entry.type = tarfile.SYMTYPE
                entry.linkname = link
                output.addfile(entry)
        return archive

    def lock(self, root):
        archive = self.archive(root)
        value = {'schema_version': 1, 'architecture': 'arm64', 'minimum_macos': '14.0',
                 'libraries': ['libmpv.2.dylib'], 'components': [{
                     'name': 'mpv', 'version': '0.38.0+18', 'revision': 'a' * 40,
                     'role': 'runtime', 'license': 'GPL-2.0-or-later',
                     'license_files': ['COPYING'], 'artifact': {
                         'path': archive.name, 'url': 'https://example.com/source.tar.gz',
                         'sha256': digest(archive.read_bytes()), 'size': archive.stat().st_size}}]}
        path = root / 'lock.json'
        path.write_text(json.dumps(value))
        return path, value

    def test_pinned_source_bytes_and_notices_are_checked(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            path, _ = self.lock(root)
            lock = module.load_source_lock(root, path)
            module.verify_sources(root, lock)
            (root / 'source.tar.gz').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                module.verify_sources(root, lock)

    def test_archive_rejects_escape_and_links_without_partial_extraction(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            for member, link in [('../escape', None), ('source/link', '../outside')]:
                archive = self.archive(root, member, link=link)
                destination = root / 'extracted'
                with self.assertRaisesRegex(ValueError, 'archive'):
                    module.extract_source(archive, destination)
                self.assertFalse(destination.exists())

    def test_duplicate_components_and_invalid_source_paths_are_rejected(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            path, value = self.lock(root)
            original = copy.deepcopy(value)
            value['components'].append(copy.deepcopy(value['components'][0]))
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                module.load_source_lock(root, path)
            value = original
            value['components'][0]['artifact']['path'] = '../escape'
            path.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                module.load_source_lock(root, path)

    def test_contained_upstream_symlink_is_extracted_without_following_it(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            archive = self.archive(root, 'source/alias', link='COPYING')
            destination = root / 'extracted'
            module.extract_source(archive, destination)
            self.assertTrue((destination / 'alias').is_symlink())
            self.assertEqual((destination / 'alias').readlink(), Path('COPYING'))

    def test_required_original_notice_must_exist_in_actual_archive(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            path, value = self.lock(root)
            value['components'][0]['license_files'] = ['MISSING']
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'notice'):
                module.verify_sources(root, module.load_source_lock(root, path))


class BuildRecordTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / '.build/media-source-complete/mpv'
        (self.output / 'runtime-lib').mkdir(parents=True)
        (self.output / 'include/mpv').mkdir(parents=True)
        for name in ('client.h', 'render.h'):
            (self.output / 'include/mpv' / name).write_text(name)
        (self.output / 'runtime-lib/libmpv.2.dylib').write_bytes(b'actual image fixture')
        self.lock = {'architecture': 'arm64', 'minimum_macos': '14.0',
                     'libraries': ['libmpv.2.dylib']}
        self.inputs = {'lock': 'a' * 64, 'recipe': 'b' * 64}
        self.environment = {'sdk': '27.0', 'clang': 'test clang'}
        self.image = SimpleNamespace(minimum_macos='14.0', sdk_version='27.0',
                                     dependencies=('/usr/lib/libSystem.B.dylib',))

    def module(self):
        self.assertIsNotNone(importlib.util.find_spec('mpv_build_record'),
                             'source build record verification is not implemented')
        return importlib.import_module('mpv_build_record')

    def inspect(self, _path):
        return ('arm64',), self.image

    def write(self):
        module = self.module()
        module.write_record(self.output, self.lock, inputs=self.inputs,
                            environment=self.environment, inspect=self.inspect,
                            verify_signature=lambda _: None)
        return module

    def verify(self, module):
        return module.verify_record(self.output, self.lock, inputs=self.inputs,
                                    environment=self.environment, inspect=self.inspect,
                                    verify_signature=lambda _: None)

    def test_record_binds_inputs_environment_headers_and_library_bytes(self):
        module = self.write()
        record = self.verify(module)
        self.assertEqual(record['inputs'], self.inputs)
        self.assertEqual(record['environment'], self.environment)
        self.assertEqual(set(record['libraries']), {'libmpv.2.dylib'})
        self.assertEqual(set(record['headers']), {'client.h', 'render.h'})

    def test_modified_output_header_input_or_environment_is_rejected(self):
        for target in ('library', 'header', 'input', 'environment'):
            with self.subTest(target=target):
                self.setUp()
                module = self.write()
                if target == 'library':
                    (self.output / 'runtime-lib/libmpv.2.dylib').write_bytes(b'changed')
                elif target == 'header':
                    (self.output / 'include/mpv/client.h').write_text('changed')
                elif target == 'input':
                    self.inputs['recipe'] = 'c' * 64
                else:
                    self.environment['clang'] = 'changed clang'
                with self.assertRaises(ValueError):
                    self.verify(module)

    def test_unclosed_dependency_wrong_architecture_and_minimum_os_are_rejected(self):
        module = self.module()
        for architectures, minimum, dependency in [
                (('x86_64',), '14.0', '/usr/lib/libSystem.B.dylib'),
                (('arm64',), '15.0', '/usr/lib/libSystem.B.dylib'),
                (('arm64',), '14.0', '@rpath/libunrecorded.dylib')]:
            image = SimpleNamespace(minimum_macos=minimum, sdk_version='27.0',
                                    dependencies=(dependency,))
            with self.subTest(architectures=architectures, minimum=minimum), \
                    self.assertRaises(ValueError):
                module.inspect_products(self.output, self.lock, environment=self.environment,
                                        inspect=lambda _: (architectures, image),
                                        verify_signature=lambda _: None)

    def test_missing_record_never_accepts_existing_products(self):
        with self.assertRaises(FileNotFoundError):
            self.verify(self.module())

    def test_duplicate_json_keys_in_record_are_rejected(self):
        module = self.write()
        (self.output / 'build-record.json').write_text('{"schema_version":1,"schema_version":1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.verify(module)


class BuildProfileTests(unittest.TestCase):
    def module(self):
        self.assertIsNotNone(importlib.util.find_spec('mpv_source_build'),
                             'controlled build recipe is not implemented')
        return importlib.import_module('mpv_source_build')

    def test_build_environment_excludes_inherited_library_search_paths(self):
        module = self.module()
        environment = module.build_environment(
            Path('/isolated/prefix'), Path('/SDK'), Path('/ninja'),
            inherited={'PATH': '/bad', 'CPATH': '/bad/include',
                       'LIBRARY_PATH': '/bad/lib', 'PKG_CONFIG_PATH': '/bad/pc'})
        self.assertNotIn('CPATH', environment)
        self.assertNotIn('LIBRARY_PATH', environment)
        self.assertNotIn('PKG_CONFIG_PATH', environment)
        self.assertEqual(environment['PKG_CONFIG_LIBDIR'], '/isolated/prefix/lib/pkgconfig')
        self.assertEqual(environment['MACOSX_DEPLOYMENT_TARGET'], '14.0')

    def test_profile_retains_required_bridge_options_and_native_decode_features(self):
        module = self.module()
        root = Path(__file__).resolve().parents[1]
        recipes = module.load_recipes(root)
        mpv = ' '.join(str(arg) for command in recipes['mpv']['commands'] for arg in command)
        self.assertIn('-Dlua=lua52', mpv)
        self.assertIn('-Dcoreaudio=enabled', mpv)
        self.assertIn('-Dgl=disabled', mpv)
        ffmpeg = ' '.join(str(arg) for command in recipes['ffmpeg']['commands'] for arg in command)
        self.assertIn('--enable-videotoolbox', ffmpeg)
        self.assertIn('--enable-audiotoolbox', ffmpeg)
        self.assertIn('--enable-libdav1d', ffmpeg)
        for compression in ('zlib', 'bzlib', 'lzma'):
            self.assertIn('--enable-' + compression, ffmpeg)
        self.assertIn('-I{prefix}/include', ffmpeg)
        self.assertIn('-L{prefix}/lib', ffmpeg)
        self.assertIn('--disable-autodetect', ffmpeg)
        self.assertNotIn('--disable-decoders', ffmpeg)
        self.assertNotIn('--disable-demuxers', ffmpeg)

    def test_changed_inputs_during_build_cannot_be_bound_to_finished_products(self):
        module = self.module()
        self.assertTrue(hasattr(module, 'assert_inputs_unchanged'),
                        'build provenance does not detect edits made during compilation')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); recipe = root / 'recipe.py'
            recipe.write_bytes(b'original')
            inputs = {'recipe.py': digest(recipe.read_bytes())}
            module.assert_inputs_unchanged(root, inputs)
            recipe.write_bytes(b'changed while build was running')
            with self.assertRaisesRegex(ValueError, 'changed during build'):
                module.assert_inputs_unchanged(root, inputs)

    def test_shared_source_sdk_and_macho_helpers_are_part_of_recipe_identity(self):
        module = self.module()
        for name in ('media_dependencies.py', 'media_bundle_macho.py', 'swift_sdk.py'):
            self.assertIn('scripts/' + name, module.INPUT_FILES)


if __name__ == '__main__':
    unittest.main()
