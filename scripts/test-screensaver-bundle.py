#!/usr/bin/env python3
"""Build and exercise the product screen saver without installing or selecting it."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from dataclasses import replace
from unittest import mock

from media_bundle_macho import parse_load_commands
from test import run_tests

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / 'scripts/build-screensaver.py'
HELPER = ROOT / 'scripts/screensaver_bundle.py'
RESOURCES = ROOT / 'Resources/ScreenSaver'
TARGET = f'{platform.machine()}-apple-macosx14.0'
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1EAAAAASUVORK5CYII=')


def checked(command, **kwargs):
    result = subprocess.run(list(map(str, command)), text=True, capture_output=True, **kwargs)
    if result.returncode != 0:
        raise AssertionError(result.stdout + result.stderr)
    return result


def make_export(root, *, corrupt_manifest=False, damaged_media=False):
    export_id, generation, media = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    generation_dir = root / 'generations' / str(generation).upper()
    media_dir = generation_dir / 'media'
    media_dir.mkdir(parents=True)
    (root / 'staging').mkdir()
    for path in (root / '.catalog.lock', root / '.publication.lock', generation_dir / '.lease'):
        path.write_bytes(b'')
    image = media_dir / 'fixture.png'; image.write_bytes(PNG)
    revision = {'value': 'a' * 64}
    manifest = {
        'schemaVersion': 1, 'generationID': str(generation), 'sourceRevision': revision,
        'source': {'kind': 'media', 'id': str(media)}, 'name': 'Bundle Fixture',
        'entries': [{'id': str(media), 'mediaID': str(media),
                     'timing': {'mode': 'seconds', 'seconds': 30, 'loops': 1},
                     'audio': {'isMuted': True, 'volume': 1}}],
        'files': [{'id': str(media), 'relativePath': 'media/fixture.png', 'kind': 'image',
                   'backend': 'native', 'width': 1, 'height': 1, 'byteCount': len(PNG),
                   'sha256': hashlib.sha256(PNG).hexdigest()}],
        'mode': 'repeatOne', 'transition': 0, 'isMuted': True, 'fit': 'fill'}
    (generation_dir / 'manifest.json').write_text('not JSON' if corrupt_manifest else json.dumps(manifest))
    if damaged_media:
        image.write_bytes(image.read_bytes() + b'changed after publication')
    (root / 'export.json').write_text(json.dumps({'schemaVersion': 1,
        'format': 'local.dynamicwallpaper.screensaver.export', 'id': str(export_id)}))
    (root / 'current.json').write_text(json.dumps({'schemaVersion': 1, 'exportID': str(export_id),
        'generationID': str(generation), 'sourceRevision': revision,
        'settingsRevision': str(uuid.uuid4()), 'publishedAt': 0}))


class MetadataTests(unittest.TestCase):
    def test_staged_metadata_and_compiler_flags_follow_configuration(self):
        spec = importlib.util.spec_from_file_location('screensaver_configuration', HELPER)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        configuration = replace(
            module.CONFIG,
            version='1.2.3',
            build='44',
            target=replace(module.CONFIG.target, architecture='x86_64',
                           minimum_macos='13.1', swift_language_mode='6'),
            development_localization='zh-Hans',
            localizations=tuple(reversed(module.CONFIG.localizations)),
            screen_saver=replace(module.CONFIG.screen_saver,
                                 executable='TestScreenSaver',
                                 display_name='Test Screen Saver'),
        )
        metadata = module.staged_metadata(configuration=configuration)
        self.assertEqual(metadata['CFBundleShortVersionString'], '1.2.3')
        self.assertEqual(metadata['CFBundleVersion'], '44')
        self.assertEqual(metadata['CFBundleExecutable'], 'TestScreenSaver')
        self.assertEqual(metadata['CFBundleDevelopmentRegion'], 'zh-Hans')
        self.assertEqual(metadata['CFBundleLocalizations'],
                         list(reversed(module.CONFIG.localizations)))

        target = configuration.screen_saver_targets[0]
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(module, 'checked') as checked, \
                mock.patch.object(module, 'source_files', return_value=[Path('Fixture.swift')]):
            module.compile_module(target, Path(directory), '/SDK', configuration)
        command = list(checked.call_args.args[0])
        self.assertIn('x86_64-apple-macosx13.1', command)
        self.assertEqual(command[command.index('-swift-version') + 1], '6')

    def test_every_localization_contains_recoverable_failure_messages(self):
        required = {
            'failure.authorizationRequired', 'failure.corruptBookmark', 'failure.staleBookmark',
            'failure.accessDenied', 'failure.notDirectory', 'failure.identityChanged',
            'failure.invalidExport', 'failure.saveFailed', 'failure.defaultsUnavailable',
            'failure.closed', 'failure.generic',
        }
        for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'):
            path = RESOURCES / f'{language}.lproj/Localizable.strings'
            values = json.loads(subprocess.check_output(
                ['plutil', '-convert', 'json', '-o', '-', path], text=True))
            self.assertTrue(required.issubset(values), f'{language}: missing {sorted(required - values.keys())}')

    def test_missing_and_invalid_metadata_are_rejected_before_output(self):
        self.assertTrue(HELPER.is_file(), 'screensaver_bundle.py is missing')
        spec = importlib.util.spec_from_file_location('screensaver_bundle', HELPER)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='screensaver metadata ', dir=ROOT / '.build') as directory:
            source = Path(directory)
            with self.assertRaises((FileNotFoundError, ValueError)): module.load_metadata(source)
            original = plistlib.loads((RESOURCES / 'Info.plist').read_bytes())
            for changed in ({**original, 'CFBundlePackageType': 'APPL'},
                            {k: v for k, v in original.items() if k != 'NSPrincipalClass'},
                            {**original, 'CFBundleExecutable': '../../../outside'}):
                (source / 'Info.plist').write_bytes(plistlib.dumps(changed))
                with self.assertRaises(ValueError): module.load_metadata(source)

    def test_swift_bookmark_negative_controls(self):
        result = checked([sys.executable, ROOT / 'scripts/test.py', '--filter', 'BookmarkAccessTests'])
        self.assertIn('Executed 7 tests, with 0 failures', result.stdout + result.stderr)


class ProductBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='screensaver product ', dir=ROOT / '.build')
        cls.work = Path(cls.temporary.name)
        cls.bundle = cls.work / 'Dynamic Wallpaper Screen Saver.saver'
        checked([sys.executable, BUILDER, '--output', cls.bundle])
        cls.harness_bundle = cls.work / 'Isolated Harness.saver'
        shutil.copytree(cls.bundle, cls.harness_bundle)
        harness_info_path = cls.harness_bundle / 'Contents/Info.plist'
        harness_info = plistlib.loads(harness_info_path.read_bytes())
        harness_info['CFBundleIdentifier'] = f'local.dynamicwallpaper.screensaver.tests.{uuid.uuid4().hex}'
        harness_info_path.write_bytes(plistlib.dumps(harness_info))
        checked(['codesign', '--force', '--sign', '-', '--timestamp=none', cls.harness_bundle])
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        cls.harness = cls.work / 'BundleHarness'
        checked(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                 '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                 '-parse-as-library', '-swift-version', '5',
                 ROOT / 'Tests/ScreenSaverBundleHarness/main.swift',
                 '-framework', 'ScreenSaver', '-framework', 'AppKit', '-framework', 'AVFoundation',
                 '-o', cls.harness])

    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()

    def test_real_bundle_metadata_signature_resources_and_dependency_closure(self):
        info = plistlib.loads((self.bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundlePackageType'], 'BNDL')
        self.assertEqual(info['CFBundleIdentifier'], 'local.dynamicwallpaper.screensaver')
        self.assertEqual(info['NSPrincipalClass'], 'DynamicWallpaperScreenSaverView')
        binary = self.bundle / 'Contents/MacOS' / info['CFBundleExecutable']
        self.assertRegex(subprocess.check_output(['xcrun', 'otool', '-hv', binary], text=True), r'\bBUNDLE\b')
        self.assertEqual(subprocess.check_output(['lipo', '-archs', binary], text=True).split(), [platform.machine()])
        commands = parse_load_commands(subprocess.check_output(['otool', '-m', '-l', binary], text=True))
        self.assertEqual(tuple(map(int, commands.minimum_macos.split('.')[:2])), (14, 0))
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
        self.assertEqual(commands.sdk_version, sdk)
        checked(['codesign', '--verify', '--strict', self.bundle])
        linked = subprocess.check_output(['otool', '-L', binary], text=True)
        dependencies = [line.strip().split(' (')[0] for line in linked.splitlines()[1:]]
        self.assertTrue(dependencies)
        self.assertTrue(all(value.startswith(('/System/Library/', '/usr/lib/')) for value in dependencies), linked)
        strings = subprocess.check_output(['strings', binary], text=True, errors='replace')
        self.assertNotIn(str(ROOT), strings)
        self.assertNotRegex('\n'.join(dependencies) + strings,
                            r'(?i)(\.app/Contents/MacOS/DynamicWallpaper|libmpv|Chromium Embedded|/\.build/)')
        for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'):
            self.assertTrue((self.bundle / f'Contents/Resources/{language}.lproj/Localizable.strings').is_file())

    def test_harness_bundle_uses_an_isolated_defaults_domain(self):
        product = plistlib.loads((self.bundle / 'Contents/Info.plist').read_bytes())
        harness = plistlib.loads((self.harness_bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(product['CFBundleIdentifier'], 'local.dynamicwallpaper.screensaver')
        self.assertTrue(harness['CFBundleIdentifier'].startswith('local.dynamicwallpaper.screensaver.tests.'))
        self.assertNotEqual(harness['CFBundleIdentifier'], product['CFBundleIdentifier'])

    def test_existing_output_is_preserved(self):
        output = self.work / 'Existing.saver'; output.mkdir(); sentinel = output / 'sentinel'
        sentinel.write_text('preserve')
        result = subprocess.run([sys.executable, BUILDER, '--output', output], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), 'preserve')

    def test_signed_bundle_tampering_is_rejected(self):
        damaged = self.work / 'Damaged.saver'
        shutil.copytree(self.bundle, damaged)
        strings = damaged / 'Contents/Resources/en.lproj/Localizable.strings'
        strings.write_text(strings.read_text() + '\n"tampered" = "tampered";\n')
        spec = importlib.util.spec_from_file_location('screensaver_bundle_verifier', HELPER)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with self.assertRaises(subprocess.CalledProcessError):
            module.verify_bundle(damaged)

    def test_copied_bundle_loads_and_displays_actual_snapshot_pixels(self):
        copied = self.work / 'Relocated.saver'; shutil.copytree(self.harness_bundle, copied)
        export = self.work / 'ValidExport'; export.mkdir(); make_export(export)
        result = checked([self.harness, copied, export, 'configured'])
        self.assertIn('"actualPixels":true', result.stdout)

    def test_real_bundle_releases_and_restores_pixels_on_power_signals(self):
        export = self.work / 'PowerCycleExport'; export.mkdir(); make_export(export)
        result = checked([self.harness, self.harness_bundle, export, 'configured-power-cycle'])
        self.assertIn('"powerCycle":true', result.stdout)
        self.assertIn('"stopped":true', result.stdout)

    def test_unconfigured_corrupt_manifest_and_wrong_identity_fail_explicitly(self):
        valid = self.work / 'NegativeExport'; valid.mkdir(); make_export(valid)
        result = checked([self.harness, self.harness_bundle, valid, 'unconfigured'])
        self.assertIn('"state":"authorizationRequired"', result.stdout)
        result = checked([self.harness, self.harness_bundle, valid, 'wrong-identity'])
        self.assertIn('"state":"failed"', result.stdout)
        corrupt = self.work / 'CorruptExport'; corrupt.mkdir(); make_export(corrupt, corrupt_manifest=True)
        result = checked([self.harness, self.harness_bundle, corrupt, 'corrupt'])
        self.assertIn('"state":"failed"', result.stdout)

    def test_zero_sized_system_host_does_not_break_failure_view_constraints(self):
        valid = self.work / 'ZeroSizedExport'; valid.mkdir(); make_export(valid)
        result = checked([self.harness, self.harness_bundle, valid, 'zero-sized-unconfigured'])
        self.assertIn('"state":"authorizationRequired"', result.stdout)
        self.assertNotIn('Unable to simultaneously satisfy constraints', result.stderr)
        self.assertNotIn('layout constraints are not satisfiable', result.stderr)

    def test_damaged_media_failure_names_the_file_instead_of_directing_reauthorization(self):
        damaged = self.work / 'DamagedMediaExport'; damaged.mkdir()
        make_export(damaged, damaged_media=True)
        result = checked([self.harness, self.harness_bundle, damaged, 'damaged-media'])
        self.assertIn('"state":"failed"', result.stdout)


if __name__ == '__main__':
    if '--worker' not in sys.argv:
        raise SystemExit(run_tests([sys.executable, str(Path(__file__).resolve()), '--worker', *sys.argv[1:]],
                                   label='Product screen saver bundle tests'))
    unittest.main(argv=[sys.argv[0], *[value for value in sys.argv[1:] if value != '--worker']])
