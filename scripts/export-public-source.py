#!/usr/bin/env python3
"""Export a reviewed source allowlist without development history or local caches."""

import argparse
import ctypes
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


ROOT_FILES = frozenset({'.gitignore', 'Package.swift', 'PUBLIC_README.md', 'BUILDING.md',
                        'Resources/AppIcon.icns', 'Resources/Info.plist',
                        'Resources/ScreenSaver/Info.plist',
                        *(f'Resources/ScreenSaver/{language}.lproj/Localizable.strings'
                          for language in ('zh-Hans', 'en', 'ja', 'fr', 'es'))})
SOURCE_TREES = ('Sources/', 'Tests/', 'scripts/', 'Resources/ThirdParty/', 'docs/help/')
SOURCE_SUFFIXES = frozenset({'.swift', '.py', '.sh', '.mm', '.html', '.md', '.cpp',
                             '.js', '.json', '.hpp', '.h', '.strings', '.mjs',
                             '.css', '.plist', '.m', '.txt'})
MATERIAL_SUFFIXES = frozenset({'.md', '.txt', '.json', '.sh', '.h', '.html', '.gz'})
IGNORED_LOCAL_NAMES = frozenset({'__pycache__', '.DS_Store'})
PERSONAL_PATHS = (
    re.compile(rb'/Users/[A-Za-z0-9._-]+/'),
    re.compile(rb'/home/[A-Za-z0-9._-]+/'),
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
BINARY_SUFFIXES = ('.icns', '.jpg', '.jpeg', '.png', '.gif', '.pdf', '.tar.gz')
METADATA_MARKERS = (b'Exif\x00\x00', b'eXIf', b'tEXt', b'zTXt', b'iTXt',
                    b'GPSLatitude', b'GPSLongitude', b'<x:xmpmeta')
THIRD_PARTY_EMAIL_EXCEPTION = 'Resources/ThirdParty/CEF/CREDITS.html'
PINNED_SOURCE_ARCHIVE = 'Resources/ThirdParty/FFmpeg/ffmpeg-n9.0.1-source.tar.gz'
PINNED_SOURCE_ARCHIVE_SHA256 = '195d54bebe1a27f84d77f4b989d193466f305b355da92292766a69f16880b18a'
PROJECT_LICENSE_SOURCE = 'Resources/ThirdParty/MPV/COPYING.GPLv3'
PROJECT_LICENSE_SHA256 = '8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903'


def allowed(relative):
    if relative in ROOT_FILES:
        return True
    path = PurePosixPath(relative)
    if any(part.startswith('.') for part in path.parts):
        return False
    if relative.startswith('Resources/ThirdParty/'):
        return path.suffix in MATERIAL_SUFFIXES or path.name.startswith('COPYING.')
    return (path.suffix in SOURCE_SUFFIXES
            and any(relative.startswith(prefix) for prefix in SOURCE_TREES))


def tracked_files(root):
    output = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--cached', '-z'])
    return {os.fsdecode(value) for value in output.split(b'\0') if value}


def inventory(root, tracked_paths):
    root = Path(root)
    actual = set()
    for relative in ROOT_FILES:
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'Missing or symlinked public source input: {relative}')
        actual.add(relative)
    for prefix in SOURCE_TREES:
        tree = root / prefix
        if tree.is_symlink() or not tree.is_dir():
            raise ValueError(f'Missing or symlinked public source tree: {prefix}')
        for directory, folders, files in os.walk(tree, followlinks=False):
            parent = Path(directory)
            for name in list(folders):
                child = parent / name
                if child.is_symlink():
                    raise ValueError(f'Symlink in public source tree: {child.relative_to(root)}')
                if name in IGNORED_LOCAL_NAMES:
                    folders.remove(name)
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
        if (not allowed(relative) or path.is_absolute() or '..' in path.parts
                or not relative.isascii()):
            raise ValueError(f'Public source path outside allowlist: {relative}')
        check_sensitive_bytes(relative.encode('ascii'), relative)
        check_email_bytes(relative.encode('ascii'), relative)
    tracked = set(tracked_paths)
    unexpected = actual - tracked
    missing = {path for path in tracked if allowed(path)} - actual
    if unexpected or missing:
        raise ValueError(f'Public source allowlist differs from tracked inputs: '
                         f'untracked={sorted(unexpected)} missing={sorted(missing)}')
    return tuple(sorted(actual))


def scan_file(path, relative):
    data = path.read_bytes()
    check_sensitive_bytes(data, relative)
    if relative.endswith('.tar.gz'):
        check_email_bytes(gzip_header_fields(data), relative)
        trusted_upstream = (relative == PINNED_SOURCE_ARCHIVE
                            and hashlib.sha256(data).hexdigest() == PINNED_SOURCE_ARCHIVE_SHA256)
        scan_archive(path, relative, trusted_upstream=trusted_upstream)
    binary_asset = relative.endswith(BINARY_SUFFIXES)
    if relative != THIRD_PARTY_EMAIL_EXCEPTION and not binary_asset:
        check_email_bytes(data, relative)
    if binary_asset:
        if any(marker in data for marker in METADATA_MARKERS):
            raise ValueError(f'Public source binary metadata found: {relative}')


def check_sensitive_bytes(data, relative):
    for expression in PERSONAL_PATHS:
        if expression.search(data):
            raise ValueError(f'Public source privacy path found: {relative}')
    for expression in SECRETS:
        if expression.search(data):
            raise ValueError(f'Public source secret found: {relative}')


def check_email_bytes(data, relative):
    for match in EMAIL.finditer(data):
        if not match.group().lower().endswith((b'.invalid', b'.example')):
            raise ValueError(f'Public source privacy email found: {relative}')


def check_upstream_source_bytes(data, relative):
    # The byte-pinned upstream archive contains illustrative absolute paths in its docs.
    # Scan its contents for this machine's home path and token formats; the upstream
    # TLS implementation contains a literal PEM delimiter, not a private key.
    # Member metadata is scanned more broadly.
    if HOST_HOME_PREFIX in data:
        raise ValueError(f'Public source privacy path found: {relative}')
    for expression in SECRETS[1:]:
        if expression.search(data):
            raise ValueError(f'Public source secret found: {relative}')


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


def scan_archive(path, relative, *, trusted_upstream=False):
    with tarfile.open(path, 'r:gz') as archive:
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
                previous = b''
                while chunk := stream.read(1024 * 1024):
                    if trusted_upstream:
                        check_upstream_source_bytes(previous + chunk, location)
                    else:
                        check_sensitive_bytes(previous + chunk, location)
                        check_email_bytes(previous + chunk, location)
                    previous = chunk[-512:]


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
    files = inventory(root, tracked_files(root) if tracked_paths is None else tracked_paths)
    if PROJECT_LICENSE_SOURCE not in files:
        raise ValueError(f'Missing project license text: {PROJECT_LICENSE_SOURCE}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.public-source-', dir=destination.parent) as temporary:
        stage = Path(temporary)
        for relative in files:
            target_relative = 'README.md' if relative == 'PUBLIC_README.md' else relative
            target = stage / target_relative
            target.parent.mkdir(parents=True, exist_ok=True)
            source = root / relative
            shutil.copyfile(source, target)
            target.chmod(0o755 if source.stat().st_mode & stat.S_IXUSR else 0o644)
            scan_file(target, target_relative)
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
          'third-party distribution review remains incomplete')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f'PUBLIC SOURCE EXPORT FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
