#!/usr/bin/env python3
"""SDK propagation and link metadata regression tests; no application launch."""
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import swift_sdk
import media_bundle_macho as macho


class SwiftSDKTests(unittest.TestCase):
    def test_same_sdk_reaches_swift_compilation_and_clang_linking(self):
        sdk = Path('/Developer With Spaces/MacOSX27.0.sdk')
        original = ['--filter', 'WallpaperSnapshotTests', '--skip-build']
        command = swift_sdk.command('test', original, sdk=sdk)
        self.assertEqual(command, ['swift', 'test', '--sdk', str(sdk),
            '-Xswiftc', '-Xclang-linker', '-Xswiftc', '-isysroot',
            '-Xswiftc', '-Xclang-linker', '-Xswiftc', str(sdk), *original])
        self.assertEqual(original, ['--filter', 'WallpaperSnapshotTests', '--skip-build'])
        self.assertNotIn('-platform_version', command, 'Do not fabricate an SDK version')

    def test_sdk_selection_uses_xcrun_and_propagates_failure(self):
        with patch.object(subprocess, 'check_output', return_value='/Selected/MacOSX27.0.sdk\n') as run:
            self.assertEqual(swift_sdk.selected_sdk(), Path('/Selected/MacOSX27.0.sdk'))
            run.assert_called_once_with(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True)
        with patch.object(subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'xcrun')):
            with self.assertRaises(subprocess.CalledProcessError):
                swift_sdk.selected_sdk()

    def test_empty_sdk_path_is_not_replaced_by_current_directory(self):
        with patch.object(subprocess, 'check_output', return_value='\n'):
            with self.assertRaisesRegex(ValueError, 'SDK path'):
                swift_sdk.selected_sdk()

    def test_binary_metadata_keeps_sdk_separate_from_minimum(self):
        parsed = macho.parse_load_commands('''Load command 0
 cmd LC_BUILD_VERSION
 platform MACOS
 minos 14.0
 sdk 27.0
''')
        self.assertEqual(parsed.minimum_macos, '14.0')
        self.assertEqual(parsed.sdk_version, '27.0')

    def test_sdk_mismatch_is_explicit_and_patch_versions_are_normalized(self):
        with patch.object(swift_sdk, 'binary_sdk', return_value='14.0'):
            with self.assertRaisesRegex(ValueError, 'SDK mismatch'):
                swift_sdk.verify_linked_sdk(Path('App'), expected='27.0')
        with patch.object(swift_sdk, 'binary_sdk', return_value='27.0'):
            swift_sdk.verify_linked_sdk(Path('App'), expected='27.0.0')
        with patch.object(swift_sdk, 'binary_sdk', return_value=None):
            with self.assertRaisesRegex(ValueError, 'SDK mismatch'):
                swift_sdk.verify_linked_sdk(Path('App'), expected='27.0')


if __name__ == '__main__':
    unittest.main()
