"""Bind locally built FFmpeg tools to pinned source and checked build inputs."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

from media_bundle_macho import inspect_image, is_system_path, validate_target
from media_dependencies import checked_bytes, relative_path
from swift_sdk import selected_sdk, sdk_version


TOOL_NAMES = ('ffmpeg', 'ffprobe')
RECORD_RELATIVE = Path('.build/dependencies/ffmpeg/local-build.json')
BUILD_SCRIPT_RELATIVE = Path('scripts/feasibility/ffmpeg/build.sh')
HEX_SHA256 = re.compile(r'[0-9a-f]{64}\Z')


def current_build_environment():
    sdk = selected_sdk()
    toolchain = subprocess.check_output(['/usr/bin/clang', '--version'], text=True).splitlines()[0]
    return sdk_version(sdk), toolchain


def record_path(root):
    return Path(root) / RECORD_RELATIVE


def _file(root, relative, label):
    root = Path(root).resolve(strict=True)
    path = root / relative
    if path.is_symlink() or not path.resolve().is_relative_to(root):
        raise ValueError(f'{label} symlink or escaping path is not accepted: {path}')
    if not path.is_file():
        raise ValueError(f'{label} is missing or not a regular file: {path}')
    return path


def _digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _source(root, lock):
    artifacts = lock['modules']['ffmpeg']['artifacts']
    if len(artifacts) != 1:
        raise ValueError('FFmpeg requires exactly one pinned source archive')
    artifact = artifacts[0]
    relative = relative_path(artifact['path'])
    if not relative.startswith('ffmpeg/') or not relative.endswith('.tar.gz'):
        raise ValueError('Invalid FFmpeg source path in dependency lock')
    source = _file(root, Path('.build/dependencies') / relative, 'FFmpeg source')
    try:
        checked_bytes(source, artifact)
    except (OSError, ValueError) as error:
        raise ValueError(f'FFmpeg source verification failed: {error}') from error
    return artifact['sha256']


def _script_sha(root):
    script = _file(root, BUILD_SCRIPT_RELATIVE, 'FFmpeg build script')
    return _digest(script)


def _tools(root, lock, install, sdk_version, inspect):
    module = lock['modules']['ffmpeg']
    result = {}
    for name in TOOL_NAMES:
        tool = _file(root, Path(install) / 'bin' / name, f'FFmpeg {name}')
        if not tool.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
            raise ValueError(f'FFmpeg {name} is not executable: {tool}')
        architecture, commands = inspect(tool)
        validate_target(architecture, commands.minimum_macos,
                        expected_architecture=module['architecture'],
                        maximum_macos=module['minimum_macos'])
        if commands.sdk_version != sdk_version:
            raise ValueError(f'FFmpeg {name} SDK differs from selected SDK')
        for dependency in commands.dependencies:
            if not is_system_path(dependency):
                raise ValueError(f'FFmpeg {name} has non-system dependency: {dependency}')
        result[name] = _digest(tool)
    return result


def validate_staged_tools(root, lock, install, *, sdk_version, inspect_image=inspect_image):
    install = Path(install)
    if install.is_symlink() or not install.resolve().is_relative_to(Path(root).resolve()):
        raise ValueError(f'FFmpeg staged install escapes build root: {install}')
    return _tools(root, lock, install, sdk_version, inspect_image)


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'Duplicate FFmpeg build record key: {key}')
        result[key] = value
    return result


def _record(document):
    if (type(document) is not dict or set(document) != {
            'schema_version', 'source_sha256', 'build_script_sha256',
            'sdk_version', 'toolchain_version', 'tools'
    } or type(document['schema_version']) is not int or document['schema_version'] != 1
            or type(document['sdk_version']) is not str
            or not re.fullmatch(r'\d+(?:\.\d+){1,2}', document['sdk_version'])
            or type(document['toolchain_version']) is not str
            or not document['toolchain_version'].strip()):
        raise ValueError('Invalid FFmpeg build record schema')
    for key in ('source_sha256', 'build_script_sha256'):
        if type(document[key]) is not str or not HEX_SHA256.fullmatch(document[key]):
            raise ValueError('Invalid FFmpeg build record schema')
    tools = document['tools']
    if (type(tools) is not dict or set(tools) != set(TOOL_NAMES)
            or any(type(value) is not str or not HEX_SHA256.fullmatch(value)
                   for value in tools.values())):
        raise ValueError('Invalid FFmpeg build record schema')
    return document


def write_record(root, lock, *, sdk_version, toolchain_version, inspect_image=inspect_image):
    source_sha = _source(root, lock)
    script_sha = _script_sha(root)
    tools = _tools(root, lock, Path('.build/dependencies/ffmpeg/install'),
                   sdk_version, inspect_image)
    document = _record({'schema_version': 1, 'source_sha256': source_sha,
                        'build_script_sha256': script_sha, 'sdk_version': sdk_version,
                        'toolchain_version': toolchain_version,
                        'tools': tools})
    destination = record_path(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix='.local-build-', dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(document, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, destination)  # Exclusive publication; no partial record is visible.
    finally:
        temporary.unlink(missing_ok=True)
    return document


def verify_record(root, lock, *, sdk_version, toolchain_version, inspect_image=inspect_image):
    source_sha = _source(root, lock)
    script_sha = _script_sha(root)
    path = _file(root, RECORD_RELATIVE, 'FFmpeg build record')
    try:
        document = _record(json.loads(path.read_text(), object_pairs_hook=_unique_pairs))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ValueError(f'Invalid FFmpeg build record schema: {error}') from error
    if document['source_sha256'] != source_sha:
        raise ValueError('FFmpeg build record source SHA256 differs from pinned input')
    if document['build_script_sha256'] != script_sha:
        raise ValueError('FFmpeg build script SHA256 differs from build record')
    if document['sdk_version'] != sdk_version:
        raise ValueError('FFmpeg build record SDK differs from selected SDK')
    if document['toolchain_version'] != toolchain_version:
        raise ValueError('FFmpeg build record toolchain differs from selected toolchain')
    actual = _tools(root, lock, Path('.build/dependencies/ffmpeg/install'),
                    sdk_version, inspect_image)
    if document['tools'] != actual:
        raise ValueError('FFmpeg tool SHA256 differs from build record')
    return actual
