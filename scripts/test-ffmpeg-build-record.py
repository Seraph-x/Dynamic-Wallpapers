#!/usr/bin/env python3
"""Local FFmpeg build evidence must bind pinned source to verified tool bytes."""

import hashlib
import importlib
import importlib.util
import json
from pathlib import Path
import tempfile
import shutil
from types import SimpleNamespace
import unittest


class FFmpegBuildRecordTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = self.root / 'scripts/feasibility/ffmpeg/build.sh'
        self.script.parent.mkdir(parents=True)
        self.script.write_bytes(b'#!/bin/sh\nexit 0\n')
        self.source = self.root / '.build/dependencies/ffmpeg/ffmpeg-n9.0.1.tar.gz'
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b'pinned source archive')
        self.bin = self.root / '.build/dependencies/ffmpeg/install/bin'
        self.bin.mkdir(parents=True)
        for name in ('ffmpeg', 'ffprobe'):
            tool = self.bin / name
            tool.write_bytes(b'local Mach-O ' + name.encode())
            tool.chmod(0o755)
        self.lock = {
            'modules': {'ffmpeg': {'architecture': 'arm64', 'minimum_macos': '14.0',
                                  'artifacts': [{
                'path': 'ffmpeg/ffmpeg-n9.0.1.tar.gz',
                'sha256': hashlib.sha256(self.source.read_bytes()).hexdigest(),
            }]}}
        }
        self.image = SimpleNamespace(
            dependencies=('/usr/lib/libSystem.B.dylib',),
            minimum_macos='14.0', sdk_version='27.0')
        self.populate_codec_inputs()

    def populate_codec_inputs(self):
        source = Path(__file__).resolve().parent.parent
        for relative in ['scripts/mpv-source-lock.json', 'scripts/mpv_source_inputs.py',
                         'scripts/media_dependencies.py', 'scripts/media_bundle_macho.py',
                         'scripts/swift_sdk.py', 'scripts/ffmpeg_build_record.py']:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / relative, destination)
        helper = self.root / 'scripts/ffmpeg_codec_build.py'
        helper.write_text('# owned codec build helper fixture\n')
        lock = json.loads((source / 'scripts/mpv-source-lock.json').read_text())
        for component in lock['components']:
            if component['name'] in ('dav1d', 'xz', 'meson', 'ninja'):
                relative = component['artifact']['path']
                destination = self.root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source / relative, destination)

    def module(self):
        self.assertIsNotNone(importlib.util.find_spec('ffmpeg_build_record'),
                             'The FFmpeg build record module is missing')
        return importlib.import_module('ffmpeg_build_record')

    def inspect(self, _path):
        return ('arm64',), self.image

    def write(self):
        module = self.module()
        module.write_record(self.root, self.lock, sdk_version='27.0',
                            toolchain_version='Apple clang test', inspect_image=self.inspect)
        return module

    def test_write_and_verify_bind_pinned_source_script_sdk_and_tools(self):
        module = self.write()
        record = json.loads(module.record_path(self.root).read_text())
        self.assertEqual(record['schema_version'], 2)
        self.assertEqual(record['source_sha256'], self.lock['modules']['ffmpeg']['artifacts'][0]['sha256'])
        self.assertEqual(record['build_script_sha256'], hashlib.sha256(self.script.read_bytes()).hexdigest())
        self.assertEqual(record['sdk_version'], '27.0')
        self.assertEqual(record['toolchain_version'], 'Apple clang test')
        self.assertEqual(set(record['tools']), {'ffmpeg', 'ffprobe'})
        self.assertIn('scripts/ffmpeg_codec_build.py', record['build_inputs'])
        self.assertIn('python', record['build_tools'])
        verified = module.verify_record(self.root, self.lock, sdk_version='27.0',
                                        toolchain_version='Apple clang test', inspect_image=self.inspect)
        self.assertEqual(verified, record['tools'])

    def test_changed_codec_helper_source_and_build_environment_are_rejected(self):
        module = self.write()
        helper = self.root / 'scripts/ffmpeg_codec_build.py'
        original = helper.read_bytes()
        helper.write_bytes(b'changed codec implementation')
        with self.assertRaisesRegex(ValueError, 'input'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)
        helper.write_bytes(original)
        record_path = module.record_path(self.root)
        record = json.loads(record_path.read_text())
        record['build_tools']['python'] = 'a different Python runtime'
        record_path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'build tool'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)
        record['build_tools'] = module.codec_build_environment()
        record_path.write_text(json.dumps(record))
        archive = next((self.root / 'Resources/ThirdParty/MPV/sources').glob('dav1d-*'))
        archive.write_bytes(b'changed corresponding codec source')
        with self.assertRaisesRegex(ValueError, 'SHA256|size'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)

    def test_modified_tool_is_rejected(self):
        module = self.write()
        (self.bin / 'ffmpeg').write_bytes(b'modified')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)

    def test_changed_build_script_or_source_is_rejected(self):
        module = self.write()
        self.script.write_bytes(b'changed recipe')
        with self.assertRaisesRegex(ValueError, 'build script'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)
        self.script.write_bytes(b'#!/bin/sh\nexit 0\n')
        self.source.write_bytes(b'changed source')
        with self.assertRaisesRegex(ValueError, 'source'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)

    def test_sdk_change_is_rejected(self):
        module = self.write()
        with self.assertRaisesRegex(ValueError, 'SDK'):
            module.verify_record(self.root, self.lock, sdk_version='26.5',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)
        with self.assertRaisesRegex(ValueError, 'toolchain'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='another compiler', inspect_image=self.inspect)
        self.image = SimpleNamespace(dependencies=('/usr/lib/libSystem.B.dylib',),
                                     minimum_macos='14.0', sdk_version='26.5')
        with self.assertRaisesRegex(ValueError, 'SDK'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)

    def test_tool_symlink_and_nonexecutable_are_rejected(self):
        module = self.write()
        tool = self.bin / 'ffmpeg'
        tool.rename(self.bin / 'elsewhere')
        tool.symlink_to('elsewhere')
        with self.assertRaisesRegex(ValueError, '[Ss]ymlink'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)
        tool.unlink()
        (self.bin / 'elsewhere').rename(tool)
        tool.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'executable'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)

    def test_wrong_architecture_and_non_system_dependency_are_rejected(self):
        module = self.write()
        def wrong_architecture(_path):
            return ('x86_64',), self.image
        with self.assertRaisesRegex(ValueError, 'arm64'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=wrong_architecture)
        self.image = SimpleNamespace(dependencies=('@rpath/libother.dylib',),
                                     minimum_macos='14.0', sdk_version='27.0')
        with self.assertRaisesRegex(ValueError, 'dependency'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)
        self.image = SimpleNamespace(dependencies=('/usr/lib/libSystem.B.dylib',),
                                     minimum_macos='15.0', sdk_version='27.0')
        with self.assertRaisesRegex(ValueError, '14.0'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)

    def test_invalid_schema_and_existing_record_are_rejected(self):
        module = self.write()
        with self.assertRaises(FileExistsError):
            module.write_record(self.root, self.lock, sdk_version='27.0',
                                toolchain_version='Apple clang test', inspect_image=self.inspect)
        path = module.record_path(self.root)
        record = json.loads(path.read_text())
        record['unexpected'] = True
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'schema'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)
        record.pop('unexpected')
        record['schema_version'] = True
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'schema'):
            module.verify_record(self.root, self.lock, sdk_version='27.0',
                                 toolchain_version='Apple clang test', inspect_image=self.inspect)

    def test_staged_install_is_checked_before_publication(self):
        module = self.module()
        staged = self.root / '.build/dependencies/ffmpeg/.stage-build/install'
        staged.parent.mkdir()
        self.bin.parent.rename(staged)
        hashes = module.validate_staged_tools(self.root, self.lock, staged,
                                               sdk_version='27.0', inspect_image=self.inspect)
        self.assertEqual(set(hashes), {'ffmpeg', 'ffprobe'})
        self.image = SimpleNamespace(dependencies=('@rpath/libother.dylib',),
                                     minimum_macos='14.0', sdk_version='27.0')
        with self.assertRaisesRegex(ValueError, 'dependency'):
            module.validate_staged_tools(self.root, self.lock, staged,
                                         sdk_version='27.0', inspect_image=self.inspect)


if __name__ == '__main__':
    unittest.main()
