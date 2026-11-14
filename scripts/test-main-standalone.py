#!/usr/bin/env python3
"""Verify Main's package and Scene fixtures without a Wallpaper Editor checkout."""

import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MainStandaloneTests(unittest.TestCase):
    def test_package_owns_playback_without_editor_products_or_targets(self):
        result = subprocess.run(['swift', 'package', '--disable-sandbox', 'dump-package'], cwd=ROOT,
                                capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        package = json.loads(result.stdout)
        names = {entry['name'] for group in ('products', 'targets') for entry in package[group]}
        self.assertTrue({'WallpaperApp', 'WallpaperCore', 'WebWallpaperBridge'} <= names)
        self.assertFalse({name for name in names if 'Editor' in name})

    def test_property_fixtures_generate_in_an_isolated_scripts_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            isolated = Path(directory)
            scripts = isolated / 'scripts'
            scripts.mkdir()
            shutil.copyfile(ROOT / 'scripts/make-native-property-fixtures.mjs',
                            scripts / 'make-native-property-fixtures.mjs')
            fixture = ROOT / 'scripts/scene-properties-fixture.mjs'
            if fixture.exists():
                shutil.copyfile(fixture, scripts / fixture.name)
            output = isolated / 'generated'
            result = subprocess.run(['node', str(scripts / 'make-native-property-fixtures.mjs'),
                                     str(output)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            loose = json.loads((output / 'loose/project.json').read_text())
            package = json.loads((output / 'package/project.json').read_text())
            self.assertEqual(loose['file'], 'scene.json')
            self.assertEqual(package['file'], 'scene.pkg')
            self.assertEqual(loose['general']['properties']['amount']['value'], 0.25)
            self.assertEqual(loose['general'], package['general'])
            scene = (output / 'loose/scene.json').read_bytes()
            packed = (output / 'package/scene.pkg').read_bytes()
            self.assertTrue(packed.endswith(scene))
            self.assertEqual(struct.unpack_from('<I', packed)[0], len('PKGV0012'))
            self.assertEqual(packed[4:12], b'PKGV0012')
            self.assertEqual(json.loads(scene)['objects'][1]['color']['user'], 'tint')


if __name__ == '__main__':
    unittest.main()
