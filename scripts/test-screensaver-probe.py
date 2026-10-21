#!/usr/bin/env python3
"""Exercise the real native screen saver probe builder, without system installation."""
from pathlib import Path
import fcntl
import json
import os
import platform
import plistlib
import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
import uuid

from test import run_tests

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / 'scripts/feasibility/screensaver/build.py'
TARGET = f'{platform.machine()}-apple-macosx14.0'


class ProbeBundleTests(unittest.TestCase):
    def test_existing_output_is_never_replaced(self):
        with tempfile.TemporaryDirectory(prefix='screensaver existing ', dir=ROOT / '.build') as directory:
            bundle = Path(directory) / 'Existing.saver'
            bundle.mkdir()
            sentinel = bundle / 'preserve.txt'
            sentinel.write_bytes(b'original artifact')
            result = subprocess.run([sys.executable, str(BUILDER), '--output', str(bundle)],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('already exists', result.stderr)
            self.assertEqual(sentinel.read_bytes(), b'original artifact')
            self.assertEqual(list(bundle.iterdir()), [sentinel])

    def test_missing_sources_and_invalid_metadata_fail_before_publication(self):
        spec = importlib.util.spec_from_file_location('screensaver_probe_build', BUILDER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='screensaver invalid ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            source = work / 'inputs'
            source.mkdir()
            output = work / 'NeverPublished.saver'
            with self.assertRaises(FileNotFoundError):
                module.build(output, source=source)
            (source / 'Info.plist').write_bytes(plistlib.dumps({'CFBundlePackageType': 'APPL'}))
            with self.assertRaisesRegex(ValueError, 'metadata'):
                module.build(output, source=source)
            (source / 'Info.plist').write_bytes((BUILDER.parent / 'Info.plist').read_bytes())
            with self.assertRaises(FileNotFoundError):
                module.build(output, source=source)
            self.assertFalse(output.exists())

    def test_malformed_or_incomplete_metadata_is_rejected(self):
        spec = importlib.util.spec_from_file_location('screensaver_probe_build', BUILDER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = plistlib.loads((BUILDER.parent / 'Info.plist').read_bytes())
        invalid = [b'not a plist', b'<?xml version="1.0"?><plist><dict>', plistlib.dumps([])]
        for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'NSPrincipalClass',
                    'CFBundleName', 'CFBundleVersion', 'CFBundleShortVersionString', 'LSMinimumSystemVersion'):
            invalid.append(plistlib.dumps({k: v for k, v in original.items() if k != key}))
        invalid.append(plistlib.dumps({**original, 'CFBundleExecutable': '../../../outside'}))
        with tempfile.TemporaryDirectory(prefix='screensaver metadata ', dir=ROOT / '.build') as directory:
            source = Path(directory)
            output = source / 'unpublished' / 'Invalid.saver'
            for metadata in invalid:
                with self.subTest(metadata=metadata):
                    (source / 'Info.plist').write_bytes(metadata)
                    with self.assertRaisesRegex(ValueError, 'metadata'):
                        module.build(output, source=source)
                    self.assertFalse(output.parent.exists())

    def test_corrupt_manifest_stops_the_host_timer_and_reports_failure(self):
        with tempfile.TemporaryDirectory(prefix='screensaver corrupt ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            export = work / 'Export'
            export.mkdir()
            (export / '.lease').write_bytes(b'')
            (export / 'probe.json').write_text('not JSON')
            bundle = work / 'Native Probe.saver'
            result = subprocess.run([sys.executable, str(BUILDER), '--output', str(bundle)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            plist = bundle / 'Contents/Info.plist'
            info = plistlib.loads(plist.read_bytes())
            info['CFBundleIdentifier'] += '.test.' + uuid.uuid4().hex
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            harness = work / 'ProbeHarness'
            result = subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                '-parse-as-library', '-swift-version', '5', str(ROOT / 'Tests/ScreenSaverProbeHarness/main.swift'),
                '-framework', 'ScreenSaver', '-framework', 'AppKit', '-o', str(harness)],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(harness), str(bundle), str(export), '--expect-failure'],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('"failureObserved":true', result.stdout)

    def test_native_fixtures_render_real_pixels_and_stop(self):
        with tempfile.TemporaryDirectory(prefix='screensaver pixels ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            for output, source in [('MakeFixtures', BUILDER.parent / 'MakeFixtures.swift'),
                                   ('ProbeHarness', ROOT / 'Tests/ScreenSaverProbeHarness/main.swift')]:
                result = subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                    '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                    '-parse-as-library', '-swift-version', '5', str(source),
                    '-framework', 'ScreenSaver', '-framework', 'AppKit', '-o', str(work / output)],
                    text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            export = work / 'Export'
            result = subprocess.run([str(work / 'MakeFixtures'), str(export)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            bundle = work / 'Native Probe.saver'
            result = subprocess.run([sys.executable, str(BUILDER), '--output', str(bundle)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            plist = bundle / 'Contents/Info.plist'
            info = plistlib.loads(plist.read_bytes())
            info['CFBundleIdentifier'] += '.test.' + uuid.uuid4().hex
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
            result = subprocess.run([str(work / 'ProbeHarness'), str(bundle), str(export)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('"realMediaPlayback":true', result.stdout)
            self.assertIn('"restartVerified":true', result.stdout)
            self.assertEqual(result.stdout.count('"realMediaPlayback":true'), 2)
            print(result.stdout.strip())

    def test_principal_class_has_configuration_and_exposes_unconfigured_start(self):
        with tempfile.TemporaryDirectory(prefix='screensaver load ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            bundle = work / 'Native Probe.saver'
            result = subprocess.run([sys.executable, str(BUILDER), '--output', str(bundle)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # A private test identity prevents an installed probe's preferences from influencing this check.
            plist = bundle / 'Contents/Info.plist'
            info = plistlib.loads(plist.read_bytes())
            info['CFBundleIdentifier'] += '.test.' + uuid.uuid4().hex
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True,
                           capture_output=True)
            harness = work / 'ProbeHarness'
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            result = subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                '-parse-as-library', '-swift-version', '5',
                str(ROOT / 'Tests/ScreenSaverProbeHarness/main.swift'),
                '-framework', 'ScreenSaver', '-framework', 'AppKit', '-o', str(harness)],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(harness), str(bundle)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('"systemHostVerified":false', result.stdout)

    def test_real_bookmark_and_independent_read_only_leases(self):
        with tempfile.TemporaryDirectory(prefix='screensaver access ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            export = work / 'Export'
            export.mkdir()
            (export / '.lease').write_bytes(b'')
            (export / 'fixture.txt').write_text('real local fixture')
            harness = work / 'AccessHarness'
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            result = subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                '-parse-as-library', '-swift-version', '5',
                str(ROOT / 'Tests/ScreenSaverProbeHarness/AccessMain.swift'),
                str(BUILDER.parent / 'ProbeAccess.swift'), '-o', str(harness)],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(harness), str(export)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('"independentReadOnlyLeases":true', result.stdout)

    def test_bookmark_reopens_across_processes_and_corruption_fails(self):
        with tempfile.TemporaryDirectory(prefix='screensaver processes ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            export = work / 'Export'
            export.mkdir()
            (export / '.lease').write_bytes(b'')
            (export / 'fixture.txt').write_text('real local fixture')
            harness = work / 'AccessProcess'
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            self.checked_command(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                '-parse-as-library', '-swift-version', '5',
                str(ROOT / 'Tests/ScreenSaverProbeHarness/AccessProcess.swift'),
                str(BUILDER.parent / 'ProbeAccess.swift'), '-o', str(harness)])
            domain = 'local.dynamicwallpaper.screensaver.test.' + uuid.uuid4().hex
            command = [str(harness), str(export), domain]
            readers = []
            try:
                self.checked_command([*command, 'authorize'])
                with (export / '.lease').open('rb') as lease:
                    for _ in range(2):
                        reader = subprocess.Popen([*command, 'hold'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                        readers.append(reader)
                        self.assertEqual(json.loads(reader.stdout.readline()), {'leaseHeld': True, 'fixtureRead': True})
                    for reader in tuple(readers):
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        out, err = reader.communicate('close\n')
                        readers.remove(reader)
                        self.assertEqual(reader.returncode, 0, out + err)
                        self.assertIn('"leaseReleased":true', out)
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.checked_command([*command, 'invalidate'])
                failed = subprocess.run([*command, 'hold'], input='close\n', text=True, capture_output=True)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn('ACCESS PROCESS FAILED:', failed.stderr)
                self.assertNotIn('"leaseHeld":true', failed.stdout)
                print('{"crossProcessReadOnlyLeases":true,"bookmarkReopened":true,'
                      '"corruptBookmarkRejected":true,"systemHostVerified":false}')
            finally:
                for reader in readers:
                    out, err = reader.communicate('close\n')
                    self.assertEqual(reader.returncode, 0, out + err)
                self.checked_command([*command, 'clear'])

    def checked_command(self, command):
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_fifo_lease_is_rejected_without_blocking_or_saving_a_bookmark(self):
        with tempfile.TemporaryDirectory(prefix='screensaver fifo ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            export = work / 'Export'
            export.mkdir()
            os.mkfifo(export / '.lease')
            harness = work / 'AccessProcess'
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            self.checked_command(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                '-parse-as-library', '-swift-version', '5',
                str(ROOT / 'Tests/ScreenSaverProbeHarness/AccessProcess.swift'),
                str(BUILDER.parent / 'ProbeAccess.swift'), '-o', str(harness)])
            command = [str(harness), str(export), 'local.dynamicwallpaper.screensaver.test.' + uuid.uuid4().hex]
            try:
                # A no-writer FIFO must fail immediately; timeout is a failure, not a passing rejection.
                result = subprocess.run([*command, 'authorize'], text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('Lease is not a regular file', result.stderr)
                unconfigured = subprocess.run([*command, 'hold'], input='close\n', text=True, capture_output=True, timeout=5)
                self.assertEqual(unconfigured.returncode, 1, unconfigured.stdout + unconfigured.stderr)
                self.assertIn('尚未授权测试目录', unconfigured.stderr)
            finally:
                self.checked_command([*command, 'clear'])

    def test_delayed_first_decoded_frame_gets_its_visible_hold_interval(self):
        with tempfile.TemporaryDirectory(prefix='screensaver timing ', dir=ROOT / '.build') as directory:
            work = Path(directory)
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            for name, sources in (
                ('MakeFixtures', [BUILDER.parent / 'MakeFixtures.swift']),
                ('PlaybackTiming', [ROOT / 'Tests/ScreenSaverProbeHarness/PlaybackTiming.swift',
                                    BUILDER.parent / 'ProbePlayback.swift'])):
                self.checked_command(['xcrun', 'swiftc', '-sdk', sdk, '-target', TARGET,
                    '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk,
                    '-parse-as-library', '-swift-version', '5', *map(str, sources),
                    '-framework', 'AppKit', '-o', str(work / name)])
            self.checked_command([str(work / 'MakeFixtures'), str(work / 'Export')])
            result = self.checked_command([str(work / 'PlaybackTiming'), str(work / 'Export')])
            self.assertIn('"delayedFirstFrameHoldVerified":true', result.stdout)
            print(result.stdout.strip())

    def test_builds_real_signed_bundle_with_only_system_dependencies(self):
        with tempfile.TemporaryDirectory(prefix='screensaver test ', dir=ROOT / '.build') as directory:
            bundle = Path(directory) / 'Native Probe.saver'
            result = subprocess.run([sys.executable, str(BUILDER), '--output', str(bundle)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['CFBundlePackageType'], 'BNDL')
            self.assertEqual(info['CFBundleIdentifier'], 'local.dynamicwallpaper.screensaver.probe')
            self.assertEqual(info['NSPrincipalClass'], 'DWNativeScreenSaverProbeView')
            binary = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
            header = subprocess.check_output(['xcrun', 'otool', '-hv', str(binary)], text=True)
            self.assertRegex(header, r'\bBUNDLE\b')
            subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
            linked = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
            dependencies = [line.strip().split(' (')[0] for line in linked.splitlines()[1:]]
            self.assertTrue(dependencies, linked)
            for dependency in dependencies:
                self.assertRegex(dependency, r'^/(System/Library|usr/lib)/')
            self.assertNotRegex('\n'.join(dependencies), re.escape(str(ROOT)))


if __name__ == '__main__':
    if '--worker' not in sys.argv:
        raise SystemExit(run_tests([sys.executable, str(Path(__file__).resolve()), '--worker',
                                    *sys.argv[1:]], label='ScreenSaver probe tests'))
    unittest.main(argv=[sys.argv[0], *[value for value in sys.argv[1:] if value != '--worker']])
