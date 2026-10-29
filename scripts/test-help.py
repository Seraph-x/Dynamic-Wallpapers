#!/usr/bin/env python3
"""Offline help contract checks and negative controls; no app launch or user data."""
from pathlib import Path
import importlib.util
import re
import shutil
import tempfile
import unittest

from help_bundle import verify_help_bundle
from localization_bundle import LANGUAGES

ROOT = Path(__file__).resolve().parents[1]
HELP = ROOT / 'Sources/WallpaperApp/Help'
BUILD_HELP_SPEC = importlib.util.spec_from_file_location(
    'build_help', ROOT / 'scripts/build-help.py')
BUILD_HELP = importlib.util.module_from_spec(BUILD_HELP_SPEC)
BUILD_HELP_SPEC.loader.exec_module(BUILD_HELP)


class HelpBundleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / 'Help'
        shutil.copytree(HELP, self.root)

    def change_page(self, before, after, language='fr'):
        path = self.root / language / 'index.html'
        text = path.read_text()
        self.assertIn(before, text)
        path.write_text(text.replace(before, after, 1))

    def test_complete_offline_bundle(self):
        report = verify_help_bundle(self.root)
        self.assertEqual(tuple(report), LANGUAGES)
        self.assertGreater(len(report['en']['sections']), 20)

    def test_missing_language_is_not_substituted(self):
        for language in LANGUAGES:
            path = self.root / language / 'index.html'
            contents = path.read_bytes()
            path.unlink()
            with self.subTest(language=language), self.assertRaisesRegex(ValueError, 'help resource'):
                verify_help_bundle(self.root)
            path.write_bytes(contents)

    def test_styles_and_script_are_required(self):
        for name in ('help.css', 'help.js'):
            path = self.root / name
            contents = path.read_bytes()
            path.write_bytes(b'')
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'help resource'):
                verify_help_bundle(self.root)
            path.write_bytes(contents)

    def test_incorrect_page_language(self):
        self.change_page('<html lang="fr">', '<html lang="en">')
        with self.assertRaisesRegex(ValueError, 'help language'):
            verify_help_bundle(self.root)

    def test_incorrect_language_switch_target(self):
        self.change_page('href="../ja/index.html"', 'href="../en/index.html"')
        with self.assertRaisesRegex(ValueError, 'language navigation'):
            verify_help_bundle(self.root)

    def test_incorrect_current_language(self):
        self.change_page(' aria-current="page"', '')
        with self.assertRaisesRegex(ValueError, 'language navigation'):
            verify_help_bundle(self.root)

    def test_duplicate_section_id(self):
        self.change_page('id="main"', 'id="contents"')
        with self.assertRaisesRegex(ValueError, 'Duplicate help section'):
            verify_help_bundle(self.root)

    def test_missing_chapter(self):
        self.change_page('id="troubleshooting"', 'id="other"')
        with self.assertRaisesRegex(ValueError, 'Missing help chapters'):
            verify_help_bundle(self.root)

    def test_translations_must_share_section_anchors(self):
        self.change_page('</main>', '<p id="only-in-french">Extra</p></main>')
        with self.assertRaisesRegex(ValueError, 'matching section IDs'):
            verify_help_bundle(self.root)

    def test_broken_internal_anchor(self):
        self.change_page('href="#contents"', 'href="#not-a-section"')
        with self.assertRaisesRegex(ValueError, 'Missing help section'):
            verify_help_bundle(self.root)

    def test_external_resource_is_not_offline(self):
        self.change_page('href="../help.css"', 'href="https://example.com/help.css"')
        with self.assertRaisesRegex(ValueError, 'relative and offline'):
            verify_help_bundle(self.root)

    def test_link_cannot_escape_bundled_help(self):
        self.change_page('href="../help.css"', 'href="../../../outside.css"')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            verify_help_bundle(self.root)

    def test_markdown_chapters_and_links_match_across_languages(self):
        baseline = None
        for language in LANGUAGES:
            text = (ROOT / f'docs/help/{language}.md').read_text()
            anchors = re.findall(r'\{#([^}]+)\}', text)
            self.assertEqual(len(set(anchors)), len(anchors))
            if baseline is None:
                baseline = anchors
            self.assertEqual(anchors, baseline, language)
            for target in re.findall(r'\]\(([^)]+)\)', text):
                if target.startswith('#'):
                    self.assertIn(target[1:], anchors)
                else:
                    self.assertIn(target, [f'{code}.md' for code in LANGUAGES])
            self.assertNotIn('![', text)
            self.assertNotIn('<img', text)
            self.assertNotIn('[此处建议插入截图', text)
            for name in ('简体中文', 'English', '日本語', 'Français', 'Español'):
                self.assertIn(name, text)

    def test_help_readme_version_and_build_follow_product_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'docs/help', root / 'docs/help')
            (root / 'scripts').mkdir()
            shutil.copy2(ROOT / 'scripts/product-configuration.json',
                         root / 'scripts/product-configuration.json')
            readme = root / 'docs/help/README.md'
            configuration = BUILD_HELP.load_product_configuration(root / 'scripts/product-configuration.json')
            expected = f'v{configuration.version} / build {configuration.build}'
            self.assertIn(expected, readme.read_text())
            readme.write_text(readme.read_text().replace(expected, 'v0.2.0 / build 2', 1))
            with self.assertRaisesRegex(ValueError, 'README.md must name configured version/build'):
                BUILD_HELP.generated_files(root)


if __name__ == '__main__':
    unittest.main()
