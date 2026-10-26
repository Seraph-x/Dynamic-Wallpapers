#!/usr/bin/env python3
"""Build a new standalone Editor candidate and ZIP; never install or publish it."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import runpy
import re

from editor_product import application_metadata, configuration, load_editor_product
from media_bundle import build_helpers, extract_cef_framework, publish_exclusively, validate_output
from media_bundle_macho import (inspect_image, macho_files, rpath_rewrite_commands,
                                run, sha256, sign_bundle, verify_macho_closure)
from media_dependencies import load_lock, verify_artifact
from swift_sdk import command, selected_sdk, sdk_version, verify_linked_sdk

RESOURCE_BUNDLE = 'DynamicWallpaperEditor_EditorApp.bundle'
PERSONAL_PATH = re.compile(rb'/Users/[A-Za-z0-9._-]+/|(?<![A-Za-z0-9_./:-])/home/[A-Za-z0-9._-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9._-]+\\')


def check_personal_paths(data):
    if PERSONAL_PATH.search(data):
        raise ValueError('Personal home path embedded in the distribution payload')


def prepare_source(root, destination, cef):
    """Recompile every locally built input in a neutral tree, including CEF wrapper."""
    destination.mkdir()
    for name in ('Sources', 'Tests', 'Editor', 'scripts', 'Resources'):
        shutil.copytree(root / name, destination / name,
                        ignore=shutil.ignore_patterns('.build', '.swiftpm', '__pycache__', '.DS_Store'))
    for name in ('Package.swift', 'LICENSE'):
        shutil.copy2(root / name, destination / name)
    (destination / 'docs').mkdir()
    shutil.copy2(root / 'docs/editor-install.md', destination / 'docs/editor-install.md')
    for artifact in cef['artifacts']:
        path = destination / '.build/dependencies' / artifact['path']
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / '.build/dependencies' / artifact['path'], path)
    prepare = runpy.run_path(str(destination / 'scripts/prepare-public-build.py'))['prepare_cef']
    lock = load_lock(destination / 'scripts/media-dependencies.json', destination)
    prepare(destination, lock, configuration(root, load_editor_product(root / 'Editor/product.json')).target)
    return destination


def prepare_notices(root, resources):
    target = resources / 'ThirdParty'
    target.mkdir()
    for name in ('CEF', 'WebWallGL'):
        shutil.copytree(root / 'Resources/ThirdParty' / name, target / name)
    shutil.copytree(root / 'Editor/ThirdParty', target / 'Editor')
    shutil.copy2(root / 'LICENSE', resources / 'LICENSE')
    shutil.copy2(root / 'Editor/README.md', resources / 'README.md')
    (target / 'README.md').write_text(
        '# Editor runtime notices\n\n'
        'This application bundles CEF/Chromium, WebWallGL and @webwallgl/editor.\n'
        'See the adjacent license, credits and pinned provenance files.\n'
        'MPV and FFmpeg are not linked or distributed in this application.\n')


def editor_resource_root(resources):
    bundle = resources / RESOURCE_BUNDLE
    return bundle / 'Contents/Resources' if (bundle / 'Contents/Resources').is_dir() else bundle


def prepare_audio_permission_localizations(resources):
    localized = editor_resource_root(resources)
    for language in ('en', 'zh-Hans', 'ja', 'fr', 'es'):
        source = localized / f'{language}.lproj/InfoPlist.strings'
        if not source.is_file():
            raise ValueError(f'Missing Editor audio permission localization: {language}')
        values = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(source)], text=True))
        if set(values) != {'NSAudioCaptureUsageDescription'} or not isinstance(values['NSAudioCaptureUsageDescription'], str) or not values['NSAudioCaptureUsageDescription'].strip():
            raise ValueError(f'Invalid Editor audio permission localization: {language}')
        target = resources / f'{language}.lproj'
        target.mkdir(exist_ok=True)
        shutil.copy2(source, target / 'InfoPlist.strings')


def verify_offline_resources(resources, root):
    localized = editor_resource_root(resources)
    provenance = json.loads((root / 'Editor/ThirdParty/provenance.json').read_text())
    for folder, field in (('EditorWeb', 'files'), ('ScenePreviewWeb', 'previewFiles')):
        for name, digest in provenance[field].items():
            path = localized / folder / name
            if not path.is_file() or sha256(path) != digest:
                raise ValueError(f'Editor resource differs from pinned provenance: {folder}/{name}')
    shared = ('index.html', 'scene.css', 'scene-runtime.mjs', 'scene-spectrum.mjs',
              'scene-source.mjs', 'scene-protocol.mjs', 'webwallgl.bundle.mjs')
    if not {'scene-shell.mjs', 'scene-preview-api.mjs', *shared}.issubset(provenance['previewFiles']):
        raise ValueError('Missing Editor preview resource provenance')
    for name in shared:
        if (localized / 'ScenePreviewWeb' / name).read_bytes() != (root / 'Sources/WallpaperApp/Resources/SceneRuntime' / name).read_bytes():
            raise ValueError(f'Editor shared preview resource differs from Main: {name}')


def verify_payload(app, root, product):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info != application_metadata(root, product):
        raise ValueError('Editor metadata changed during packaging')
    resources = app / 'Contents/Resources'
    bundle = resources / RESOURCE_BUNDLE
    # SwiftPM's current macOS resource layout includes Contents/Resources.
    localized = bundle / 'Contents/Resources' if (bundle / 'Contents/Resources').is_dir() else bundle
    for language in configuration(root, product).localizations:
        if not (localized / f'{language}.lproj/Localizable.strings').is_file():
            raise ValueError(f'Missing Editor localization: {language}')
    verify_offline_resources(resources, root)
    for language in configuration(root, product).localizations:
        source = localized / f'{language}.lproj/InfoPlist.strings'
        target = resources / f'{language}.lproj/InfoPlist.strings'
        if not target.is_file() or target.read_bytes() != source.read_bytes():
            raise ValueError(f'Missing or changed top-level Editor audio permission localization: {language}')
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            # Source roots must not be embedded in distributed executables/resources.
            with path.open('rb') as stream:
                previous = b''
                while chunk := stream.read(1024 * 1024):
                    data = previous + chunk
                    try:
                        check_personal_paths(data)
                    except ValueError as error:
                        raise ValueError(f'{error}: {path.relative_to(app)}') from error
                    previous = data[-4096:]
    return verify_macho_closure(app, product_target=configuration(root, product).target)


def build(root, output):
    product = load_editor_product(root / 'Editor/product.json')
    config = configuration(root, product)
    output = validate_output(root, output)
    output.parent.mkdir(parents=True, exist_ok=True)
    lock = load_lock(root / 'scripts/media-dependencies.json', root)
    cef = lock['modules']['cef']
    for artifact in cef['artifacts']:
        verify_artifact(root / '.build/dependencies', artifact)
    subprocess.run(['node', str(root / 'Editor/Web/build.mjs'), '--check'], check=True, cwd=root)
    # Keep generated SwiftPM Bundle.module paths independent of the user's home.
    with tempfile.TemporaryDirectory(prefix='dynamic-wallpaper-editor-', dir='/private/tmp') as temporary:
        stage = Path(temporary)
        source = prepare_source(root, stage / 'source', cef)
        sdk = selected_sdk()
        arguments = ['-c', 'release', '--disable-sandbox', '--scratch-path', str(stage / 'swift'),
                     '-Xswiftc', '-file-prefix-map', '-Xswiftc', f'{source}=.',
                     '-Xcc', f'-ffile-prefix-map={source}=.', '-Xcxx', f'-ffile-prefix-map={source}=.']
        subprocess.run(command('build', arguments, sdk=sdk), cwd=source / 'Editor', check=True)
        binaries = Path(subprocess.check_output(command('build', arguments + ['--show-bin-path'], sdk=sdk),
                                                cwd=source / 'Editor', text=True).strip())
        binary = binaries / product['executable']
        verify_linked_sdk(binary, expected=sdk_version(sdk))
        app = stage / config.application.bundle_name
        contents = app / 'Contents'
        for directory in ('MacOS', 'Resources', 'Frameworks'):
            (contents / directory).mkdir(parents=True)
        shutil.copy2(binary, contents / 'MacOS' / product['executable'])
        shutil.copytree(binaries / RESOURCE_BUNDLE, contents / 'Resources' / RESOURCE_BUNDLE)
        shutil.copy2(root / 'Resources/AppIcon.icns', contents / 'Resources/AppIcon.icns')
        prepare_audio_permission_localizations(contents / 'Resources')
        prepare_notices(source, contents / 'Resources')
        (contents / 'Info.plist').write_bytes(plistlib.dumps(application_metadata(root, product)))
        archive = root / '.build/dependencies' / cef['artifacts'][0]['path']
        extract_cef_framework(archive, contents / 'Frameworks', cef['version'])
        build_helpers(source, stage, contents / 'Frameworks', cef['version'], config)
        for helper in (contents / 'Frameworks').glob('*.app'):
            (helper / 'Contents/Resources').mkdir()
        # Drop only build-machine rpaths; any unresolved dependency fails closure verification.
        for image in macho_files(app):
            for action in rpath_rewrite_commands(image, inspect_image(image)[1].rpaths, required=()):
                run(action)
        sign_bundle(app)
        images = verify_payload(app, root, product)
        receipt = {'product': product, 'cef_version': cef['version'], 'images': images,
                   'signature': 'ad-hoc; not notarized', 'source_root_embedded': False}
        # Cross-volume publication uses a sibling staging directory, then exclusive rename.
        with tempfile.TemporaryDirectory(prefix='.editor-candidate-', dir=output.parent) as publish:
            candidate = Path(publish) / app.name
            shutil.copytree(app, candidate, symlinks=True)
            run(['codesign', '--verify', '--deep', '--strict', candidate])
            publish_exclusively(candidate, output)
        output.with_suffix('.receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return product


def archive_candidate(root, app, product):
    name = f"DynamicWallpaperEditor-{product['version']}-build{product['build']}-arm64"
    archive = app.parent / (name + '.zip')
    if archive.exists():
        raise FileExistsError(archive)
    with tempfile.TemporaryDirectory(prefix='.editor-archive-', dir=app.parent) as temporary:
        stage = Path(temporary)
        delivery = stage / name
        delivery.mkdir()
        shutil.copytree(app, delivery / app.name, symlinks=True)
        shutil.copy2(root / 'docs/editor-install.md', delivery / 'INSTALL.md')
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(delivery), str(archive)], check=True)
        unpacked = stage / 'unpacked'
        subprocess.run(['ditto', '-x', '-k', str(archive), str(unpacked)], check=True)
        verify_payload(unpacked / name / app.name, root, product)
    archive.with_name(name + '-SHA256SUMS.txt').write_text(f'{sha256(archive)}  {archive.name}\n')
    return archive


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='new .app beneath this checkout dist/')
    parser.add_argument('--zip', action='store_true', help='also create and re-verify a separate ZIP')
    args = parser.parse_args()
    product = build(root, args.output.absolute())
    if args.zip:
        print(f'EDITOR ARCHIVE: {archive_candidate(root, args.output.absolute(), product)}')
    print(f'EDITOR CANDIDATE: {args.output}; ad-hoc signed, not notarized, not installed or published')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'EDITOR PACKAGING FAILED: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, file=sys.stderr)
        raise SystemExit(1)
