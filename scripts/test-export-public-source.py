#!/usr/bin/env python3
"""Public snapshot inventory and privacy checks, without network or GitHub."""

import importlib.util
import gzip
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name('export-public-source.py')
LICENSE_TEXT = (SCRIPT.parents[1] / 'Resources/ThirdParty/MPV/COPYING.GPLv3').read_bytes()


def load_module():
    spec = importlib.util.spec_from_file_location('export_public_source', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PublicSourceExportTests(unittest.TestCase):
    def test_editor_sources_and_notices_are_exported_without_build_caches(self):
        module = load_module()
        files = {'Editor/Package.swift': b'// standalone package',
                 'Editor/Sources/EditorApp/App.swift': b'// editor source',
                 'docs/editor-install.md': b'# Independent Editor install notes',
                 'Editor/ThirdParty/WebWallGL-Editor-LICENSE': b'MIT notice'}
        for relative, contents in files.items():
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(contents)
        self.tracked.update(files)
        cache = self.root / 'Editor/Web/.build/node_modules/private/cache.txt'
        cache.parent.mkdir(parents=True); cache.write_text('private build cache')
        module.export(self.root, self.destination, tracked_paths=self.tracked)
        for relative in files:
            self.assertTrue((self.destination / relative).is_file())
        self.assertFalse((self.destination / 'Editor/Web/.build').exists())

    def test_screen_saver_localizations_are_required_build_inputs(self):
        module = load_module()
        for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'):
            self.assertIn(f'Resources/ScreenSaver/{language}.lproj/Localizable.strings',
                          module.ROOT_FILES)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / 'source'
        self.root.mkdir()
        files = {
            '.gitignore': b'.build/\n',
            'Package.swift': b'// package fixture\n',
            'Editor/Package.swift': b'// standalone package\n',
            'Editor/ThirdParty/WebWallGL-Editor-LICENSE': b'MIT notice',
            'PUBLIC_README.md': b'# Public source\n',
            'BUILDING.md': b'# Building\n',
            'Resources/AppIcon.icns': b'icns safe binary',
            'Resources/Info.plist': b'<plist/>',
            'Resources/ScreenSaver/Info.plist': b'<plist/>',
            'Resources/ThirdParty/README.md': b'Notices',
            'Resources/ThirdParty/MPV/COPYING.GPLv3': LICENSE_TEXT,
            'Sources/Example.swift': b'public struct Example {}\n',
            'Tests/ExampleTests.swift': b'final class ExampleTests {}\n',
            'scripts/build-app.sh': b'#!/bin/bash\n',
            'docs/help/index.md': b'# Help\n',
            'docs/editor-install.md': b'# Independent Editor install notes\n',
        }
        for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'):
            files[f'Resources/ScreenSaver/{language}.lproj/Localizable.strings'] = b'"name" = "name";\n'
        for relative, content in files.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.tracked = set(files)
        self.destination = self.base / 'public'

    def test_exact_allowlist_and_readme_mapping_exclude_history_and_private_files(self):
        module = load_module()
        (self.root / '.git').mkdir()
        (self.root / '.git/config').write_text('private history')
        (self.root / 'README.md').write_text('private README')
        (self.root / '.build').mkdir()
        (self.root / '.build/private.log').write_text('private cache')
        module.export(self.root, self.destination, tracked_paths=self.tracked)
        expected = (self.tracked - {'PUBLIC_README.md'}) | {'README.md', 'LICENSE'}
        self.assertEqual({str(p.relative_to(self.destination)) for p in self.destination.rglob('*')
                          if p.is_file()}, expected)
        self.assertEqual((self.destination / 'README.md').read_text(), '# Public source\n')
        self.assertEqual((self.destination / 'LICENSE').read_bytes(),
                         (self.root / 'Resources/ThirdParty/MPV/COPYING.GPLv3').read_bytes())
        self.assertFalse((self.destination / '.git').exists())
        with self.assertRaises(FileExistsError):
            module.export(self.root, self.destination, tracked_paths=self.tracked)

    def test_missing_project_license_source_is_rejected(self):
        module = load_module()
        license_source = 'Resources/ThirdParty/MPV/COPYING.GPLv3'
        (self.root / license_source).unlink()
        with self.assertRaisesRegex(ValueError, 'license'):
            module.export(self.root, self.destination, tracked_paths=self.tracked - {license_source})

    def test_changed_project_license_text_is_rejected(self):
        module = load_module()
        license_source = self.root / 'Resources/ThirdParty/MPV/COPYING.GPLv3'
        license_source.write_bytes(b'Not the GNU GPL\n')
        with self.assertRaisesRegex(ValueError, 'license'):
            module.export(self.root, self.destination, tracked_paths=self.tracked)

    def test_extra_file_or_symlink_inside_allowlisted_tree_is_rejected(self):
        module = load_module()
        extra = self.root / 'Sources/private-note.txt'
        extra.write_text('not tracked')
        with self.assertRaisesRegex(ValueError, 'untracked|allowlist'):
            module.export(self.root, self.destination, tracked_paths=self.tracked)
        extra.unlink()
        link = self.root / 'Sources/linked.swift'
        link.symlink_to(self.root / 'Sources/Example.swift')
        with self.assertRaisesRegex(ValueError, '[Ss]ymlink'):
            module.export(self.root, self.destination, tracked_paths=self.tracked)

    def test_tracked_secret_filename_is_not_implicitly_allowlisted(self):
        module = load_module()
        secret = self.root / 'scripts/.env'
        secret.write_text('harmless fixture')
        with self.assertRaisesRegex(ValueError, 'allowlist'):
            module.export(self.root, self.destination,
                          tracked_paths=self.tracked | {'scripts/.env'})

    def test_tracked_email_filename_is_rejected(self):
        module = load_module()
        relative = 'Sources/privateperson@' + 'personal.example.com.swift'
        (self.root / relative).write_text('public struct Safe {}')
        with self.assertRaisesRegex(ValueError, 'privacy'):
            module.export(self.root, self.destination,
                          tracked_paths=self.tracked | {relative})

    def test_personal_path_email_and_credential_are_rejected(self):
        module = load_module()
        source = self.root / 'Sources/Example.swift'
        for content in (b'/Users/' + b'privateperson/Documents/media.mov',
                        b'privateperson@' + b'personal.example.com',
                        b'-----BEGIN ' + b'PRIVATE KEY-----'):
            source.write_bytes(content)
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, 'privacy|secret'):
                module.export(self.root, self.destination, tracked_paths=self.tracked)

    def test_project_authored_third_party_notes_cannot_hide_email(self):
        module = load_module()
        notes = self.root / 'Resources/ThirdParty/README.md'
        notes.write_bytes(b'contact: privateperson@' + b'personal.example.com')
        with self.assertRaisesRegex(ValueError, 'privacy email'):
            module.export(self.root, self.destination, tracked_paths=self.tracked)

    def test_binary_metadata_is_scanned(self):
        module = load_module()
        icon = self.root / 'Resources/AppIcon.icns'
        icon.write_bytes(b'icns\x00Exif\x00\x00GPSLatitude=1')
        with self.assertRaisesRegex(ValueError, 'metadata'):
            module.export(self.root, self.destination, tracked_paths=self.tracked)

    def test_copied_bytes_are_scanned_before_publication(self):
        module = load_module()
        copyfile = module.shutil.copyfile

        def change_source_before_copy(source, target):
            if Path(source).name == 'Example.swift':
                Path(source).write_bytes(b'/Users/' + b'privateperson/secret.mov')
            return copyfile(source, target)

        with mock.patch.object(module.shutil, 'copyfile', side_effect=change_source_before_copy):
            with self.assertRaisesRegex(ValueError, 'privacy'):
                module.export(self.root, self.destination, tracked_paths=self.tracked)
        self.assertFalse(self.destination.exists())

    def test_archive_private_key_is_rejected(self):
        module = load_module()
        archive = self.base / 'secret.tar.gz'
        payload = (b'-----BEGIN ' + b'PRIVATE KEY-----\n'
                   + b'cHJpdmF0ZS1rZXktZml4dHVyZQ==\n'
                   + b'-----END ' + b'PRIVATE KEY-----\n')
        member = tarfile.TarInfo('FFmpeg-n9.0.1/secret.pem')
        member.size = len(payload)
        with tarfile.open(archive, 'w:gz') as output:
            output.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(ValueError, 'secret'):
            module.scan_file(archive, module.PINNED_SOURCE_ARCHIVE)

    def test_gzip_header_personal_path_is_rejected(self):
        module = load_module()
        raw_tar = io.BytesIO()
        with tarfile.open(fileobj=raw_tar, mode='w') as output:
            member = tarfile.TarInfo('safe.txt')
            member.size = 4
            output.addfile(member, io.BytesIO(b'safe'))
        compressed = gzip.compress(raw_tar.getvalue())
        filename = b'/Users/' + b'privateperson/secret.mov\x00'
        compressed = compressed[:3] + bytes([compressed[3] | 8]) + compressed[4:10] + filename + compressed[10:]
        archive = self.base / 'header.tar.gz'
        archive.write_bytes(compressed)
        with self.assertRaisesRegex(ValueError, 'privacy'):
            module.scan_file(archive, 'Resources/ThirdParty/FFmpeg/header.tar.gz')

    def test_untrusted_archive_member_email_is_rejected(self):
        module = load_module()
        archive = self.base / 'email.tar.gz'
        payload = b'privateperson@' + b'personal.example.com'
        member = tarfile.TarInfo('notes.txt')
        member.size = len(payload)
        with tarfile.open(archive, 'w:gz') as output:
            output.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(ValueError, 'privacy email'):
            module.scan_file(archive, 'Resources/ThirdParty/FFmpeg/email.tar.gz')

    def test_archive_member_contents_and_metadata_are_scanned(self):
        module = load_module()
        archive = self.base / 'source.tar.gz'
        personal_path = (str(Path.home()) + '/Documents/').encode()
        for field in ('body', 'uname', 'linkname', 'pax'):
            with self.subTest(field=field):
                member = tarfile.TarInfo('FFmpeg-n9.0.1/notes.txt')
                body = personal_path if field == 'body' else b'ordinary notes'
                if field == 'uname':
                    member.uname = personal_path.decode()
                if field == 'linkname':
                    member.type = tarfile.SYMTYPE
                    member.linkname = personal_path.decode()
                    body = b''
                if field == 'pax':
                    member.pax_headers = {'comment': personal_path.decode()}
                member.size = len(body)
                with tarfile.open(archive, 'w:gz') as output:
                    output.addfile(member, io.BytesIO(body) if body else None)
                with self.assertRaisesRegex(ValueError, 'privacy'):
                    module.scan_file(archive, 'Resources/ThirdParty/FFmpeg/source.tar.gz')


if __name__ == '__main__':
    unittest.main()
