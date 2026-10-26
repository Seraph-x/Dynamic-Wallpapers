#!/usr/bin/env python3
"""Verify real Editor resource variants and top-level audio permission strings."""
from pathlib import Path
import runpy
import shutil
import tempfile
import unittest
from editor_product import application_metadata, load_editor_product
ROOT = Path(__file__).resolve().parents[1]
PACKAGING = runpy.run_path(str(ROOT / 'scripts/build-editor-app.py'))


class EditorAudioPackagingTests(unittest.TestCase):
    def fixture(self, directory):
        resources = Path(directory) / 'Resources'
        bundle = resources / PACKAGING['RESOURCE_BUNDLE']
        bundle.mkdir(parents=True)
        for name in ('EditorWeb', 'ScenePreviewWeb'):
            shutil.copytree(ROOT / 'Editor/Sources/EditorApp/Resources' / name, bundle / name)
        for language in ('en', 'zh-Hans', 'ja', 'fr', 'es'):
            target = bundle / f'{language}.lproj'
            target.mkdir()
            (target/'Localizable.strings').write_text('"ready" = "Ready";')
            (target/'InfoPlist.strings').write_text('"NSAudioCaptureUsageDescription" = "Analyze system audio only when enabled.";')
        return resources, bundle

    def test_editor_metadata_requests_system_audio_without_microphone_permission(self):
        metadata = application_metadata(ROOT, load_editor_product(ROOT / 'Editor/product.json'))
        self.assertTrue(metadata.get('NSAudioCaptureUsageDescription'))
        self.assertNotIn('NSMicrophoneUsageDescription', metadata)

    def test_permission_strings_are_copied_to_actual_application_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            resources, bundle = self.fixture(directory)
            PACKAGING['prepare_audio_permission_localizations'](resources)
            for language in ('en', 'zh-Hans', 'ja', 'fr', 'es'):
                name = f'{language}.lproj/InfoPlist.strings'
                self.assertEqual((resources / name).read_bytes(), (bundle / name).read_bytes())
            (bundle / 'ja.lproj/InfoPlist.strings').unlink()
            with self.assertRaises((ValueError, FileNotFoundError)):
                PACKAGING['prepare_audio_permission_localizations'](resources)

    def test_offline_gate_accepts_recorded_editor_shell_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            resources, bundle = self.fixture(directory)
            PACKAGING['verify_offline_resources'](resources, ROOT)
            shell = bundle / 'ScenePreviewWeb/scene-shell.mjs'
            shell.write_bytes((ROOT / 'Sources/WallpaperApp/Resources/SceneRuntime/scene-shell.mjs').read_bytes())
            with self.assertRaisesRegex(ValueError, 'resource|provenance|differs'):
                PACKAGING['verify_offline_resources'](resources, ROOT)

    def test_offline_gate_requires_observer_and_checks_workbench_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            resources, bundle = self.fixture(directory)
            observer = bundle / 'ScenePreviewWeb/scene-preview-api.mjs'
            original = observer.read_bytes()
            observer.unlink()
            with self.assertRaises((ValueError, FileNotFoundError)):
                PACKAGING['verify_offline_resources'](resources, ROOT)
            observer.write_bytes(original)
            (bundle / 'EditorWeb/runtime.mjs').write_text('throw Error("tampered");')
            with self.assertRaisesRegex(ValueError, 'resource|provenance|differs'):
                PACKAGING['verify_offline_resources'](resources, ROOT)


if __name__ == '__main__':
    unittest.main()
