"""Pinned corresponding-source inputs for the controlled libmpv build."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import tarfile

from media_dependencies import checked_bytes, relative_path, validate_artifact


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'Duplicate JSON key: {key}')
        result[key] = value
    return result


def source_file(root, relative):
    root = Path(root).resolve()
    path = root / relative_path(relative)
    if path.is_symlink() or not path.resolve().is_relative_to(root):
        raise ValueError(f'Source path is symlinked or escapes root: {relative}')
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def load_source_lock(root, path=None):
    path = Path(path) if path is not None else Path(root) / 'scripts/mpv-source-lock.json'
    document = json.loads(path.read_text(), object_pairs_hook=unique_pairs)
    if (type(document) is not dict or document.get('schema_version') != 1
            or type(document.get('schema_version')) is not int
            or document.get('architecture') != 'arm64'
            or document.get('minimum_macos') != '14.0'):
        raise ValueError('Invalid controlled mpv source lock')
    libraries = document.get('libraries')
    if (not isinstance(libraries, list) or not libraries
            or len(libraries) != len(set(libraries))
            or 'libmpv.2.dylib' not in libraries
            or any(not re.fullmatch(r'[A-Za-z0-9_.+-]+\.dylib', name) for name in libraries)):
        raise ValueError('Invalid controlled library set')
    components = document.get('components')
    if not isinstance(components, list) or not components:
        raise ValueError('Source components are required')
    seen = set()
    for component in components:
        name = component.get('name')
        if not isinstance(name, str) or not re.fullmatch(r'[a-z0-9_]+', name):
            raise ValueError('Invalid source component name')
        if name in seen:
            raise ValueError(f'Duplicate source component: {name}')
        seen.add(name)
        if (not component.get('version') or not component.get('license')
                or component.get('role') not in ('runtime', 'build-tool', 'generator')
                or not re.fullmatch(r'[a-f0-9]{40}|n?\d+(?:\.\d+)+', component.get('revision', ''))):
            raise ValueError(f'Invalid source component: {name}')
        validate_artifact(component['artifact'])
        notices = component.get('license_files')
        if not isinstance(notices, list) or not notices:
            raise ValueError(f'Original notices are required: {name}')
        for notice in notices:
            relative_path(notice)
    for artifact in document.get('patches', []):
        validate_artifact(artifact)
    return document


def archive_members(archive):
    members = archive.getmembers()
    roots = set()
    seen = set()
    for member in members:
        name = member.name.rstrip('/')
        parts = PurePosixPath(name).parts
        if (not parts or name.startswith('/') or '\\' in name or '..' in parts
                or name in seen or not (member.isfile() or member.isdir() or member.issym())):
            raise ValueError(f'Invalid source archive member: {member.name}')
        if member.issym():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if (member.linkname.startswith('/') or '\\' in member.linkname
                    or not target.startswith(parts[0] + '/')):
                raise ValueError(f'Invalid source archive symlink: {member.name}')
        roots.add(parts[0])
        seen.add(name)
    if len(roots) != 1:
        raise ValueError('Source archive must have one top-level directory')
    symlinks = {member.name.rstrip('/') for member in members if member.issym()}
    for member in members:
        if any(str(parent) in symlinks for parent in PurePosixPath(member.name).parents):
            raise ValueError(f'Source archive writes through symlink: {member.name}')
    return members


def verify_sources(root, lock):
    for component in lock['components']:
        artifact = component['artifact']
        path = source_file(root, artifact['path'])
        checked_bytes(path, artifact)
        with tarfile.open(path) as archive:
            members = archive_members(archive)
            names = {'/'.join(PurePosixPath(member.name).parts[1:])
                     for member in members if member.isfile()}
            for notice in component['license_files']:
                if notice not in names:
                    raise ValueError(f'Original notice missing in {component["name"]}: {notice}')
    for patch in lock.get('patches', []):
        checked_bytes(source_file(root, patch['path']), patch)


def extract_source(path, destination):
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    with tarfile.open(path) as archive:
        members = archive_members(archive)  # Validate the entire tree before any write.
        destination.mkdir(parents=True)
        for member in members:
            parts = PurePosixPath(member.name).parts[1:]
            if not parts:
                continue
            target = destination.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.issym():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(f'Unreadable source archive member: {member.name}')
                with stream, target.open('xb') as output:
                    shutil.copyfileobj(stream, output)
                target.chmod(member.mode & 0o777)
