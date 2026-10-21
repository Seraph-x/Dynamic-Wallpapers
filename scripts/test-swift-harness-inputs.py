#!/usr/bin/env python3
"""Check artifact selection without compiling or launching an application."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('swift-harness-inputs.sh').resolve()


class HarnessInputTests(unittest.TestCase):
    def inspect(self, directory):
        return subprocess.run(['bash', '-eu', '-c',
            'BIN="$1"; source "$2"; printf "%s\\n" "${SWIFT_HARNESS_IMPORTS[@]}" '
            '"${SWIFT_CORE_OBJECTS[@]}" "${SWIFT_NATIVE_OBJECTS[@]}" "${SWIFT_WEB_OBJECTS[@]}"',
            'harness-input-test', str(directory), str(SCRIPT)],
            text=True, capture_output=True, timeout=60)

    def test_swift_build_consolidated_objects(self):
        with tempfile.TemporaryDirectory(prefix='swift build ') as root:
            directory = Path(root) / 'out/Products/Debug'
            directory.mkdir(parents=True)
            for name in ('WallpaperCore.o', 'WallpaperNative.o', 'WebWallpaperBridge.o'):
                (directory / name).touch()
            result = self.inspect(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Swift Build consolidated objects', result.stdout)
            self.assertIn(str(directory / 'WallpaperCore.o'), result.stdout.splitlines())
            self.assertIn(str(directory / 'WallpaperNative.o'), result.stdout.splitlines())
            self.assertIn(str(directory / 'WebWallpaperBridge.o'), result.stdout.splitlines())
            self.assertIn('-fmodule-map-file=', result.stdout)
            self.assertNotIn('WallpaperCore.build', result.stdout)

    def test_legacy_swiftpm_per_source_objects(self):
        with tempfile.TemporaryDirectory(prefix='swift native ') as root:
            directory = Path(root)
            for name in ('Modules', 'WallpaperCore.build', 'WallpaperNative.build', 'WebWallpaperBridge.build'):
                (directory / name).mkdir()
            for name in ('WallpaperCore.build/Core.swift.o', 'WallpaperNative.build/MediaSurface.swift.o',
                         'WebWallpaperBridge.build/WebPage.mm.o'):
                (directory / name).touch()
            result = self.inspect(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('legacy SwiftPM per-source objects', result.stdout)
            self.assertIn(str(directory / 'WallpaperCore.build/Core.swift.o'), result.stdout.splitlines())
            self.assertIn(str(directory / 'WallpaperNative.build/MediaSurface.swift.o'), result.stdout.splitlines())
            self.assertIn(str(directory / 'WebWallpaperBridge.build/WebPage.mm.o'), result.stdout.splitlines())

    def test_missing_native_objects_fail_explicitly_in_both_layouts(self):
        for consolidated in (True, False):
            with self.subTest(consolidated=consolidated), tempfile.TemporaryDirectory() as root:
                directory = Path(root)
                if consolidated:
                    for name in ('WallpaperCore.o', 'WebWallpaperBridge.o'):
                        (directory / name).touch()
                else:
                    for name in ('Modules', 'WallpaperCore.build', 'WallpaperNative.build', 'WebWallpaperBridge.build'):
                        (directory / name).mkdir()
                    (directory / 'WallpaperCore.build/Core.swift.o').touch()
                    (directory / 'WebWallpaperBridge.build/WebPage.mm.o').touch()
                result = self.inspect(directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Missing WallpaperNative', result.stderr)

    def test_unknown_layout_is_an_explicit_failure(self):
        with tempfile.TemporaryDirectory() as root:
            result = self.inspect(Path(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unsupported Swift build artifact layout', result.stderr)


if __name__ == '__main__':
    unittest.main()
