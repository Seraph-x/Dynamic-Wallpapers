#!/usr/bin/env python3
"""Offline parser/path/transaction tests; no app, media, SPM or signing."""
import importlib
import hashlib
import json
import pathlib
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from types import SimpleNamespace
from unittest import mock

macho = importlib.import_module('media_bundle_macho')
bundle = importlib.import_module('media_bundle')
materials_module = importlib.import_module('media_bundle_materials')
PRODUCT_TARGET = SimpleNamespace(architecture='arm64', minimum_macos='14.0')


def write_screensaver_fixture(bundle_path, overrides=None):
    contents = bundle_path / 'Contents'
    executable = contents / 'MacOS/DynamicWallpaperScreenSaver'
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_bytes(b'screen saver executable fixture')
    executable.chmod(0o755)
    info = {
        'CFBundlePackageType': 'BNDL',
        'CFBundleIdentifier': 'local.dynamicwallpaper.screensaver',
        'CFBundleExecutable': 'DynamicWallpaperScreenSaver',
        'CFBundleName': 'Dynamic Wallpaper Screen Saver',
        'CFBundleDisplayName': 'Dynamic Wallpaper Screen Saver',
        'CFBundleShortVersionString': '0.3.0',
        'CFBundleVersion': '3',
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleLocalizations': ['zh-Hans', 'en', 'ja', 'fr', 'es'],
        'LSMinimumSystemVersion': '14.0',
        'NSPrincipalClass': 'DynamicWallpaperScreenSaverView',
        'NSHighResolutionCapable': True,
        'DWApplicationBundleIdentifier': 'local.dynamicwallpaper.app',
    }
    info.update(overrides or {})
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'):
        strings = contents / f'Resources/{language}.lproj/Localizable.strings'
        strings.parent.mkdir(parents=True, exist_ok=True)
        strings.write_text('"fixture" = "fixture";\n')
    return bundle_path


def write_payload_fixture(app):
    paths = ['Contents/MacOS/DynamicWallpaper', 'Contents/Resources/AppIcon.icns',
             'Contents/Resources/MediaTools/ffmpeg', 'Contents/Resources/MediaTools/ffprobe',
             'Contents/Resources/ThirdParty/distribution-status.json']
    paths += [f'Contents/Resources/DynamicWallpaper_WallpaperApp.bundle/{language}.lproj/Localizable.strings'
              for language in ('zh-hans', 'en', 'ja', 'fr', 'es')]
    framework = f'Contents/Frameworks/{bundle.FRAMEWORK}'
    paths += [f'{framework}/{name}' for name in ('Chromium Embedded Framework',
        'Libraries/libcef_sandbox.dylib', 'Libraries/libvk_swiftshader.dylib', 'Libraries/libvulkan.dylib',
        'Libraries/vk_swiftshader_icd.json', 'Resources/icudtl.dat', 'Resources/resources.pak',
        'Resources/chrome_100_percent.pak', 'Resources/chrome_200_percent.pak',
        'Resources/v8_context_snapshot.arm64.bin', 'Resources/gpu_shader_cache.bin')]
    for suffix, role, identifier in bundle.HELPERS:
        name = f'DynamicWallpaper Helper{suffix}'
        contents = app / f'Contents/Frameworks/{name}.app/Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name,
            'CFBundleIdentifier': identifier,
            'CFBundleShortVersionString': '0.3.0', 'CFBundleVersion': '3'}))
        paths.append(f'Contents/Frameworks/{name}.app/Contents/MacOS/{name}')
    for relative in paths:
        path = app / relative; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'payload layout fixture'); path.chmod(0o755)
    (app / 'Contents/Info.plist').write_bytes(
        plistlib.dumps(bundle.product_application_metadata(bundle.CONFIG)))
    (app / 'Contents/Resources/ThirdParty/README.md').write_text(
        f'{bundle.CONFIG.application.swiftpm_product} '
        f'{bundle.CONFIG.version}/build {bundle.CONFIG.build}\n')
    (app / 'Contents/Resources/DynamicWallpaper_WallpaperApp.bundle/Info.plist').write_bytes(
        plistlib.dumps({'CFBundleDevelopmentRegion': 'en'}))
    help_source = pathlib.Path(__file__).resolve().parents[1] / 'Sources/WallpaperApp/Help'
    shutil.copytree(help_source, app / 'Contents/Resources/DynamicWallpaper_WallpaperApp.bundle/Help')
    write_screensaver_fixture(app / 'Contents/PlugIns/Dynamic Wallpaper Screen Saver.saver')


class MachOChecks(unittest.TestCase):
    def test_nested_screensaver_is_signed_before_outer_application(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            saver = app / 'Contents/PlugIns/Dynamic Wallpaper Screen Saver.saver'
            saver.mkdir(parents=True)
            commands = []
            with mock.patch.object(macho, 'macho_files', return_value=[]), \
                 mock.patch.object(macho, 'run', side_effect=lambda command: commands.append(command) or ''):
                macho.sign_bundle(app)
            signed = [pathlib.Path(command[-1]) for command in commands
                      if command[:4] == ['codesign', '--force', '--sign', '-']]
            self.assertLess(signed.index(saver), signed.index(app))

    def test_nested_screensaver_image_uses_its_own_bundle_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            saver = app / 'Contents/PlugIns/Dynamic Wallpaper Screen Saver.saver'
            write_screensaver_fixture(saver)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'DynamicWallpaper',
            }))
            outer_executable = app / 'Contents/MacOS/DynamicWallpaper'
            outer_executable.parent.mkdir(parents=True)
            outer_executable.write_bytes(b'outer fixture')
            executable = saver / 'Contents/MacOS/DynamicWallpaperScreenSaver'
            header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 8, 0, 0, 0, 0)
            executable.write_bytes(header)
            self.assertEqual(macho.nearest_executable(executable, app), executable.resolve())

    def test_native_resource_bundle_layout_is_packaged_with_all_languages_and_help(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Native.app'
            write_payload_fixture(app)
            resources = app / 'Contents/Resources/DynamicWallpaper_WallpaperApp.bundle'
            contents = resources / 'Contents'
            contents.mkdir()
            native_resources = contents / 'Resources'
            native_resources.mkdir()
            for child in list(resources.iterdir()):
                if child == contents:
                    continue
                destination = contents if child.name == 'Info.plist' else native_resources
                shutil.move(str(child), destination / child.name)
            chinese = native_resources / 'zh-hans.lproj'
            chinese.rename(native_resources / 'zh-Hans.lproj')
            bundle.required_payload(app, [])
            (native_resources / 'zh-Hans.lproj/Localizable.strings').unlink()
            with self.assertRaisesRegex(ValueError, 'localization'):
                bundle.required_payload(app, [])

    def test_each_packaged_language_is_required(self):
        for language in ('zh-hans', 'en', 'ja', 'fr', 'es'):
            with self.subTest(language=language), tempfile.TemporaryDirectory() as directory:
                app = pathlib.Path(directory) / 'Candidate.app'
                write_payload_fixture(app)
                (app / f'Contents/Resources/DynamicWallpaper_WallpaperApp.bundle/{language}.lproj/Localizable.strings').unlink()
                with self.assertRaisesRegex(ValueError, 'localization'):
                    bundle.required_payload(app, [])

    def test_application_declares_the_supported_localizations(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            write_payload_fixture(app)
            info_path = app / 'Contents/Info.plist'
            info = plistlib.loads(info_path.read_bytes())
            info.pop('CFBundleLocalizations')
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, 'localization'):
                bundle.required_payload(app, [])

    def test_inspection_accepts_cef_helper_executable_names_with_parentheses(self):
        with tempfile.TemporaryDirectory() as directory:
            image = pathlib.Path(directory) / 'DynamicWallpaper Helper (Renderer)'
            header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)
            build_version = struct.pack('<6I', 0x32, 24, 1, 0xe0000, 0xe0000, 0)
            image.write_bytes(header + build_version)
            architecture, commands = macho.inspect_image(image)
            self.assertEqual(architecture, ('arm64',))
            self.assertEqual(commands.minimum_macos, '14.0')

    def test_bundled_standalone_tool_uses_its_own_executable_path(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            tool = app / 'Contents/Resources/MediaTools/ffmpeg'
            tool.parent.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'DynamicWallpaper'}))
            tool.write_bytes(struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0))
            self.assertEqual(macho.nearest_executable(tool, app), tool.resolve())

    def test_load_commands_preserve_spaces_and_do_not_treat_id_as_dependency(self):
        parsed = macho.parse_load_commands('''Load command 0
      cmd LC_ID_DYLIB
     name @rpath/liba.dylib (offset 24)
Load command 1
      cmd LC_LOAD_DYLIB
     name @rpath/Some Framework.framework/Some Framework (offset 24)
Load command 2
      cmd LC_RPATH
     path @loader_path/../Libraries (offset 12)
Load command 3
      cmd LC_BUILD_VERSION
 platform 1
    minos 14.0
      sdk 26.5
''')
        self.assertEqual(parsed.dependencies, ('@rpath/Some Framework.framework/Some Framework',))
        self.assertEqual(parsed.rpaths, ('@loader_path/../Libraries',))
        self.assertEqual(parsed.minimum_macos, '14.0')

    def test_missing_or_non_macos_deployment_target_is_rejected(self):
        for text in ('Load command 0\n cmd LC_LOAD_DYLIB\n name x (offset 24)',
                     'Load command 0\n cmd LC_BUILD_VERSION\n platform 2\n minos 14.0'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                macho.parse_load_commands(text)

    def test_legacy_minimum_and_weak_dependency_are_retained(self):
        parsed = macho.parse_load_commands('''Load command 0
 cmd LC_VERSION_MIN_MACOSX
 version 11.0
Load command 1
 cmd LC_LOAD_WEAK_DYLIB
 name /usr/lib/libc++.1.dylib (offset 24)
''')
        self.assertEqual(parsed.minimum_macos, '11.0')
        self.assertEqual(parsed.dependencies, ('/usr/lib/libc++.1.dylib',))

    def test_architecture_and_minimum_are_real_constraints(self):
        macho.validate_target(
            ('arm64',), '14.0', expected_architecture='arm64', maximum_macos='14.0')
        for arch, minimum in [(('x86_64',), '14.0'), (('arm64',), '14.1')]:
            with self.subTest(arch=arch, minimum=minimum), self.assertRaises(ValueError):
                macho.validate_target(
                    arch, minimum, expected_architecture='arm64', maximum_macos='14.0')

    def test_target_validation_uses_injected_product_constraints(self):
        macho.validate_target(
            ('x86_64',), '13.0', expected_architecture='x86_64', maximum_macos='13.0')

    def test_system_prefix_cannot_hide_path_traversal(self):
        self.assertTrue(macho.is_system_path('/usr/lib/libSystem.B.dylib'))
        self.assertFalse(macho.is_system_path('/usr/lib/../../../tmp/libbad.dylib'))
        self.assertFalse(macho.is_system_path('/opt/homebrew/lib/libbad.dylib'))

    def test_bundle_resolution_requires_actual_inside_file_and_rejects_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            executable = app / 'Contents/MacOS/DynamicWallpaper'
            library = app / 'Contents/Frameworks/MPV/liba.dylib'
            executable.parent.mkdir(parents=True); library.parent.mkdir(parents=True)
            executable.write_bytes(b'executable'); library.write_bytes(b'library')
            resolved = macho.resolve_reference('@rpath/liba.dylib', image=executable,
                executable=executable, bundle=app, rpaths=('@executable_path/../Frameworks/MPV',))
            self.assertEqual(resolved, library.resolve())
            with self.assertRaises(ValueError):
                macho.resolve_reference('@rpath/missing.dylib', image=executable,
                    executable=executable, bundle=app, rpaths=('@executable_path/../Frameworks/MPV',))
            outside = pathlib.Path(directory) / 'outside.dylib'; outside.write_bytes(b'outside')
            library.unlink(); library.symlink_to(outside)
            with self.assertRaises(ValueError):
                macho.resolve_reference('@rpath/liba.dylib', image=executable,
                    executable=executable, bundle=app, rpaths=('@executable_path/../Frameworks/MPV',))

    def test_duplicate_rpath_must_not_produce_ambiguous_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'; app.mkdir()
            (app / 'A').mkdir(); (app / 'B').mkdir()
            for folder in ('A', 'B'): (app / folder / 'same.dylib').write_bytes(b'x')
            executable = app / 'main'; executable.write_bytes(b'x')
            with self.assertRaises(ValueError):
                macho.resolve_reference('@rpath/same.dylib', image=executable,
                    executable=executable, bundle=app, rpaths=('@loader_path/A', '@loader_path/B'))

    def test_rewrite_plan_removes_external_rpaths_and_preserves_system(self):
        commands = macho.rpath_rewrite_commands(pathlib.Path('/stage/app'),
            ('/usr/lib/swift', '/Applications/Xcode.app/Toolchains/lib', '/opt/homebrew/lib',
             '/external/vendor/lib', '@loader_path'),
            required=('@executable_path/../Frameworks/MPV',))
        flattened = [argument for command in commands for argument in command]
        self.assertEqual(flattened.count('-delete_rpath'), 3)
        self.assertNotIn('/usr/lib/swift', flattened)
        self.assertIn('@executable_path/../Frameworks/MPV', flattened)


class PackagingTransactions(unittest.TestCase):
    def test_application_metadata_tracks_each_configured_product_field(self):
        base = bundle.CONFIG
        first_helper = replace(
            base.cef_helpers[0], bundle_identifier='test.helper.identifier')
        cases = [
            (replace(base, version='1.2.3'), 'CFBundleShortVersionString', '1.2.3'),
            (replace(base, build='44'), 'CFBundleVersion', '44'),
            (replace(base, development_localization='zh-Hans'),
             'CFBundleDevelopmentRegion', 'zh-Hans'),
            (replace(base, localizations=tuple(reversed(base.localizations))),
             'CFBundleLocalizations', list(reversed(base.localizations))),
            (replace(base, application=replace(
                base.application, bundle_identifier='test.application')),
             'CFBundleIdentifier', 'test.application'),
            (replace(base, application=replace(
                base.application, display_name='Test Display')),
             'CFBundleDisplayName', 'Test Display'),
            (replace(base, application=replace(
                base.application, executable='TestExecutable', swiftpm_product='TestExecutable')),
             'CFBundleExecutable', 'TestExecutable'),
            (replace(base, screen_saver=replace(
                base.screen_saver, bundle_name='Test Saver.saver')),
             'DWScreenSaverBundleName', 'Test Saver.saver'),
            (replace(base, target=replace(base.target, minimum_macos='13.1')),
             'LSMinimumSystemVersion', '13.1'),
            (replace(base, cef_helpers=(first_helper, *base.cef_helpers[1:])),
             'DWCEFHelpers', None),
        ]
        for configuration, key, expected in cases:
            with self.subTest(key=key):
                metadata = bundle.product_application_metadata(configuration)
                if key == 'DWCEFHelpers':
                    self.assertEqual(metadata[key][0]['bundleIdentifier'],
                                     'test.helper.identifier')
                else:
                    self.assertEqual(metadata[key], expected)

    def test_packager_loads_pinned_inputs_from_importable_dependency_module(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            payload = b'pinned packaging input'
            artifact = {'path': 'cef/source.tar.bz2', 'url': 'https://example.com/source.tar.bz2',
                        'sha256': hashlib.sha256(payload).hexdigest()}
            lock = {'schema_version': 1,
                    'modules': {'cef': {'version': '1', 'architecture': 'arm64',
                                        'minimum_macos': '13.0',
                                        'artifacts': [artifact]}}}
            (root / 'scripts').mkdir()
            (root / 'scripts/media-dependencies.json').write_text(json.dumps(lock))
            cached = root / '.build/dependencies/cef/source.tar.bz2'
            cached.parent.mkdir(parents=True)
            cached.write_bytes(payload)

            self.assertEqual(bundle.load_pinned_inputs(root), lock)

    def test_source_build_preflights_dependencies_before_swiftpm(self):
        script = pathlib.Path(__file__).with_name('package-app.py')
        spec = importlib.util.spec_from_file_location('package_app_entrypoint', script)
        entrypoint = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entrypoint)
        events = []

        def fail_preflight():
            events.append('preflight')
            raise ValueError('prepared dependency preflight failed')

        output = pathlib.Path(__file__).resolve().parents[1] / 'dist/preflight-test-never-created.app'
        with mock.patch.object(entrypoint, 'verify_build_dependencies', create=True,
                               side_effect=fail_preflight), \
             mock.patch.object(entrypoint, 'selected_sdk',
                               side_effect=lambda: events.append('swiftpm') or self.fail('SwiftPM started')), \
             mock.patch.object(sys, 'argv', [str(script), '--output', str(output)]):
            with self.assertRaisesRegex(ValueError, 'prepared dependency preflight failed'):
                entrypoint.main()
        self.assertEqual(events, ['preflight'])

    def test_source_build_requires_ffmpeg_record_before_swiftpm(self):
        script = pathlib.Path(__file__).with_name('package-app.py')
        spec = importlib.util.spec_from_file_location('package_app_record_entrypoint', script)
        entrypoint = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entrypoint)
        output = pathlib.Path(__file__).resolve().parents[1] / 'dist/record-test-never-created.app'
        with mock.patch.object(entrypoint, 'verify_build_dependencies'), \
             mock.patch.object(entrypoint, 'verify_ffmpeg_for_build',
                               side_effect=ValueError('FFmpeg build record missing')), \
             mock.patch.object(entrypoint.subprocess, 'run') as run, \
             mock.patch.object(sys, 'argv', [str(script), '--output', str(output)]):
            with self.assertRaisesRegex(ValueError, 'FFmpeg build record missing'):
                entrypoint.main()
        run.assert_not_called()

    def test_copy_dependencies_requires_record_and_copies_exact_ffmpeg_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app = root / 'Candidate.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            stage = root / 'stage'
            stage.mkdir()
            tools = root / '.build/dependencies/ffmpeg/install/bin'
            tools.mkdir(parents=True)
            expected = {}
            for name in ('ffmpeg', 'ffprobe'):
                (tools / name).write_bytes(f'local {name}'.encode())
                expected[name] = hashlib.sha256((tools / name).read_bytes()).hexdigest()
            lock = {'modules': {'cef': {'version': '1', 'artifacts': [{'path': 'cef/source'}]},
                                'mpv': {'artifacts': []}, 'ffmpeg': {'artifacts': []}}}
            with mock.patch.object(bundle, 'extract_cef_framework'), \
                 mock.patch.object(bundle, 'build_helpers', return_value={}), \
                 mock.patch.object(bundle, 'current_build_environment',
                                   return_value=('27.0', 'clang test')), \
                 mock.patch.object(bundle, 'verify_record', side_effect=ValueError('record missing')):
                with self.assertRaisesRegex(ValueError, 'record missing'):
                    bundle.copy_dependencies(root, app, stage, lock)
            with mock.patch.object(bundle, 'extract_cef_framework'), \
                 mock.patch.object(bundle, 'build_helpers', return_value={}), \
                 mock.patch.object(bundle, 'current_build_environment',
                                   return_value=('27.0', 'clang test')), \
                 mock.patch.object(bundle, 'verify_record', return_value=expected):
                result = bundle.copy_dependencies(root, app, stage, lock)
            for name in ('ffmpeg', 'ffprobe'):
                self.assertEqual((app / 'Contents/Resources/MediaTools' / name).read_bytes(),
                                 (tools / name).read_bytes())
            self.assertEqual({pathlib.Path(item['path']).name: item['sha256']
                              for item in result['media_tools']}, expected)
            (tools / 'ffmpeg').write_bytes(b'mutated after record verification')
            changed_app = root / 'Changed.app'
            (changed_app / 'Contents/Resources').mkdir(parents=True)
            with mock.patch.object(bundle, 'extract_cef_framework'), \
                 mock.patch.object(bundle, 'build_helpers', return_value={}), \
                 mock.patch.object(bundle, 'current_build_environment',
                                   return_value=('27.0', 'clang test')), \
                 mock.patch.object(bundle, 'verify_record', return_value=expected):
                with self.assertRaisesRegex(ValueError, 'SHA256'):
                    bundle.copy_dependencies(root, changed_app, stage, lock)

    def test_embedded_screensaver_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            write_payload_fixture(app)
            shutil.rmtree(app / 'Contents/PlugIns/Dynamic Wallpaper Screen Saver.saver')
            with self.assertRaisesRegex(ValueError, '[Ss]creen saver'):
                bundle.required_payload(app, [])

    def test_embedded_screensaver_metadata_and_payload_are_exact(self):
        changes = (
            {'CFBundleIdentifier': 'local.dynamicwallpaper.other'},
            {'CFBundleShortVersionString': '0.2.0'},
            {'CFBundleVersion': '2'},
            {'CFBundlePackageType': 'APPL'},
            {'CFBundleExecutable': '../outside'},
        )
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                app = pathlib.Path(directory) / 'Candidate.app'
                write_payload_fixture(app)
                saver = app / 'Contents/PlugIns/Dynamic Wallpaper Screen Saver.saver'
                write_screensaver_fixture(saver, change)
                with self.assertRaisesRegex(ValueError, '[Ss]creen saver'):
                    bundle.required_payload(app, [])

    def test_embedding_records_verified_screensaver_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = write_screensaver_fixture(root / 'Input.saver')
            app = root / 'Candidate.app'
            (app / 'Contents').mkdir(parents=True)
            verification = {
                'architectures': ['arm64'], 'minimumMacOS': '14.0', 'sdk': '27.0',
                'dependencies': ['/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit'],
            }
            with mock.patch.object(bundle, 'verify_screensaver_bundle', return_value=verification):
                provenance = bundle.embed_screensaver(source, app)
            embedded = app / 'Contents/PlugIns/Dynamic Wallpaper Screen Saver.saver'
            self.assertTrue((embedded / 'Contents/MacOS/DynamicWallpaperScreenSaver').is_file())
            self.assertEqual(provenance['bundle_identifier'], 'local.dynamicwallpaper.screensaver')
            self.assertEqual(provenance['version'], '0.3.0')
            self.assertEqual(provenance['build'], '3')
            self.assertEqual(provenance['architectures'], ['arm64'])
            self.assertEqual(provenance['sdk'], '27.0')
            self.assertEqual(len(provenance['executable_sha256']), 64)
            self.assertEqual(len(provenance['info_plist_sha256']), 64)

    def test_candidate_verification_rechecks_screensaver_signature_and_closure(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            write_payload_fixture(app)
            with mock.patch.object(bundle, 'verify_application_localizations'), \
                 mock.patch.object(bundle, 'verify_help_bundle'), \
                 mock.patch.object(bundle, 'verify_helper_metadata'), \
                 mock.patch.object(bundle, 'verify_distribution_materials', return_value={'complete': True}), \
                 mock.patch.object(bundle, 'verify_macho_closure', return_value=[]), \
                 mock.patch.object(bundle, 'run', return_value='signature'), \
                 mock.patch.object(bundle, 'verify_screensaver_bundle',
                                   side_effect=ValueError('screen saver signature invalid')):
                with self.assertRaisesRegex(ValueError, 'signature invalid'):
                    bundle.verify_candidate(app, [], configuration=bundle.CONFIG)

    def test_candidate_verification_rejects_stale_screensaver_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'
            write_payload_fixture(app)
            saver = app / 'Contents/PlugIns/Dynamic Wallpaper Screen Saver.saver'
            verification = {
                'architectures': ['arm64'], 'minimumMacOS': '14.0', 'sdk': '27.0',
                'dependencies': ['/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit'],
            }
            recorded = bundle.screensaver_provenance(saver, verification)
            recorded['executable_sha256'] = '0' * 64
            provenance = app / 'Contents/Resources/BuildProvenance.json'
            provenance.write_text(json.dumps({'screen_saver': recorded}))
            with mock.patch.object(bundle, 'verify_application_localizations'), \
                 mock.patch.object(bundle, 'verify_help_bundle'), \
                 mock.patch.object(bundle, 'verify_helper_metadata'), \
                 mock.patch.object(bundle, 'verify_distribution_materials', return_value={'complete': True}), \
                 mock.patch.object(bundle, 'verify_macho_closure', return_value=[]), \
                 mock.patch.object(bundle, 'run', return_value='signature'), \
                 mock.patch.object(bundle, 'verify_screensaver_bundle', return_value=verification):
                with self.assertRaisesRegex(ValueError, 'provenance'):
                    bundle.verify_candidate(app, [], configuration=bundle.CONFIG)

    def test_existing_binary_requires_explicit_screensaver_before_packaging(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        result = subprocess.run(
            [sys.executable, root / 'scripts/package-app.py', '--binary', root / 'missing-binary',
             '--output', root / 'dist/unused-screen-saver-test.app'],
            text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--screensaver', result.stderr)

    def test_each_packaged_help_language_is_required(self):
        for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'):
            with self.subTest(language=language), tempfile.TemporaryDirectory() as directory:
                app = pathlib.Path(directory) / 'Candidate.app'
                write_payload_fixture(app)
                (app / f'Contents/Resources/DynamicWallpaper_WallpaperApp.bundle/Help/{language}/index.html').unlink()
                with self.assertRaisesRegex(ValueError, 'help'):
                    bundle.required_payload(app, [])

    def test_display_name_keeps_the_space_without_renaming_the_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Dynamic Wallpaper.app'; write_payload_fixture(app)
            info = bundle.required_payload(app, [])
            self.assertEqual(info['CFBundleName'], 'Dynamic Wallpaper')
            self.assertEqual(info['CFBundleDisplayName'], 'Dynamic Wallpaper')
            self.assertEqual(info['CFBundleExecutable'], 'DynamicWallpaper')

    def test_joined_display_names_are_rejected(self):
        for key in ('CFBundleName', 'CFBundleDisplayName'):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                app = pathlib.Path(directory) / 'Dynamic Wallpaper.app'; write_payload_fixture(app)
                info_path = app / 'Contents/Info.plist'
                info = plistlib.loads(info_path.read_bytes()); info[key] = 'DynamicWallpaper'
                info_path.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, key):
                    bundle.required_payload(app, [])

    def test_material_manifest_covers_every_retained_file(self):
        with tempfile.TemporaryDirectory() as directory:
            materials = pathlib.Path(directory)
            notice = materials / 'notice.txt'; notice.write_bytes(b'notice')
            status = {'schema_version': 1, 'complete': False,
                'files': [{'path': 'notice.txt', 'sha256': hashlib.sha256(b'notice').hexdigest()}],
                'components': {name: {'version': 'fixed', 'license': 'retained notice', 'complete': False,
                    'license_files': ['notice.txt']} for name in ('cef', 'mpv', 'ffmpeg')}}
            (materials / 'distribution-status.json').write_text(json.dumps(status))
            self.assertFalse(materials_module.verify_distribution_materials(materials)['complete'])
            (materials / 'unlisted-source.txt').write_bytes(b'unlisted')
            with self.assertRaisesRegex(ValueError, '[Mm]anifest|[Uu]nlisted|[Cc]over'):
                materials_module.verify_distribution_materials(materials)

    def test_checked_in_materials_exclude_host_generated_paths_and_keep_incomplete_status(self):
        materials = pathlib.Path(__file__).resolve().parents[1] / 'Resources/ThirdParty'
        status = materials_module.verify_distribution_materials(materials)
        self.assertFalse(status['complete'])
        self.assertFalse(status['components']['mpv']['complete'])
        self.assertFalse(status['components']['ffmpeg']['complete'])
        removed = ('FFmpeg/buildconf.txt', 'FFmpeg/config.h', 'FFmpeg/config.mak',
                   'FFmpeg/ffprobe-version.txt', 'FFmpeg/license.txt', 'MPV/build-metadata.txt')
        for relative in removed:
            self.assertFalse((materials / relative).exists(), relative)
        for path in materials.rglob('*'):
            if path.suffix in ('.md', '.txt', '.json', '.sh', '.h'):
                content = path.read_text()
                for prefix in ('/Users/', '/private/tmp/', '/opt/homebrew/'):
                    self.assertNotIn(prefix, content, str(path))

    def test_missing_dynamically_loaded_cef_sandbox_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'; write_payload_fixture(app)
            (app / f'Contents/Frameworks/{bundle.FRAMEWORK}/Libraries/libcef_sandbox.dylib').unlink()
            with self.assertRaisesRegex(ValueError, 'Missing packaged payload'):
                bundle.required_payload(app, [])

    def test_nonexecutable_application_is_rejected_before_macho_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'; write_payload_fixture(app)
            (app / 'Contents/MacOS/DynamicWallpaper').chmod(0o644)
            with self.assertRaisesRegex(ValueError, '[Ee]xecutable'):
                bundle.required_payload(app, [])

    def test_helper_metadata_must_match_its_actual_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Candidate.app'; write_payload_fixture(app)
            info = app / 'Contents/Frameworks/DynamicWallpaper Helper (Renderer).app/Contents/Info.plist'
            data = plistlib.loads(info.read_bytes()); data['CFBundleExecutable'] = 'OtherHelper'
            info.write_bytes(plistlib.dumps(data))
            with self.assertRaisesRegex(ValueError, '[Hh]elper'):
                bundle.required_payload(app, [])

    def test_materials_cannot_claim_complete_without_notice_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            materials = root / 'Resources/ThirdParty'
            materials.mkdir(parents=True)
            (materials / 'distribution-status.json').write_text(json.dumps({'complete': True}))
            app = root / 'Candidate.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            icon = root / 'supplied.icns'; icon.write_bytes(b'icon')
            with self.assertRaisesRegex(ValueError, 'material|notice|manifest'):
                bundle.prepare_resources(root, app, root, icon)

    def test_third_party_readme_must_match_product_version_and_build(self):
        with tempfile.TemporaryDirectory() as directory:
            materials = pathlib.Path(directory)
            (materials / 'README.md').write_text('DynamicWallpaper 0.2.0/build 2\n')
            with self.assertRaisesRegex(ValueError, 'README.*version/build'):
                bundle.verify_third_party_product_label(materials, bundle.CONFIG)

    def test_output_must_be_new_app_under_this_worktree_dist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); (root / 'dist').mkdir()
            accepted = root / 'dist/candidates/0.3.0/Dynamic Wallpaper.app'
            self.assertEqual(bundle.validate_output(root, accepted), accepted)
            for target in (root / 'old.app', root / 'dist/not-an-app', root / 'dist/../bad.app'):
                with self.subTest(target=target), self.assertRaises(ValueError):
                    bundle.validate_output(root, target)
            accepted.mkdir(parents=True)
            with self.assertRaises(FileExistsError): bundle.validate_output(root, accepted)

    def test_symlinked_dist_or_parent_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); (root / 'elsewhere').mkdir()
            (root / 'dist').symlink_to(root / 'elsewhere', target_is_directory=True)
            with self.assertRaises(ValueError): bundle.validate_output(root, root / 'dist/new.app')

    def test_publish_is_exclusive_even_if_destination_is_created_after_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); staged = root / 'staged.app'; staged.mkdir()
            (staged / 'marker').write_bytes(b'new'); destination = root / 'target.app'
            destination.mkdir()
            with self.assertRaises(FileExistsError): bundle.publish_exclusively(staged, destination)
            self.assertEqual(list(destination.iterdir()), [])
            self.assertEqual((staged / 'marker').read_bytes(), b'new')
            destination.rmdir(); bundle.publish_exclusively(staged, destination)
            self.assertEqual((destination / 'marker').read_bytes(), b'new')
            self.assertFalse(staged.exists())

    def test_checked_copy_preserves_source_bytes_and_rejects_wrong_digest(self):
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); source = root / 'source'; source.write_bytes(b'locked input')
            destination = root / 'copy'
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            bundle.copy_checked(source, destination, digest)
            self.assertEqual(source.read_bytes(), b'locked input')
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            with self.assertRaises(ValueError): bundle.copy_checked(source, root / 'wrong', '0' * 64)
            self.assertFalse((root / 'wrong').exists())


if __name__ == '__main__':
    unittest.main()
