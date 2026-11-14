#!/usr/bin/env python3
"""Public snapshot inventory and privacy checks, without network or GitHub."""

import importlib.util
import gzip
import hashlib
import io
import json
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
    def test_shared_scene_scripts_are_exported_without_editor_sources_or_build_caches(self):
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
            self.assertFalse((self.destination / relative).exists())
        self.assertEqual((self.destination / 'Resources/SceneScript/resource-runtime.mjs').read_bytes(),
                         b'export const runtime = {};\n')
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
            '.gitattributes': b'*.mjs -whitespace\n',
            'Package.swift': b'// package fixture\n',
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
            'Resources/SceneScript/resource-runtime.mjs': b'export const runtime = {};\n',
            'scripts/public-source-policy.json': b'{"schema_version":1,"additional_source_files":[],"upstream_files":{}}\n',
            'Resources/ThirdParty/distribution-status.json': b'{"schema_version":1,"files":[]}\n',
        }
        for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'):
            files[f'Resources/ScreenSaver/{language}.lproj/Localizable.strings'] = b'"name" = "name";\n'
        for relative, content in files.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.tracked = set(files)
        self.destination = self.base / 'public'

    def add_file(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        self.tracked.add(relative)
        return path

    def policy(self, *, additional=(), upstream=None):
        document = {'schema_version': 1, 'additional_source_files': list(additional),
                    'upstream_files': upstream or {}}
        self.add_file('scripts/public-source-policy.json', json.dumps(document).encode())

    def material(self, relative, content):
        self.add_file(relative, content)
        path = self.root / 'Resources/ThirdParty/distribution-status.json'
        document = json.loads(path.read_text())
        document['files'].append({'path': relative.removeprefix('Resources/ThirdParty/'),
                                  'sha256': hashlib.sha256(content).hexdigest(), 'size': len(content)})
        path.write_text(json.dumps(document))

    def make_archive(self, name, member, payload, mode='w:gz'):
        path = self.base / name
        info = tarfile.TarInfo(member)
        info.size = len(payload)
        with tarfile.open(path, mode) as output:
            output.addfile(info, io.BytesIO(payload))
        return path.read_bytes()

    def test_manifest_materials_and_explicit_build_inputs_are_retained(self):
        files = {'Resources/ThirdParty/MPV/recipe/scripts/compile.py': b'print("source recipe")\n',
                 'Resources/ThirdParty/MPV/patches/fix.patch': b'upstream patch\n',
                 'Resources/ThirdParty/MPV/notices/library/LICENSE': b'Public license\n',
                 'Resources/ThirdParty/MPV/acceptance/fixtures/sample.mkv': b'authored fixture'}
        for relative, content in files.items():
            self.material(relative, content)
        additional = {'Tests/Fixtures/scene.pkg': b'authored scene',
                      'Tests/Fixtures/artwork.png': b'authored image',
                      'scripts/scene-runtime-build/.gitignore': b'node_modules/\n',
                      'docs/releases/1.1.1/RELEASE_NOTES.md': b'# Release\n'}
        for relative, content in additional.items():
            self.add_file(relative, content)
        self.add_file('scripts/codec-audit.c', b'int main(void) { return 0; }\n')
        self.policy(additional=additional)
        load_module().export(self.root, self.destination, tracked_paths=self.tracked)
        for relative, content in (files | additional).items():
            self.assertEqual((self.destination / relative).read_bytes(), content)
        self.assertTrue((self.destination / 'scripts/codec-audit.c').is_file())
        self.assertTrue((self.destination / '.gitattributes').is_file())

    def test_material_hash_mismatch_cannot_be_exported(self):
        relative = 'Resources/ThirdParty/MPV/recipe/scripts/compile.py'
        self.material(relative, b'original recipe\n')
        (self.root / relative).write_bytes(b'changed recipe\n')
        with self.assertRaisesRegex(ValueError, 'hash|digest'):
            load_module().export(self.root, self.destination, tracked_paths=self.tracked)

    def test_untracked_node_cache_symlinks_are_ignored_but_tracked_cache_is_rejected(self):
        cache = self.root / 'scripts/scene-runtime-build/node_modules'
        cache.mkdir(parents=True)
        (cache / 'tool').symlink_to(self.root / 'Sources/Example.swift')
        load_module().export(self.root, self.destination, tracked_paths=self.tracked)
        self.assertFalse((self.destination / 'scripts/scene-runtime-build/node_modules').exists())
        with self.assertRaisesRegex(ValueError, '[Tt]racked.*cache|cache.*tracked'):
            load_module().inventory(self.root, self.tracked | {'scripts/scene-runtime-build/node_modules/tool'})

    def test_pinned_upstream_archive_does_not_bypass_strong_credentials(self):
        relative = 'Resources/ThirdParty/Example/source.tar.gz'
        data = self.make_archive('credential.tar.gz', 'source/test.txt', b'gh' + b'p_' + b'A' * 36)
        self.material(relative, data)
        self.policy(upstream={relative: {'sha256': hashlib.sha256(data).hexdigest(),
                                        'kind': 'archive', 'reason': 'Pinned archive fixture'}})
        with self.assertRaisesRegex(ValueError, 'secret'):
            load_module().export(self.root, self.destination, tracked_paths=self.tracked)

    def test_current_machine_home_cannot_be_added_as_an_upstream_exception(self):
        relative = 'Resources/ThirdParty/Example/source.tar.gz'
        member = 'source/notes.txt'
        value = (str(Path.home()) + '/').encode()
        data = self.make_archive('home.tar.gz', member, value)
        self.material(relative, data)
        self.policy(upstream={relative: {'sha256': hashlib.sha256(data).hexdigest(),
            'kind': 'archive', 'reason': 'Pinned archive fixture', 'members': {
                member: {'sha256': hashlib.sha256(value).hexdigest(), 'reason': 'Invalid example',
                         'matches': [{'category': 'personal-path', 'offset': 0,
                                      'match_sha256': hashlib.sha256(value).hexdigest()}]}}}})
        with self.assertRaisesRegex(ValueError, 'privacy'):
            load_module().export(self.root, self.destination, tracked_paths=self.tracked)

    def test_exact_pinned_upstream_notice_preserves_copyright_email(self):
        relative = 'Resources/ThirdParty/Example/LICENSE'
        data = b'Copyright upstream' + b'@' + b'public-upstream.org\n'
        self.material(relative, data)
        self.policy(upstream={relative: {'sha256': hashlib.sha256(data).hexdigest(),
                                        'kind': 'notice', 'reason': 'Original upstream copyright notice'}})
        load_module().export(self.root, self.destination, tracked_paths=self.tracked)
        self.assertEqual((self.destination / relative).read_bytes(), data)
        (self.root / relative).write_bytes(data + b'changed')
        with self.assertRaisesRegex(ValueError, 'hash|digest'):
            load_module().export(self.root, self.base / 'changed', tracked_paths=self.tracked)

    def test_pinned_notice_still_rejects_personal_paths_and_secrets(self):
        relative = 'Resources/ThirdParty/Example/LICENSE'
        for data in (b'/Users/' + b'privateperson/file', b'gh' + b'p_' + b'A' * 36):
            self.add_file(relative, data)
            self.policy(additional=[relative], upstream={relative: {
                'sha256': hashlib.sha256(data).hexdigest(), 'kind': 'notice', 'reason': 'Fixture notice'}})
            with self.subTest(kind=data[:3]), self.assertRaisesRegex(ValueError, 'privacy|secret'):
                load_module().export(self.root, self.destination, tracked_paths=self.tracked)

    def test_xz_and_bzip2_archive_members_are_privacy_scanned(self):
        for suffix, mode in (('xz', 'w:xz'), ('bz2', 'w:bz2')):
            data = self.make_archive('input.tar.' + suffix, 'source/private.txt',
                                     b'/home/' + b'privateperson/source', mode)
            path = self.base / ('input.tar.' + suffix)
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ValueError, 'privacy'):
                load_module().scan_file(path, 'Resources/ThirdParty/input.tar.' + suffix)

    def test_upstream_archive_exceptions_match_exact_member_hash_and_occurrence(self):
        relative = 'Resources/ThirdParty/Example/source.tar.gz'
        member = 'source/docs/example.txt'
        value = b'/home/' + b'upstream-example/'
        payload = b'Example: ' + value + b'source\nCopyright upstream' + b'@' + b'public-upstream.org\n'
        data = self.make_archive('input.tar.gz', member, payload)
        self.material(relative, data)
        exception = {'sha256': hashlib.sha256(payload).hexdigest(),
                     'reason': 'Unchanged upstream documentation example',
                     'matches': [{'category': 'personal-path', 'offset': payload.index(value),
                                  'match_sha256': hashlib.sha256(value).hexdigest()}]}
        self.policy(upstream={relative: {'sha256': hashlib.sha256(data).hexdigest(),
                                        'kind': 'archive', 'reason': 'Pinned upstream source',
                                        'members': {member: exception}}})
        load_module().export(self.root, self.destination, tracked_paths=self.tracked)
        self.assertEqual((self.destination / relative).read_bytes(), data)
        exception['matches'][0]['offset'] += 1
        self.policy(upstream={relative: {'sha256': hashlib.sha256(data).hexdigest(),
                                        'kind': 'archive', 'reason': 'Pinned upstream source',
                                        'members': {member: exception}}})
        with self.assertRaisesRegex(ValueError, 'privacy|exception'):
            load_module().export(self.root, self.base / 'wrong-occurrence', tracked_paths=self.tracked)

    def test_web_routes_named_home_are_not_personal_filesystem_paths(self):
        module = load_module()
        module.check_sensitive_bytes(b'https://www.quad9.net/home/privacy/', 'upstream.js')
        module.check_sensitive_bytes(b'/cast/chromecast/home/wallpaper/', 'upstream.js')
        with self.assertRaisesRegex(ValueError, 'privacy'):
            module.check_sensitive_bytes(b'file:///home/' + b'privateperson/source', 'source.txt')

    def test_home_paths_in_colon_separated_path_lists_are_not_missed(self):
        with self.assertRaisesRegex(ValueError, 'privacy'):
            load_module().check_sensitive_bytes(b'/usr/local/lib:/home/' + b'privateperson/lib', 'source.txt')

    def test_reserved_test_email_domains_are_distinct_from_real_domains(self):
        module = load_module()
        for domain in ('artwork.test', 'example.com', 'sub.example.com', 'example.net', 'example.org'):
            module.check_email_bytes(b'fixture' + b'@' + domain.encode(), 'fixture.py')
        for domain in ('artwork.test.private-company.org', 'notexample.com', 'example.com.private-company.org'):
            with self.subTest(domain=domain), self.assertRaisesRegex(ValueError, 'privacy'):
                module.check_email_bytes(b'person' + b'@' + domain.encode(), 'source.txt')

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

    def test_additional_source_file_cannot_traverse_a_symlinked_parent(self):
        outside = self.base / 'outside'
        outside.mkdir()
        (outside / 'release.md').write_text('reviewed release notes')
        (self.root / 'docs/release-link').symlink_to(outside, target_is_directory=True)
        relative = 'docs/release-link/release.md'
        self.tracked.add(relative)
        self.policy(additional=[relative])
        with self.assertRaisesRegex(ValueError, '[Ss]ymlink'):
            load_module().export(self.root, self.destination, tracked_paths=self.tracked)

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
                        b'privateperson@' + b'private-company.org',
                        b'-----BEGIN ' + b'PRIVATE KEY-----'):
            source.write_bytes(content)
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, 'privacy|secret'):
                module.export(self.root, self.destination, tracked_paths=self.tracked)

    def test_project_authored_third_party_notes_cannot_hide_email(self):
        module = load_module()
        notes = self.root / 'Resources/ThirdParty/README.md'
        notes.write_bytes(b'contact: privateperson@' + b'private-company.org')
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
            module.scan_file(archive, 'Resources/ThirdParty/FFmpeg/ffmpeg-n9.0.1-source.tar.gz')

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
        payload = b'privateperson@' + b'private-company.org'
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
