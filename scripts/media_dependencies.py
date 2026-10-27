#!/usr/bin/env python3
"""Verify or prepare pinned dependency inputs. Never runs media/GUI probes."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

from media_bundle_macho import inspect_image as inspect_macho_image, is_system_path
from product_configuration import load as load_product_configuration

ROOT = Path(__file__).resolve().parents[1]
MODULES = ('cef', 'mpv', 'ffmpeg')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative_path(value):
    if (not isinstance(value, str) or not value or '\\' in value
            or PurePosixPath(value).is_absolute()
            or any(part in ('', '.', '..') for part in value.split('/'))):
        raise ValueError(f'Invalid relative path: {value!r}')
    return value


def sha256_value(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value):
        raise ValueError(f'Invalid SHA256: {value!r}')
    return value


def validate_artifact(artifact):
    if not isinstance(artifact, dict):
        raise ValueError('Artifact must be an object')
    relative_path(artifact.get('path'))
    sha256_value(artifact.get('sha256'))
    url = artifact.get('url')
    if not isinstance(url, str):
        raise ValueError('Artifact URL must be a string')
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError(f'HTTPS URL required: {url!r}')
    if 'size' in artifact and (type(artifact['size']) is not int or artifact['size'] <= 0):
        raise ValueError('Artifact size must be a positive integer')


def cache_path(root, relative):
    path = root / relative_path(relative)
    if path.is_symlink():
        raise ValueError(f'Cache symlink is not accepted: {path}')
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'Cache path escapes root through symlink: {path}')
    return path


def checked_bytes(path, artifact):
    if not path.is_file():
        raise FileNotFoundError(f'Missing regular cache file: {path}')
    actual = digest(path)
    if actual != artifact['sha256']:
        raise ValueError(f'SHA256 mismatch: {path}: expected={artifact["sha256"]} actual={actual}')
    if 'size' in artifact and path.stat().st_size != artifact['size']:
        raise ValueError(f'Size mismatch: {path}')


def manifest_artifacts(reference, root):
    if not isinstance(reference, dict):
        raise ValueError('Manifest reference must be an object')
    path = cache_path(root, reference.get('path'))
    sha256_value(reference.get('sha256'))
    checked_bytes(path, reference)
    prefix = relative_path(reference.get('cache_prefix'))
    entries = json.loads(path.read_text())
    if not isinstance(entries, list) or not entries:
        raise ValueError('Referenced library manifest must be a nonempty list')
    artifacts = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get('file'), str):
            raise ValueError('Invalid library manifest entry')
        if not re.fullmatch(r'[A-Za-z0-9_.+-]+\.dylib', entry['file']):
            raise ValueError('Invalid library filename')
        artifacts.append({'path': f'{prefix}/{entry["file"]}', 'url': entry.get('url'),
                          'sha256': entry.get('sha256')})
    return artifacts


def load_lock(path, root=ROOT):
    lock = json.loads(path.read_text())
    if not isinstance(lock, dict) or type(lock.get('schema_version')) is not int or lock['schema_version'] != 1:
        raise ValueError('Unsupported dependency lock schema')
    if 'target' in lock:
        raise ValueError('Dependency lock must not contain a product target')
    modules = lock.get('modules')
    if not isinstance(modules, dict) or not modules or set(modules) - set(MODULES):
        raise ValueError('Invalid or empty dependency modules')
    seen = set()
    for name, module in modules.items():
        if (not isinstance(module, dict) or not isinstance(module.get('version'), str)
                or not module['version'] or not isinstance(module.get('architecture'), str)
                or not module['architecture'] or not isinstance(module.get('minimum_macos'), str)
                or not module['minimum_macos']):
            raise ValueError(f'Invalid module metadata: {name}')
        artifacts = module.get('artifacts')
        if not isinstance(artifacts, list):
            raise ValueError(f'Invalid artifact list: {name}')
        if 'manifest' in module:
            artifacts = artifacts + manifest_artifacts(module['manifest'], root)
        if 'source_build' in module:
            if name != 'mpv' or 'manifest' in module or artifacts:
                raise ValueError('Controlled MPV source build cannot contain binary artifacts')
            reference = module['source_build']
            if (not isinstance(reference, dict) or set(reference) != {'path', 'sha256', 'output'}
                    or reference.get('output') != '.build/media-source-complete/mpv'):
                raise ValueError('Invalid controlled MPV source build output/reference')
            checked_bytes(cache_path(root, reference['path']), reference)
            from mpv_source_inputs import load_source_lock
            module['_source_lock'] = load_source_lock(root, root / reference['path'])
            if any(module[key] != module['_source_lock'][key]
                   for key in ('architecture', 'minimum_macos')):
                raise ValueError('Controlled MPV source target disagrees with dependency module')
        if not artifacts and 'source_build' not in module:
            raise ValueError(f'Empty artifact list: {name}')
        for artifact in artifacts:
            validate_artifact(artifact)
            if artifact['path'] in seen:
                raise ValueError(f'Duplicate cache path: {artifact["path"]}')
            seen.add(artifact['path'])
        module['artifacts'] = artifacts  # Local parsed document; never writes the lock.
    return lock


def verify_artifact(root, artifact):
    checked_bytes(cache_path(root, artifact['path']), artifact)


def prepared_error(message):
    raise ValueError(f'PREPARED DEPENDENCY INVALID: {message}')


def require_prepared_file(root, path):
    root = Path(root).resolve()
    path = Path(path)
    if path.is_symlink() or not path.resolve().is_relative_to(root):
        prepared_error(f'path escapes dependency root: {path}')
    if not path.is_file():
        prepared_error(f'missing regular file: {path}')
    return path.resolve()


def product_target_values(product_target):
    architecture = getattr(product_target, 'architecture', None)
    minimum_macos = getattr(product_target, 'minimum_macos', None)
    if not isinstance(architecture, str) or not architecture:
        prepared_error('invalid product target architecture')
    if not isinstance(minimum_macos, str) or not minimum_macos:
        prepared_error('invalid product target minimum macOS')
    return architecture, minimum_macos


def verify_module_target(module, product_target, name):
    architecture, maximum_macos = product_target_values(product_target)
    if module['architecture'] != architecture:
        prepared_error(
            f'{name} architecture {module["architecture"]} does not match product {architecture}')
    if version_tuple(module['minimum_macos']) > version_tuple(maximum_macos):
        prepared_error(
            f'{name} requires macOS {module["minimum_macos"]}, above product {maximum_macos}')
    return architecture, maximum_macos


def cef_prepared_paths(lock, dependency_root, *, product_target):
    architecture, _ = verify_module_target(lock['modules']['cef'], product_target, 'CEF')
    if architecture != 'arm64':
        prepared_error(f'unsupported CEF prepared architecture: {architecture}')
    version = lock['modules']['cef']['version']
    base = Path(dependency_root) / 'cef'
    header = base / f'cef_binary_{version}_macosarm64_minimal/include/cef_app.h'
    wrapper = base / 'wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a'
    return header, wrapper


def archive_member_names(path):
    return subprocess.check_output(['ar', '-t', str(path)], text=True, stderr=subprocess.STDOUT).splitlines()


def verify_cef_prepared(lock, dependency_root, *, product_target,
                        archive_members=archive_member_names):
    header, wrapper = cef_prepared_paths(lock, dependency_root, product_target=product_target)
    require_prepared_file(dependency_root, header)
    wrapper = require_prepared_file(dependency_root, wrapper)
    try:
        members = archive_members(wrapper)
    except (OSError, subprocess.CalledProcessError) as error:
        prepared_error(f'unreadable wrapper archive {wrapper}: {error}')
    if not members:
        prepared_error(f'empty wrapper archive: {wrapper}')


def expected_mpv_library_names(lock):
    if 'source_build' in lock['modules']['mpv']:
        return tuple(sorted(lock['modules']['mpv']['_source_lock']['libraries']))
    names = []
    for artifact in lock['modules']['mpv']['artifacts']:
        path = PurePosixPath(artifact['path'])
        if path.parts[:2] == ('mpv', 'lib') and path.suffix == '.dylib':
            names.append(path.name)
    if not names or len(names) != len(set(names)):
        prepared_error('locked MPV runtime library names are empty or duplicated')
    return tuple(sorted(names))


def mpv_prepared_root(root, lock):
    module = lock['modules']['mpv']
    if 'source_build' not in module:
        raise ValueError('MPV runtime requires a controlled source-build record')
    return Path(root) / module['source_build']['output']


def verify_codesign(path):
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def version_tuple(value):
    try:
        return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])
    except (AttributeError, ValueError):
        prepared_error(f'invalid macOS deployment target: {value!r}')


def verify_mpv_prepared(lock, dependency_root, *, product_target,
                        inspect_image=inspect_macho_image,
                        verify_signature=verify_codesign):
    expected_architecture, maximum_macos = verify_module_target(
        lock['modules']['mpv'], product_target, 'MPV')
    if 'source_build' in lock['modules']['mpv']:
        from mpv_source_build import verify_built
        return verify_built(Path(dependency_root).parent.parent)
    dependency_root = Path(dependency_root)
    for relative in ('mpv/include/mpv/client.h', 'mpv/include/mpv/render.h'):
        require_prepared_file(dependency_root, dependency_root / relative)
    expected = expected_mpv_library_names(lock)
    runtime = dependency_root / 'mpv/runtime-lib'
    if runtime.is_symlink() or not runtime.resolve().is_relative_to(dependency_root.resolve()):
        prepared_error(f'runtime directory escapes dependency root: {runtime}')
    if not runtime.is_dir():
        prepared_error(f'missing runtime directory: {runtime}')
    actual = tuple(sorted(path.name for path in runtime.iterdir()))
    if actual != expected:
        prepared_error(f'MPV runtime library set differs: expected={expected} actual={actual}')
    expected_set = set(expected)
    for name in expected:
        image = require_prepared_file(dependency_root, runtime / name)
        try:
            architectures, commands = inspect_image(image)
        except (OSError, subprocess.CalledProcessError, ValueError) as error:
            prepared_error(f'Mach-O inspection failed for {image}: {error}')
        if tuple(architectures) != (expected_architecture,):
            prepared_error(
                f'expected {expected_architecture}-only Mach-O {image}, got {architectures}')
        if version_tuple(commands.minimum_macos) > version_tuple(maximum_macos):
            prepared_error(
                f'Mach-O requires macOS {commands.minimum_macos}, above {maximum_macos}: {image}')
        try:
            verify_signature(image)
        except (OSError, subprocess.CalledProcessError, ValueError) as error:
            prepared_error(f'signature verification failed for {image}: {error}')
        for reference in commands.dependencies:
            if is_system_path(reference):
                continue
            prefix = '@rpath/'
            dependency = reference.removeprefix(prefix) if reference.startswith(prefix) else None
            if dependency not in expected_set or '/' in dependency:
                prepared_error(f'unresolved non-system dependency {image}: {reference}')
    if 'libmpv.2.dylib' not in expected_set:
        prepared_error('locked runtime set does not contain libmpv.2.dylib')


def verify_locked_inputs(lock, dependency_root, modules):
    for name in modules:
        module = lock['modules'][name]
        if 'source_build' in module:
            from mpv_source_inputs import verify_sources
            verify_sources(Path(dependency_root).parent.parent, module['_source_lock'])
        for artifact in module['artifacts']:
            verify_artifact(dependency_root, artifact)


def verify_prepared_dependencies(lock, dependency_root, modules=('cef', 'mpv'), *, product_target):
    for name in modules:
        if name == 'cef':
            verify_cef_prepared(lock, dependency_root, product_target=product_target)
        elif name == 'mpv':
            verify_mpv_prepared(lock, dependency_root, product_target=product_target)
        else:
            raise ValueError(f'No prepared-product verifier for module: {name}')
        print(f'PREPARED products verified module={name}', flush=True)


def verify_build_dependencies(root=ROOT, modules=('cef', 'mpv')):
    root = Path(root)
    lock = load_lock(root / 'scripts/media-dependencies.json', root)
    dependency_root = root / '.build/dependencies'
    verify_locked_inputs(lock, dependency_root, modules)
    print(f'PINNED inputs verified modules={" ".join(modules)}', flush=True)
    product_target = load_product_configuration(
        root / 'scripts/product-configuration.json').target
    verify_prepared_dependencies(
        lock, dependency_root, modules, product_target=product_target)


def download(url, path, *, curl='curl'):
    subprocess.run([curl, '--proto', '=https', '--proto-redir', '=https', '--http1.1',
                    '--fail', '--location', '--show-error', '--connect-timeout', '20',
                    '--max-time', '600', url, '--output', str(path)], check=True)


def prepare_artifact(root, artifact, *, downloader=download, source=None):
    path = cache_path(root, artifact['path'])
    if path.exists():
        checked_bytes(path, artifact)
        print(f'CACHE verified {artifact["path"]}', flush=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, filename = tempfile.mkstemp(prefix=f'.{path.name}.', suffix='.download', dir=path.parent)
    temporary = Path(filename)
    try:
        os.close(descriptor)
        if source is None:
            downloader(artifact['url'], temporary)
        else:
            shutil.copyfile(source, temporary)
        checked_bytes(temporary, artifact)
        with temporary.open('rb') as stream:
            os.fsync(stream.fileno())
        # Exclusive publication: a concurrent writer cannot be overwritten.
        os.link(temporary, path)
        print(f'PREPARED verified {artifact["path"]}', flush=True)
    finally:
        temporary.unlink()


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--verify', nargs='*', choices=MODULES, metavar='MODULE',
                        help='read-only input-cache verification; omitted modules means all')
    action.add_argument('--verify-build', nargs='*', choices=('cef', 'mpv'), metavar='MODULE',
                        help='verify pinned inputs and prepared products; omitted modules means cef and mpv')
    action.add_argument('--prepare', nargs='+', choices=MODULES, metavar='MODULE',
                        help='prepare only explicitly named modules')
    parser.add_argument('--archive', type=Path, help='import local archive for a single cef/ffmpeg module')
    parser.add_argument('--build', action='store_true',
                        help='with --prepare ffmpeg, use the verified non-GUI source build')
    parser.add_argument('--curl', default='curl', help='explicit download executable; no alternate downloader')
    args = parser.parse_args()
    if args.archive and (args.prepare is None or len(args.prepare) != 1 or args.prepare[0] == 'mpv'):
        parser.error('--archive requires exactly one --prepare cef or ffmpeg')
    if args.build and args.prepare != ['ffmpeg']:
        parser.error('--build requires exactly --prepare ffmpeg')
    return args


def main():
    args = arguments()
    lock = load_lock(ROOT / 'scripts/media-dependencies.json')
    if args.verify_build is not None:
        product_target = load_product_configuration().target
        selected = tuple(args.verify_build or ('cef', 'mpv'))
        verify_locked_inputs(lock, ROOT / '.build/dependencies', selected)
        print(f'PINNED inputs verified modules={" ".join(selected)}', flush=True)
        verify_prepared_dependencies(
            lock, ROOT / '.build/dependencies', selected, product_target=product_target)
        print('COMPLETE scope=prepared-build-dependencies; runtime-images-static-only; '
              'distribution-license-review-incomplete')
        return
    selected = args.prepare if args.prepare is not None else (args.verify or list(lock['modules']))
    cache = ROOT / '.build/dependencies'
    for name in selected:
        module = lock['modules'][name]
        print(f'MODULE {name} version={module["version"]} license={module.get("license_status", "not-audited")}', flush=True)
        for artifact in module['artifacts']:
            if args.prepare is None:
                verify_artifact(cache, artifact)
            else:
                prepare_artifact(cache, artifact, source=args.archive,
                                 downloader=lambda url, path: download(url, path, curl=args.curl))
        print(f'INPUTS verified module={name} count={len(module["artifacts"])}', flush=True)
    if args.build:
        subprocess.run([sys.executable, str(ROOT / 'scripts/prepare-public-build.py'), 'ffmpeg'],
                       cwd=ROOT, check=True)
    print('COMPLETE scope=pinned-input-cache; runtime-not-tested; distribution-license-review-incomplete')


def run_cli():
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(run_cli())
