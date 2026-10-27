#!/usr/bin/env python3
"""Measured FFmpeg distribution evidence must be accurate and path-normalized."""
import importlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock


class BuildMaterialTests(unittest.TestCase):
    def module(self):
        self.assertIsNotNone(importlib.util.find_spec('media_build_materials'),
                             'measured public build evidence export is not implemented')
        return importlib.import_module('media_build_materials')

    def test_configuration_preserves_real_options_and_normalizes_only_known_paths(self):
        module = self.module()
        options, prefix = module.normalized_ffmpeg_configuration('''
configuration:
 --prefix=/Users/example/build/install
 --sysroot=/Applications/Xcode.app/SDK
 --disable-autodetect
 --disable-network
 --enable-static
 --disable-shared
 --enable-videotoolbox
 --extra-cflags='-mmacosx-version-min=14.0'
Exiting with exit code 0
''')
        self.assertEqual(prefix, '/Users/example/build/install')
        self.assertIn('--prefix=<BUILD_PREFIX>', options)
        self.assertIn('--sysroot=<MACOS_SDK>', options)
        self.assertIn('--extra-cflags=-mmacosx-version-min=14.0', options)
        self.assertNotIn('/Users/', str(options))

    def test_license_and_feature_evidence_rejects_nonfree_gpl_or_network_configuration(self):
        module = self.module()
        valid = ['--disable-autodetect', '--disable-network', '--disable-shared', '--enable-static']
        license_text = 'GNU Lesser General Public License version 2.1 or later'
        flags = {'GPL': 0, 'NONFREE': 0, 'VERSION3': 0, 'NETWORK': 0}
        module.verify_ffmpeg_license(valid, license_text, flags)
        for changed in [valid + ['--enable-gpl'], valid + ['--enable-nonfree'],
                        [option for option in valid if option != '--disable-network']]:
            with self.subTest(options=changed), self.assertRaises(ValueError):
                module.verify_ffmpeg_license(changed, license_text, flags)
        with self.assertRaises(ValueError):
            module.verify_ffmpeg_license(valid, 'GNU General Public License version 3', flags)
        with self.assertRaises(ValueError):
            module.verify_ffmpeg_license(valid, license_text, dict(flags, GPL=1))

    def test_known_prefix_in_explicit_include_link_flags_is_normalized(self):
        module = self.module()
        options, _prefix = module.normalized_ffmpeg_configuration(
            '--prefix=/Users/example/build --sysroot=/SDK '
            "--extra-cflags='-I/Users/example/build/include' "
            "--extra-ldflags='-L/Users/example/build/lib'")
        self.assertIn('--extra-cflags=-I<BUILD_PREFIX>/include', options)
        self.assertIn('--extra-ldflags=-L<BUILD_PREFIX>/lib', options)
        with self.assertRaisesRegex(ValueError, 'Unexpected host path'):
            module.normalized_ffmpeg_configuration(
                '--prefix=/Users/example/build --extra-cflags=-I/Users/other/include')

    def test_original_notice_copies_are_bound_to_the_actual_source_archive(self):
        module = self.module()
        self.assertTrue(hasattr(module, 'verify_original_notice_copies'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); archive = root / 'source.tar.gz'
            with tarfile.open(archive, 'w:gz') as output:
                member = tarfile.TarInfo('project/COPYING'); member.size = 8
                output.addfile(member, io.BytesIO(b'original'))
            notice = root / 'Resources/ThirdParty/MPV/notices/component/COPYING'
            notice.parent.mkdir(parents=True); notice.write_bytes(b'original')
            lock = {'components': [{'name': 'component', 'license_files': ['COPYING'],
                                     'artifact': {'path': 'source.tar.gz'}}]}
            module.verify_original_notice_copies(root, lock)
            notice.write_bytes(b'modified')
            with self.assertRaisesRegex(ValueError, 'Original notice'):
                module.verify_original_notice_copies(root, lock)

    def test_partial_native_phase_record_cannot_mark_distribution_complete(self):
        self.assertIsNotNone(importlib.util.find_spec('media_acceptance_materials'),
                             'native acceptance material validation is not implemented')
        module = importlib.import_module('media_acceptance_materials')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = root / 'acceptance.json'
            path.write_text(json.dumps({'schema_version': 1, 'passed': True,
                                         'phase_count': 1, 'phases': []}))
            with self.assertRaisesRegex(ValueError, 'complete six-fixture'):
                module.verify_native_acceptance(root, path, root)


class PackagingEvidenceBindingTests(unittest.TestCase):
    def setUp(self):
        from mpv_source_build import INPUT_FILES
        source = Path(__file__).resolve().parents[1]
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.materials = self.root / 'Resources/ThirdParty'
        for relative in ('MPV/acceptance', 'MPV/recipe'):
            shutil.copytree(source / 'Resources/ThirdParty' / relative,
                            self.materials / relative)
        for relative in ('MPV/BUILD-RECORD.json', 'FFmpeg/BUILD-RECORD.json'):
            destination = self.materials / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / 'Resources/ThirdParty' / relative, destination)
        self.mpv_record = json.loads((self.materials / 'MPV/BUILD-RECORD.json').read_text())
        self.ffmpeg_record = json.loads((self.materials / 'FFmpeg/BUILD-RECORD.json').read_text())
        for relative in (*INPUT_FILES, 'Sources/MPVBridge/MPVBridge.mm',
                         'Tests/MPVBridgeHarness/source-acceptance.mm',
                         'scripts/test-controlled-mpv.py'):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / relative, destination)
        record = self.root / '.build/media-source-complete/mpv/build-record.json'
        record.parent.mkdir(parents=True)
        shutil.copyfile(self.materials / 'MPV/BUILD-RECORD.json', record)
        self.status = self.materials / 'distribution-status.json'
        self.status.write_text(json.dumps({'components': {'mpv': {'complete': True}}}))

    def verify(self):
        import media_build_materials
        # Native/toolchain build validation is tested separately. Retain the real
        # measured files here so this test isolates packaging's evidence binding.
        with mock.patch('mpv_source_build.verify_built', return_value=self.mpv_record), \
                mock.patch.object(media_build_materials, 'verify_original_notice_copies'), \
                mock.patch.object(media_build_materials, 'ffmpeg_public_record',
                                  return_value=self.ffmpeg_record):
            media_build_materials.verify_material_build_records(
                self.root, {'modules': {'mpv': {'_source_lock': {}}}})

    def test_current_actual_native_evidence_and_recipe_are_accepted(self):
        self.verify()

    def test_packaging_rejects_actual_native_acceptance_source_drift(self):
        for relative in ('Sources/MPVBridge/MPVBridge.mm',
                         'Tests/MPVBridgeHarness/source-acceptance.mm',
                         'scripts/test-controlled-mpv.py'):
            path = self.root / relative
            original = path.read_bytes()
            with self.subTest(source=relative):
                path.write_bytes(original + b'\n// changed after acceptance\n')
                with self.assertRaisesRegex(ValueError, 'Native acceptance source changed'):
                    self.verify()
            path.write_bytes(original)

    def test_packaging_rejects_changed_distributed_recipe(self):
        path = self.materials / 'MPV/recipe/scripts/mpv-source-recipes.json'
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'Distributed MPV recipe'):
            self.verify()

    def test_complete_true_cannot_retain_acceptance_for_other_products(self):
        path = self.materials / 'MPV/acceptance/acceptance.json'
        document = json.loads(path.read_text())
        document['build_record_sha256'] = '0' * 64
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(ValueError, 'different built libraries'):
            self.verify()

    def test_complete_true_requires_retained_native_acceptance(self):
        (self.materials / 'MPV/acceptance/acceptance.json').unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()

    def test_explicitly_incomplete_materials_do_not_claim_native_acceptance(self):
        self.status.write_text(json.dumps({'components': {'mpv': {'complete': False}}}))
        shutil.rmtree(self.materials / 'MPV/acceptance')
        self.verify()


if __name__ == '__main__':
    unittest.main()
