#!/usr/bin/env python3
import copy
from pathlib import Path
import unittest
import runpy
from editor_product import load_editor_product, helper_configuration, application_metadata

ROOT = Path(__file__).resolve().parents[1]

class EditorProductTests(unittest.TestCase):
    def test_distribution_gate_catches_other_checkout_paths(self):
        check = runpy.run_path(str(ROOT / 'scripts/build-editor-app.py'))['check_personal_paths']
        for value in (b'/Use' + b'rs/build-owner/other-checkout/wrapper.cc',
                      b'/ho' + b'me/build-owner/source/',
                      b'C:\\Us' + b'ers\\build-owner\\source'):
            with self.assertRaises(ValueError): check(value)
        check(b'/private/tmp/editor-source/scene.cc')
        check(b'https://www.quad9.net/home/privacy/')
        check(b'/cast/chromecast/home/wallpaper/collections?rt=b')

    def test_own_version_helpers_and_url_scheme_are_independent_from_main(self):
        product = load_editor_product(ROOT / 'Editor/product.json')
        self.assertEqual(product['version'], '0.1.0')
        helpers = helper_configuration(ROOT, product)
        self.assertEqual(helpers['application']['executable'], 'DynamicWallpaperEditor')
        self.assertTrue(all(item['bundle_identifier'].startswith('local.dynamicwallpaper.editor.') for item in helpers['cef_helpers']))
        metadata = application_metadata(ROOT, product)
        self.assertEqual(metadata['CFBundleURLTypes'][0]['CFBundleURLSchemes'], ['dynamic-wallpaper-editor'])
        self.assertEqual(metadata['DWHostBundleIdentifier'], 'local.dynamicwallpaper.app')
        self.assertEqual(metadata['DWEditorExchangeAPI'], '1')
        self.assertFalse(metadata['LSUIElement'])

    def test_invalid_configuration_cannot_become_bundle_paths_or_helper_ids(self):
        original = load_editor_product(ROOT / 'Editor/product.json')
        for key,value in [('executable','../Main'),('name','A/B'),('bundleIdentifier','file:///tmp/x'),('architecture','x86_64'),
                          ('version',True),('build','zero'),('urlScheme','https')]:
            invalid = copy.deepcopy(original); invalid[key] = value
            with self.assertRaises(ValueError, msg=str((key,value))):
                helper_configuration(ROOT, invalid)

if __name__ == '__main__': unittest.main()
