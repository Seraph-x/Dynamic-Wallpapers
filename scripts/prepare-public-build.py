#!/usr/bin/env python3
"""Prepare pinned, non-GUI build inputs and products for a local source build."""

import argparse
import ctypes
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile

from ffmpeg_build_record import (record_path, validate_staged_tools,
                                 verify_record, write_record)
from media_dependencies import (cef_prepared_paths, expected_mpv_library_names,
                                load_lock, prepare_artifact, verify_cef_prepared,
                                verify_locked_inputs, verify_mpv_prepared)
from product_configuration import load as load_product_configuration
from swift_sdk import selected_sdk, sdk_version as get_sdk_version


MODULES = ('cef', 'mpv', 'ffmpeg')


def publish_directory(source, destination):
    """Darwin RENAME_EXCL publishes a prepared directory without replacing another."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def extract_cef(archive, destination, version):
    """Extract only regular entries beneath the exact pinned CEF archive root."""
    prefix = f'cef_binary_{version}_macosarm64_minimal'
    destination = Path(destination)
    with tarfile.open(archive, 'r:bz2') as source:
        members = source.getmembers()
        seen = set()
        for member in members:
            name = member.name.rstrip('/')
            parts = PurePosixPath(name).parts
            if (not name or '\\' in name or name.startswith('/') or '..' in parts
                    or not parts or parts[0] != prefix or name in seen
                    or not (member.isfile() or member.isdir())):
                raise ValueError(f'Invalid CEF archive member: {member.name}')
            seen.add(name)
        if f'{prefix}/include/cef_app.h' not in seen:
            raise ValueError('CEF archive lacks the expected header')
        if f'{prefix}/CMakeLists.txt' not in seen:
            raise ValueError('CEF archive lacks the expected wrapper build recipe')
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            stream = source.extractfile(member)
            if stream is None:
                raise ValueError(f'Unreadable CEF archive member: {member.name}')
            with stream, target.open('xb') as output:
                shutil.copyfileobj(stream, output)
            target.chmod(member.mode & 0o777)


def prepare_cef(root, lock, product_target):
    dependency_root = Path(root) / '.build/dependencies'
    cef_root = dependency_root / 'cef'
    header, wrapper = cef_prepared_paths(lock, dependency_root, product_target=product_target)
    extracted = header.parents[1]
    if extracted.exists() or wrapper.exists():
        verify_cef_prepared(lock, dependency_root, product_target=product_target)
        return
    archive = dependency_root / lock['modules']['cef']['artifacts'][0]['path']
    stage = Path(tempfile.mkdtemp(prefix='.cef-build-', dir=cef_root))
    extract_cef(archive, stage, lock['modules']['cef']['version'])
    staged_source = stage / extracted.name
    build = stage / 'wrapper-make'
    commands = [
        ['cmake', '-S', str(staged_source), '-B', str(build), '-G', 'Unix Makefiles',
         '-DPROJECT_ARCH=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
         '-DUSE_SANDBOX=OFF', '-DCMAKE_BUILD_TYPE=Release',
         '-DCMAKE_C_COMPILER=/usr/bin/clang', '-DCMAKE_CXX_COMPILER=/usr/bin/clang++'],
        ['cmake', '--build', str(build), '--target', 'libcef_dll_wrapper', '-j', '6'],
    ]
    for index, command in enumerate(commands):
        with (stage / f'cmake-{index}.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    publish_directory(staged_source, extracted)
    publish_directory(build, wrapper.parents[1])
    verify_cef_prepared(lock, dependency_root, product_target=product_target)


def sign_mpv(path):
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)


def prepare_mpv(root, lock, product_target, *, signer=sign_mpv):
    dependency_root = Path(root) / '.build/dependencies'
    module_root = dependency_root / 'mpv'
    runtime = module_root / 'runtime-lib'
    if runtime.exists():
        verify_mpv_prepared(lock, dependency_root, product_target=product_target)
        return
    stage = Path(tempfile.mkdtemp(prefix='.runtime-', dir=module_root))
    for name in expected_mpv_library_names(lock):
        shutil.copy2(module_root / 'lib' / name, stage / name)
        signer(stage / name)
    publish_directory(stage, runtime)
    verify_mpv_prepared(lock, dependency_root, product_target=product_target)


def prepare_ffmpeg(root, lock, *, sdk_version, toolchain_version):
    root = Path(root)
    module_root = root / '.build/dependencies/ffmpeg'
    install = module_root / 'install'
    record = record_path(root)
    if install.exists() or record.exists():
        verify_record(root, lock, sdk_version=sdk_version,
                      toolchain_version=toolchain_version)
        return
    artifact = lock['modules']['ffmpeg']['artifacts'][0]
    stage = Path(tempfile.mkdtemp(prefix='.build-', dir=module_root))
    subprocess.run(['bash', str(root / 'scripts/feasibility/ffmpeg/build.sh'),
                    str(root / '.build/dependencies' / artifact['path']),
                    artifact['sha256'], str(stage)], cwd=root, check=True)
    validate_staged_tools(root, lock, stage / 'install', sdk_version=sdk_version)
    publish_directory(stage / 'install', install)
    write_record(root, lock, sdk_version=sdk_version,
                 toolchain_version=toolchain_version)


def prepare(root, modules=MODULES):
    root = Path(root)
    lock = load_lock(root / 'scripts/media-dependencies.json', root)
    dependency_root = root / '.build/dependencies'
    for name in modules:
        if name not in MODULES:
            raise ValueError(f'Unknown dependency module: {name}')
        for artifact in lock['modules'][name]['artifacts']:
            prepare_artifact(dependency_root, artifact)
        verify_locked_inputs(lock, dependency_root, (name,))
        product_target = load_product_configuration(
            root / 'scripts/product-configuration.json').target
        if name == 'cef':
            prepare_cef(root, lock, product_target)
        elif name == 'mpv':
            prepare_mpv(root, lock, product_target)
        else:
            sdk = selected_sdk()
            version = get_sdk_version(sdk)
            toolchain = subprocess.check_output(['/usr/bin/clang', '--version'], text=True).splitlines()[0]
            prepare_ffmpeg(root, lock, sdk_version=version, toolchain_version=toolchain)
        print(f'PREPARED verified module={name}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('modules', nargs='*', choices=MODULES,
                        help='omitted means CEF, mpv and FFmpeg')
    options = parser.parse_args()
    prepare(Path(__file__).resolve().parents[1], tuple(options.modules or MODULES))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f'PUBLIC BUILD PREPARATION FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
