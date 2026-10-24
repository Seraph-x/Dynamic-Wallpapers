import pathlib
import plistlib
import tempfile
import unittest
from localization_bundle import CONFIG, RESOURCE_BUNDLE, prepare_localizations


class AudioCaptureLocalizationTests(unittest.TestCase):
    def test_permission_strings_are_copied_to_main_bundle_in_every_language(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / 'build/DynamicWallpaper'
            binary.parent.mkdir()
            source = binary.parent / RESOURCE_BUNDLE
            source.mkdir()
            (source / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleDevelopmentRegion': 'en'}))
            for language in CONFIG.localizations:
                folder = source / f'{language}.lproj'
                folder.mkdir()
                (folder / 'Localizable.strings').write_text('"test" = "test";')
                (folder / 'InfoPlist.strings').write_text('"NSAudioCaptureUsageDescription" = "Audio permission";')
            app = root / 'Candidate.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            prepare_localizations(binary, app)
            for language in CONFIG.localizations:
                self.assertEqual((app / f'Contents/Resources/{language}.lproj/InfoPlist.strings').read_text(),
                                 '"NSAudioCaptureUsageDescription" = "Audio permission";')


if __name__ == '__main__':
    unittest.main()
