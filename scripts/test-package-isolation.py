#!/usr/bin/env python3
"""Prove package metadata and WallpaperCore do not require prepared media products."""
import json
import shutil
import subprocess
import sys
from pathlib import Path
import re
import tempfile
import unittest
from types import SimpleNamespace

import media_dependencies


ROOT = Path(__file__).resolve().parents[1]


class PackageIsolationTests(unittest.TestCase):
    def copy_package(self, temporary):
        shutil.copy2(ROOT / 'Package.swift', temporary / 'Package.swift')
        shutil.copytree(ROOT / 'Sources', temporary / 'Sources')
        shutil.copytree(ROOT / 'Tests', temporary / 'Tests')
        (temporary / 'scripts').mkdir(parents=True)
        shutil.copy2(ROOT / 'scripts/product-configuration.json',
                     temporary / 'scripts/product-configuration.json')
        shutil.copy2(ROOT / 'scripts/media-dependencies.json',
                     temporary / 'scripts/media-dependencies.json')
        shutil.copy2(ROOT / 'scripts/mpv-source-lock.json',
                     temporary / 'scripts/mpv-source-lock.json')

    @staticmethod
    def dump_package(temporary):
        return subprocess.run(
            ['swift', 'package', '--package-path', str(temporary), '--disable-sandbox', 'dump-package'],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    def test_package_and_core_are_isolated_from_media_products(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            self.copy_package(temporary)

            subprocess.run(['swift', 'package', '--package-path', str(temporary),
                            '--disable-sandbox', 'describe'], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            subprocess.run([sys.executable, str(ROOT / 'scripts/swift_sdk.py'), 'build',
                            '--package-path', str(temporary), '--disable-sandbox',
                            '--target', 'WallpaperCore'], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

            missing_input = temporary / '.build/dependencies/cef/cef_binary_152.0.6_macosarm64_minimal.tar.bz2'
            with self.assertRaisesRegex(FileNotFoundError, re.escape(str(missing_input))):
                media_dependencies.verify_build_dependencies(temporary, ('cef',))

            lock = media_dependencies.load_lock(temporary / 'scripts/media-dependencies.json', temporary)
            missing_header = temporary / ('.build/dependencies/cef/'
                'cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal/include/cef_app.h')
            with self.assertRaisesRegex(ValueError,
                                        f'PREPARED DEPENDENCY INVALID.*{re.escape(str(missing_header))}'):
                media_dependencies.verify_prepared_dependencies(
                    lock, temporary / '.build/dependencies', ('cef',),
                    product_target=SimpleNamespace(
                        architecture='arm64', minimum_macos='14.0'))

    def test_manifest_rejects_malformed_product_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            self.copy_package(temporary)
            (temporary / 'scripts/product-configuration.json').write_text('{')
            result = self.dump_package(temporary)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('Invalid scripts/product-configuration.json', result.stdout)

    def test_manifest_rejects_duplicate_keys_at_every_product_object_level(self):
        replacements = {
            'root': ('"schema_version": 1', '"schema_version": 1, "schema_version": 1'),
            'target': ('"architecture": "arm64"',
                       '"architecture": "arm64", "architecture": "arm64"'),
            'application': ('"swiftpm_product": "DynamicWallpaper"',
                            '"swiftpm_product": "DynamicWallpaper", '
                            '"swiftpm_product": "DynamicWallpaper"'),
            'screen_saver': ('"principal_class": "DynamicWallpaperScreenSaverView"',
                             '"principal_class": "DynamicWallpaperScreenSaverView", '
                             '"principal_class": "DynamicWallpaperScreenSaverView"'),
            'cef_helper': ('"role": "main"', '"role": "main", "role": "main"'),
            'swift_target': ('"name": "WallpaperCore"',
                             '"name": "WallpaperCore", "name": "WallpaperCore"'),
        }
        source = (ROOT / 'scripts/product-configuration.json').read_text()
        for level, (needle, replacement) in replacements.items():
            with self.subTest(level=level), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                self.copy_package(temporary)
                path = temporary / 'scripts/product-configuration.json'
                path.write_text(source.replace(needle, replacement, 1))
                result = self.dump_package(temporary)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('Duplicate JSON key', result.stdout)

    def test_manifest_rejects_unknown_missing_and_cyclic_product_configuration(self):
        source = json.loads((ROOT / 'scripts/product-configuration.json').read_text())
        mutations = {
            'unknown root': lambda document: document.update(unexpected=True),
            'invalid semantic version': lambda document: document.update(version='01.2.3'),
            'missing application field': lambda document: document['application'].pop(
                'swiftpm_product'),
            'unknown target field': lambda document: document['screen_saver_targets'][0].update(
                unexpected=True),
            'cycle': lambda document: document['screen_saver_targets'][0].update(
                dependencies=['WallpaperNative']),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                self.copy_package(temporary)
                document = json.loads(json.dumps(source))
                mutate(document)
                (temporary / 'scripts/product-configuration.json').write_text(
                    json.dumps(document))
                result = self.dump_package(temporary)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('Invalid scripts/product-configuration.json', result.stdout)


if __name__ == '__main__':
    unittest.main()
