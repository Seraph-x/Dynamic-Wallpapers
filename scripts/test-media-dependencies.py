"""Offline regression tests; no real downloads or media processes."""
import copy
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest

import media_dependencies as MODULE


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.payload = b'verified archive bytes'
        self.product_target = SimpleNamespace(architecture='arm64', minimum_macos='14.0')
        self.artifact = {'path': 'cef/source.tar.bz2', 'url': 'https://example.com/source.tar.bz2',
                         'sha256': hashlib.sha256(self.payload).hexdigest()}
        self.lock = {'schema_version': 1,
                     'modules': {'cef': {'version': '1', 'architecture': 'arm64',
                                         'minimum_macos': '13.0',
                                         'artifacts': [self.artifact]}}}
        self.lock_path = self.root / 'lock.json'

    def load(self):
        self.lock_path.write_text(json.dumps(self.lock))
        return MODULE.load_lock(self.lock_path, self.root)

    def test_valid_cache_is_read_only(self):
        path = self.root / self.artifact['path']
        path.parent.mkdir()
        path.write_bytes(self.payload)
        before = path.stat().st_mtime_ns
        MODULE.verify_artifact(self.root, self.artifact)
        self.assertEqual(path.stat().st_mtime_ns, before)

    def test_missing_cache_is_error_without_creating_directories(self):
        with self.assertRaises(FileNotFoundError):
            MODULE.verify_artifact(self.root, self.artifact)
        self.assertFalse((self.root / 'cef').exists())

    def test_corrupt_cache_is_not_replaced(self):
        path = self.root / self.artifact['path']
        path.parent.mkdir()
        path.write_bytes(b'broken')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            MODULE.prepare_artifact(self.root, self.artifact, downloader=lambda *_: self.fail('must not download'))
        self.assertEqual(path.read_bytes(), b'broken')

    def test_download_hash_failure_never_publishes(self):
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            MODULE.prepare_artifact(self.root, self.artifact, downloader=lambda _, path: path.write_bytes(b'broken'))
        self.assertFalse((self.root / self.artifact['path']).exists())
        self.assertEqual(list((self.root / 'cef').iterdir()), [])

    def test_verified_download_publishes_real_bytes(self):
        MODULE.prepare_artifact(self.root, self.artifact, downloader=lambda _, path: path.write_bytes(self.payload))
        self.assertEqual((self.root / self.artifact['path']).read_bytes(), self.payload)

    def test_downloader_failure_never_publishes_partial_file(self):
        def fail(_, path):
            path.write_bytes(self.payload[:3])
            raise OSError('network interrupted')
        with self.assertRaisesRegex(OSError, 'network interrupted'):
            MODULE.prepare_artifact(self.root, self.artifact, downloader=fail)
        self.assertEqual(list((self.root / 'cef').iterdir()), [])

    def test_concurrent_destination_is_never_overwritten(self):
        def concurrent_write(_, path):
            path.write_bytes(self.payload)
            (self.root / self.artifact['path']).write_bytes(b'other writer')
        with self.assertRaises(FileExistsError):
            MODULE.prepare_artifact(self.root, self.artifact, downloader=concurrent_write)
        self.assertEqual((self.root / self.artifact['path']).read_bytes(), b'other writer')

    def test_parent_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as other:
            (self.root / 'cef').symlink_to(other, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'symlink'):
                MODULE.prepare_artifact(self.root, self.artifact)

    def test_local_archive_import_does_not_change_source(self):
        source = self.root / 'original.tar'
        source.write_bytes(self.payload)
        MODULE.prepare_artifact(self.root, self.artifact, source=source)
        self.assertEqual(source.read_bytes(), self.payload)

    def test_cache_symlink_is_rejected(self):
        external = self.root / 'external'
        external.write_bytes(self.payload)
        (self.root / 'cef').mkdir()
        (self.root / self.artifact['path']).symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            MODULE.verify_artifact(self.root, self.artifact)

    def test_valid_lock(self):
        self.assertEqual(self.load()['modules']['cef']['artifacts'], [self.artifact])

    def test_dependency_lock_rejects_top_level_product_target(self):
        self.lock['target'] = {'architecture': 'arm64', 'minimum_macos': '14.0'}
        with self.assertRaisesRegex(ValueError, 'product target'):
            self.load()

    def test_dependency_lock_accepts_dependency_only_module_facts(self):
        self.lock['modules']['cef'].update(
            architecture='arm64', minimum_macos='13.0')
        loaded = self.load()
        self.assertEqual(loaded['modules']['cef']['architecture'], 'arm64')
        self.assertEqual(loaded['modules']['cef']['minimum_macos'], '13.0')

    def test_illegal_lock_values(self):
        original = copy.deepcopy(self.lock)
        for field, value in [('path', '../escape'), ('path', '/tmp/escape'),
                             ('sha256', 'abc'), ('sha256', 42), ('url', 'http://example.com/file')]:
            with self.subTest(field=field, value=value):
                self.lock = copy.deepcopy(original)
                self.lock['modules']['cef']['artifacts'][0][field] = value
                with self.assertRaises(ValueError):
                    self.load()

    def test_empty_or_wrong_schema_is_rejected(self):
        for value in [None, [], {}, {'schema_version': True}, {'schema_version': 2},
                      dict(self.lock, modules={})]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.lock = value
                self.load()

    def test_duplicate_cache_path_is_rejected(self):
        self.lock['modules']['cef']['artifacts'].append(copy.deepcopy(self.artifact))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.load()

    def test_changed_referenced_manifest_is_rejected(self):
        manifest = self.root / 'libraries.json'
        manifest.write_text('[]')
        self.lock['modules']['cef']['manifest'] = {'path': 'libraries.json', 'sha256': '0' * 64,
                                                  'cache_prefix': 'cef/lib'}
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            self.load()

    def test_valid_referenced_manifest_expands_artifacts(self):
        entries = [{'file': 'libmpv.2.dylib', 'sha256': self.artifact['sha256'],
                    'url': 'https://example.com/libmpv.2.dylib'}]
        manifest = self.root / 'libraries.json'
        manifest.write_text(json.dumps(entries))
        self.lock['modules']['cef']['manifest'] = {'path': 'libraries.json',
            'sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(), 'cache_prefix': 'cef/lib'}
        self.assertEqual(len(self.load()['modules']['cef']['artifacts']), 2)

    def prepared_lock(self):
        return {
            'schema_version': 1,
            'modules': {
                'cef': {'version': '1', 'architecture': 'arm64',
                        'minimum_macos': '13.0', 'artifacts': [self.artifact]},
                'mpv': {'version': '1', 'architecture': 'arm64',
                        'minimum_macos': '12.0', 'artifacts': [
                    {'path': 'mpv/include/mpv/client.h'},
                    {'path': 'mpv/include/mpv/render.h'},
                    {'path': 'mpv/lib/libmpv.2.dylib'},
                    {'path': 'mpv/lib/libdependency.1.dylib'},
                ]},
            },
        }

    def test_prepared_cef_requires_header_and_nonempty_wrapper_archive(self):
        lock = self.prepared_lock()
        dependency_root = self.root / 'dependencies'
        header = dependency_root / 'cef/cef_binary_1_macosarm64_minimal/include/cef_app.h'
        wrapper = dependency_root / 'cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a'
        with self.assertRaisesRegex(ValueError, f'PREPARED DEPENDENCY INVALID.*{header}'):
            MODULE.verify_cef_prepared(
                lock, dependency_root, product_target=self.product_target,
                archive_members=lambda _: ['member.o'])
        header.parent.mkdir(parents=True)
        header.write_text('header')
        wrapper.parent.mkdir(parents=True)
        wrapper.write_bytes(b'archive')
        with self.assertRaisesRegex(ValueError, 'PREPARED DEPENDENCY INVALID.*empty'):
            MODULE.verify_cef_prepared(
                lock, dependency_root, product_target=self.product_target,
                archive_members=lambda _: [])
        MODULE.verify_cef_prepared(
            lock, dependency_root, product_target=self.product_target,
            archive_members=lambda _: ['member.o'])

    def test_prepared_paths_cannot_escape_dependency_root(self):
        lock = self.prepared_lock()
        dependency_root = self.root / 'dependencies'
        external = self.root / 'external'
        (external / 'include').mkdir(parents=True)
        (external / 'include/cef_app.h').write_text('header')
        (dependency_root / 'cef').mkdir(parents=True)
        (dependency_root / 'cef/cef_binary_1_macosarm64_minimal').symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'PREPARED DEPENDENCY INVALID.*escapes'):
            MODULE.verify_cef_prepared(
                lock, dependency_root, product_target=self.product_target,
                archive_members=lambda _: ['member.o'])

    def make_mpv_products(self, names=('libmpv.2.dylib', 'libdependency.1.dylib')):
        dependency_root = self.root / 'dependencies'
        include = dependency_root / 'mpv/include/mpv'
        include.mkdir(parents=True)
        (include / 'client.h').write_text('client')
        (include / 'render.h').write_text('render')
        runtime = dependency_root / 'mpv/runtime-lib'
        runtime.mkdir(parents=True)
        for name in names:
            (runtime / name).write_bytes(b'inspected through injected boundary')
        return dependency_root

    @staticmethod
    def image(dependencies=(), architecture=('arm64',), minimum='12.0'):
        return architecture, SimpleNamespace(dependencies=dependencies, minimum_macos=minimum)

    def test_prepared_mpv_requires_exact_locked_runtime_library_names(self):
        dependency_root = self.make_mpv_products(names=('libmpv.2.dylib',))
        with self.assertRaisesRegex(ValueError, 'PREPARED DEPENDENCY INVALID.*runtime library set'):
            MODULE.verify_mpv_prepared(self.prepared_lock(), dependency_root,
                product_target=self.product_target,
                inspect_image=lambda _: self.image(), verify_signature=lambda _: None)

    def test_prepared_mpv_rejects_unsigned_or_non_arm64_runtime_images(self):
        dependency_root = self.make_mpv_products()
        with self.assertRaisesRegex(ValueError, 'PREPARED DEPENDENCY INVALID.*arm64'):
            MODULE.verify_mpv_prepared(self.prepared_lock(), dependency_root,
                product_target=self.product_target,
                inspect_image=lambda _: self.image(architecture=('x86_64',)), verify_signature=lambda _: None)
        with self.assertRaisesRegex(ValueError, 'PREPARED DEPENDENCY INVALID.*signature'):
            MODULE.verify_mpv_prepared(self.prepared_lock(), dependency_root,
                product_target=self.product_target,
                inspect_image=lambda _: self.image(),
                verify_signature=lambda _: (_ for _ in ()).throw(OSError('bad signature')))

    def test_prepared_mpv_rejects_unresolved_non_system_dependencies(self):
        dependency_root = self.make_mpv_products()
        with self.assertRaisesRegex(ValueError, 'PREPARED DEPENDENCY INVALID.*missing.dylib'):
            MODULE.verify_mpv_prepared(self.prepared_lock(), dependency_root,
                product_target=self.product_target,
                inspect_image=lambda path: self.image(('@rpath/missing.dylib',) if path.name == 'libmpv.2.dylib' else ()),
                verify_signature=lambda _: None)

    def test_prepared_mpv_uses_explicit_product_target(self):
        dependency_root = self.make_mpv_products()
        lock = self.prepared_lock()
        lock['modules']['mpv'].update(
            architecture='x86_64', minimum_macos='13.0')
        target = SimpleNamespace(architecture='x86_64', minimum_macos='13.0')
        MODULE.verify_mpv_prepared(
            lock, dependency_root, product_target=target,
            inspect_image=lambda _: self.image(
                architecture=('x86_64',), minimum='13.0'),
            verify_signature=lambda _: None)

    def test_verify_build_checks_inputs_before_prepared_products(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        (scripts / 'media-dependencies.json').write_text(json.dumps(self.lock))
        with self.assertRaisesRegex(FileNotFoundError, 'Missing regular cache file'):
            MODULE.verify_build_dependencies(self.root, ('cef',))


if __name__ == '__main__':
    unittest.main()
