#!/usr/bin/env python3
"""Export reviewed source inputs without development history or local caches.

The distribution manifest binds required build materials to their SHA-256 hashes.
The publication policy pins unchanged upstream notices/archives before permitting
their copyright email addresses. Public upstream path examples and a TLS parser
marker require archive, member and exact occurrence hashes; all other paths and
credential formats remain checked, including archive metadata. The current
machine's home directory cannot be exempted.
"""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


POLICY_PATH = 'scripts/public-source-policy.json'
MATERIAL_MANIFEST = 'Resources/ThirdParty/distribution-status.json'
ROOT_FILES = frozenset({'.gitignore', '.gitattributes', 'Package.swift', 'PUBLIC_README.md', 'BUILDING.md',
                        POLICY_PATH, MATERIAL_MANIFEST,
                        'Resources/AppIcon.icns', 'Resources/Info.plist',
                        'Resources/ScreenSaver/Info.plist',
                        *(f'Resources/ScreenSaver/{language}.lproj/Localizable.strings'
                          for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'))})
SOURCE_TREES = ('Sources/', 'Tests/', 'scripts/', 'Resources/SceneScript/', 'Resources/ThirdParty/', 'docs/help/')
SOURCE_SUFFIXES = frozenset({'.swift', '.py', '.sh', '.mm', '.html', '.md', '.cpp',
                             '.js', '.json', '.hpp', '.h', '.strings', '.mjs',
                             '.css', '.plist', '.m', '.txt', '.c'})
MATERIAL_SUFFIXES = frozenset({'.md', '.txt', '.json', '.sh', '.h', '.html', '.gz'})
IGNORED_LOCAL_NAMES = frozenset({'__pycache__', '.DS_Store', '.build', '.swiftpm', 'node_modules', 'dist'})
PERSONAL_PATHS = (
    re.compile(rb'/Users/[A-Za-z0-9._-]+/'),
    re.compile(rb'(?<![A-Za-z0-9_./-])(?:file://)?/home/[A-Za-z0-9._-]+/'),
    re.compile(rb'[A-Za-z]:\\Users\\[A-Za-z0-9._-]+\\'),
)
EMAIL = re.compile(rb'(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
SECRETS = (
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(rb'github_pat_[A-Za-z0-9_]{20,}'),
    re.compile(rb'ghp_[A-Za-z0-9]{30,}'),
    re.compile(rb'AKIA[0-9A-Z]{16}'),
    re.compile(rb'xox[baprs]-[A-Za-z0-9-]{20,}'),
)
HOST_HOME_PREFIX = os.fsencode(str(Path.home().resolve()) + '/')
BINARY_SUFFIXES = ('.icns', '.jpg', '.jpeg', '.png', '.gif', '.pdf')
METADATA_MARKERS = (b'Exif\x00\x00', b'eXIf', b'tEXt', b'zTXt', b'iTXt',
                    b'GPSLatitude', b'GPSLongitude', b'<x:xmpmeta')
ARCHIVE_SUFFIXES = ('.tar.gz', '.tar.xz', '.tar.bz2')
PROJECT_LICENSE_SOURCE = 'Resources/ThirdParty/MPV/COPYING.GPLv3'
PROJECT_LICENSE_SHA256 = '8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903'


def allowed(relative, material_paths=(), additional_paths=()):
    if relative in ROOT_FILES or relative in material_paths or relative in additional_paths:
        return True
    path = PurePosixPath(relative)
    if any(part.startswith('.') for part in path.parts):
        return False
    if relative.startswith('Resources/ThirdParty/'):
        return path.suffix in MATERIAL_SUFFIXES or path.name.startswith('COPYING.')
    return (path.suffix in SOURCE_SUFFIXES
            and any(relative.startswith(prefix) for prefix in SOURCE_TREES))


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate public source policy or manifest key')
        result[key] = value
    return result


def checked_relative(value):
    if (not isinstance(value, str) or not value or not value.isascii() or '\\' in value
            or PurePosixPath(value).is_absolute() or '..' in PurePosixPath(value).parts
            or PurePosixPath(value).as_posix() != value):
        raise ValueError('Invalid public source policy or manifest path')
    return value


def checked_digest(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        raise ValueError('Invalid public source policy or manifest digest')
    return value


def load_policy(root):
    document = json.loads((Path(root) / POLICY_PATH).read_text(), object_pairs_hook=unique_pairs)
    if (not isinstance(document, dict) or set(document) != {'schema_version', 'additional_source_files', 'upstream_files'}
            or type(document['schema_version']) is not int or document['schema_version'] != 1
            or not isinstance(document['additional_source_files'], list)
            or not isinstance(document['upstream_files'], dict)):
        raise ValueError('Invalid public source policy')
    for relative in document['additional_source_files']:
        checked_relative(relative)
    for relative, entry in document['upstream_files'].items():
        checked_relative(relative)
        if (not relative.startswith('Resources/ThirdParty/') or not isinstance(entry, dict)
                or entry.get('kind') not in ('notice', 'archive') or not entry.get('reason')):
            raise ValueError('Invalid upstream privacy policy entry')
        checked_digest(entry.get('sha256'))
        for member, exception in entry.get('members', {}).items():
            checked_relative(member)
            checked_digest(exception.get('sha256'))
            if not exception.get('reason') or not isinstance(exception.get('matches'), list):
                raise ValueError('Invalid upstream member exception')
            for match in exception['matches']:
                if (match.get('category') not in ('personal-path', 'private-key-marker')
                        or type(match.get('offset')) is not int or match['offset'] < 0):
                    raise ValueError('Invalid upstream occurrence exception')
                checked_digest(match.get('match_sha256'))
    return document


def material_hashes(root):
    document = json.loads((Path(root) / MATERIAL_MANIFEST).read_text(), object_pairs_hook=unique_pairs)
    if (not isinstance(document, dict) or type(document.get('schema_version')) is not int
            or document['schema_version'] != 1 or not isinstance(document.get('files'), list)):
        raise ValueError('Invalid public source material manifest')
    result = {}
    for entry in document['files']:
        relative = 'Resources/ThirdParty/' + checked_relative(entry.get('path'))
        if relative in result:
            raise ValueError('Duplicate public source material path')
        result[relative] = checked_digest(entry.get('sha256'))
    return result


def tracked_files(root):
    output = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--cached', '-z'])
    return {os.fsdecode(value) for value in output.split(b'\0') if value}


def regular_source(root, relative):
    path = Path(root)
    for part in PurePosixPath(relative).parts:
        path /= part
        if path.is_symlink():
            raise ValueError(f'Symlink in public source input: {relative}')
    if not path.is_file():
        raise ValueError(f'Missing public source input: {relative}')
    return path


def inventory(root, tracked_paths, *, policy=None, materials=None):
    root = Path(root)
    policy = load_policy(root) if policy is None else policy
    materials = material_hashes(root) if materials is None else materials
    tracked = set(tracked_paths)
    for relative in tracked:
        if IGNORED_LOCAL_NAMES.intersection(PurePosixPath(relative).parts) or relative.endswith(('.pyc', '.pyo')):
            raise ValueError(f'Tracked build cache is not a public source input: {relative}')
    actual = set()
    additional = set(policy['additional_source_files'])
    for relative in ROOT_FILES | additional | set(materials):
        regular_source(root, relative)
        actual.add(relative)
    for prefix in SOURCE_TREES:
        tree = root / prefix
        if tree.is_symlink() or not tree.is_dir():
            raise ValueError(f'Missing or symlinked public source tree: {prefix}')
        for directory, folders, files in os.walk(tree, followlinks=False):
            parent = Path(directory)
            for name in list(folders):
                if name in IGNORED_LOCAL_NAMES:
                    folders.remove(name)
                    continue
                child = parent / name
                if child.is_symlink():
                    raise ValueError(f'Symlink in public source tree: {child.relative_to(root)}')
            for name in files:
                path = parent / name
                if path.is_symlink():
                    raise ValueError(f'Symlink in public source tree: {path.relative_to(root)}')
                if name in IGNORED_LOCAL_NAMES or name.endswith(('.pyc', '.pyo')):
                    continue
                if not path.is_file():
                    raise ValueError(f'Non-file public source input: {path.relative_to(root)}')
                actual.add(path.relative_to(root).as_posix())
    for relative in actual:
        path = PurePosixPath(relative)
        if (not allowed(relative, materials, additional) or path.is_absolute() or '..' in path.parts
                or not relative.isascii()):
            raise ValueError(f'Public source path outside allowlist: {relative}')
        check_sensitive_bytes(relative.encode('ascii'), relative)
        check_email_bytes(relative.encode('ascii'), relative)
    unexpected = actual - tracked
    missing = {path for path in tracked if allowed(path, materials, additional)} - actual
    if unexpected or missing:
        raise ValueError(f'Public source allowlist differs from tracked inputs: '
                         f'untracked={sorted(unexpected)} missing={sorted(missing)}')
    return tuple(sorted(actual))


def scan_file(path, relative, *, policy=None, expected_hash=None):
    data = path.read_bytes()
    upstream = (policy or {}).get('upstream_files', {}).get(relative)
    digest = hashlib.sha256(data).hexdigest()
    if expected_hash is not None and digest != expected_hash:
        raise ValueError(f'Public source material hash mismatch: {relative}')
    if upstream and digest != upstream['sha256']:
        raise ValueError(f'Public source upstream hash mismatch: {relative}')
    check_sensitive_bytes(data, relative)
    if relative.endswith(ARCHIVE_SUFFIXES):
        if relative.endswith('.tar.gz'):
            header = gzip_header_fields(data)
            check_sensitive_bytes(header, relative)
            check_email_bytes(header, relative)
            if any(marker in header for marker in METADATA_MARKERS):
                raise ValueError(f'Public source binary metadata found: {relative} gzip header')
        scan_archive(path, relative, upstream=upstream if upstream and upstream['kind'] == 'archive' else None)
        return
    binary_asset = relative.endswith(BINARY_SUFFIXES)
    if not (upstream and upstream['kind'] == 'notice') and not binary_asset:
        check_email_bytes(data, relative)
    if binary_asset:
        if any(marker in data for marker in METADATA_MARKERS):
            raise ValueError(f'Public source binary metadata found: {relative}')


def check_sensitive_bytes(data, relative, *, exceptions=()):
    if HOST_HOME_PREFIX in data:
        raise ValueError(f'Public source privacy path found: {relative}')
    approved = {(entry['category'], entry['offset'], entry['match_sha256']) for entry in exceptions}
    observed = set()
    patterns = [(pattern, 'personal-path', 'privacy path') for pattern in PERSONAL_PATHS]
    patterns += [(pattern, 'private-key-marker' if index == 0 else 'secret', 'secret')
                 for index, pattern in enumerate(SECRETS)]
    for expression, category, label in patterns:
        for match in expression.finditer(data):
            occurrence = (category, match.start(), hashlib.sha256(match.group()).hexdigest())
            if occurrence in approved:
                observed.add(occurrence)
                continue
            raise ValueError(f'Public source {label} found: {relative}')
    if approved != observed:
        raise ValueError(f'Upstream privacy exception no longer matches: {relative}')


def check_email_bytes(data, relative):
    for match in EMAIL.finditer(data):
        domain = match.group().rsplit(b'@', 1)[-1].lower()
        reserved = (domain.endswith((b'.invalid', b'.example', b'.test'))
                    or any(domain == example or domain.endswith(b'.' + example)
                           for example in (b'example.com', b'example.net', b'example.org')))
        if not reserved:
            raise ValueError(f'Public source privacy email found: {relative}')


def gzip_header_fields(data):
    if len(data) < 10 or data[:3] != b'\x1f\x8b\x08' or data[3] & 0xe0:
        raise ValueError('Invalid gzip header in public source archive')
    flags = data[3]
    offset = 10
    fields = []
    if flags & 4:
        if len(data) < offset + 2:
            raise ValueError('Truncated gzip extra length')
        length = int.from_bytes(data[offset:offset + 2], 'little')
        offset += 2
        fields.append(data[offset:offset + length])
        offset += length
    for flag in (8, 16):
        if flags & flag:
            end = data.find(b'\x00', offset)
            if end < 0:
                raise ValueError('Unterminated gzip header field')
            fields.append(data[offset:end])
            offset = end + 1
    if offset + (2 if flags & 2 else 0) > len(data):
        raise ValueError('Truncated gzip header')
    return b'\n'.join(fields)


def scan_archive(path, relative, *, upstream=None):
    members = upstream.get('members', {}) if upstream else {}
    observed_members = set()
    with tarfile.open(path, 'r:*') as archive:
        for index, member in enumerate(archive):
            location = f'{relative} member #{index}'
            metadata = (member.name, member.linkname, member.uname, member.gname,
                        *member.pax_headers.keys(), *member.pax_headers.values())
            for value in metadata:
                encoded = str(value).encode('utf-8', 'surrogateescape')
                check_sensitive_bytes(encoded, location)
                check_email_bytes(encoded, location)
            if not member.isfile():
                continue
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError(f'Unreadable public source archive member: {relative}')
            with stream:
                data = stream.read()
            exception = members.get(member.name)
            if exception:
                if hashlib.sha256(data).hexdigest() != exception['sha256']:
                    raise ValueError(f'Upstream member exception hash mismatch: {location}')
                observed_members.add(member.name)
            check_sensitive_bytes(data, location, exceptions=exception['matches'] if exception else ())
            if not upstream:
                check_email_bytes(data, location)
    if observed_members != set(members):
        raise ValueError(f'Upstream privacy exception member missing: {relative}')


def publish_directory(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def export(root, destination, *, tracked_paths=None):
    root = Path(root).resolve(strict=True)
    destination = Path(destination).absolute()
    if destination.is_symlink():
        raise FileExistsError(f'Public source destination already exists: {destination}')
    destination = destination.parent.resolve() / destination.name
    if destination.exists():
        raise FileExistsError(f'Public source destination already exists: {destination}')
    policy, materials = load_policy(root), material_hashes(root)
    files = inventory(root, tracked_files(root) if tracked_paths is None else tracked_paths,
                      policy=policy, materials=materials)
    if PROJECT_LICENSE_SOURCE not in files:
        raise ValueError(f'Missing project license text: {PROJECT_LICENSE_SOURCE}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.public-source-', dir=destination.parent) as temporary:
        stage = Path(temporary)
        for relative in files:
            target_relative = 'README.md' if relative == 'PUBLIC_README.md' else relative
            target = stage / target_relative
            target.parent.mkdir(parents=True, exist_ok=True)
            source = regular_source(root, relative)
            shutil.copyfile(source, target)
            target.chmod(0o755 if source.stat().st_mode & stat.S_IXUSR else 0o644)
            scan_file(target, target_relative, policy=policy, expected_hash=materials.get(relative))
        license_path = stage / 'LICENSE'
        shutil.copyfile(stage / PROJECT_LICENSE_SOURCE, license_path)
        if hashlib.sha256(license_path.read_bytes()).hexdigest() != PROJECT_LICENSE_SHA256:
            raise ValueError(f'Project license text differs from GNU GPLv3: {PROJECT_LICENSE_SOURCE}')
        license_path.chmod(0o644)
        scan_file(license_path, 'LICENSE')
        exported = {path.relative_to(stage).as_posix() for path in stage.rglob('*') if path.is_file()}
        expected = {'README.md' if path == 'PUBLIC_README.md' else path for path in files} | {'LICENSE'}
        if exported != expected or (stage / '.git').exists():
            raise ValueError('Public source export inventory differs from allowlist')
        publish_directory(stage, destination)
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path,
                        help='new destination directory; existing paths are never replaced')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    files = export(root, options.output)
    print(f'PUBLIC SOURCE CANDIDATE: {len(files)} files; no Git history copied; '
          'source bytes and pinned upstream materials scanned')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f'PUBLIC SOURCE EXPORT FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
