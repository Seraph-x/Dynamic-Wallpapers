"""Build and verify the independent product screen saver bundle."""
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
from xml.parsers.expat import ExpatError

from media_bundle import publish_exclusively
from media_bundle_macho import parse_load_commands
from product_configuration import load as load_product_configuration

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Resources/ScreenSaver'
CONFIG = load_product_configuration()


def checked(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def read_metadata(source):
    path = Path(source) / 'Info.plist'
    if not path.is_file() or path.is_symlink():
        raise FileNotFoundError(f'Required screen saver metadata is missing: {path}')
    try:
        value = plistlib.loads(path.read_bytes())
    except (plistlib.InvalidFileException, ExpatError, ValueError) as error:
        raise ValueError(f'Invalid screen saver metadata: {error}') from error
    if not isinstance(value, dict):
        raise ValueError('Screen saver metadata must be a dictionary.')
    return value


def staged_metadata(source=RESOURCES, configuration=CONFIG):
    template = read_metadata(source)
    expected_template = {'CFBundlePackageType': 'BNDL', 'NSHighResolutionCapable': True}
    if template != expected_template:
        raise ValueError('Screen saver Info.plist must be a stable metadata template')
    return {**template, **configuration.screen_saver_metadata()}


def load_metadata(source, configuration=CONFIG):
    value = read_metadata(source)
    expected = {
        'CFBundlePackageType': 'BNDL',
        'NSHighResolutionCapable': True,
        **configuration.screen_saver_metadata(),
    }
    if value != expected:
        raise ValueError('Screen saver metadata does not match product configuration')
    return value


def source_files(target):
    directory = ROOT / target.path
    files = sorted(directory.glob('*.swift'))
    if not files or any(path.is_symlink() or not path.is_file() for path in files):
        raise FileNotFoundError(f'Missing or invalid Swift sources for {target.name}: {directory}')
    return files


def validate_output(output):
    output = Path(os.path.abspath(output))
    if output.suffix != '.saver':
        raise ValueError(f'Screen saver output must end in .saver: {output}')
    if output.exists() or output.is_symlink():
        raise FileExistsError(f'Output already exists; choose a new path: {output}')
    parent = output.parent
    while parent != ROOT.parent and parent != parent.parent:
        if parent.is_symlink():
            raise ValueError(f'Symlinked output parent is not accepted: {parent}')
        if parent.exists() and not parent.is_dir():
            raise ValueError(f'Output parent is not a directory: {parent}')
        parent = parent.parent
    return output


def compile_module(target, work, sdk, configuration=CONFIG):
    name = target.name
    module = work / f'{name}.swiftmodule'
    obj = work / f'{name}.o'
    command = ['xcrun', 'swiftc', '-sdk', sdk, '-target',
               f'{configuration.target.architecture}-apple-macosx{configuration.target.minimum_macos}',
               '-swift-version', configuration.target.swift_language_mode,
               '-parse-as-library', '-whole-module-optimization', '-O',
               '-module-cache-path', work / 'ModuleCache', '-I', work,
               '-module-name', name, '-emit-module', '-emit-module-path', module,
               '-emit-object', *source_files(target), '-o', obj]
    checked(command)
    return obj


def verify_bundle(bundle, expected_sdk=None, configuration=CONFIG):
    info = load_metadata(bundle / 'Contents', configuration)
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.is_file() or executable.is_symlink():
        raise ValueError(f'Missing screen saver executable: {executable}')
    header = subprocess.check_output(['xcrun', 'otool', '-hv', executable], text=True)
    if ' BUNDLE ' not in header:
        raise ValueError('Screen saver executable is not an MH_BUNDLE image.')
    architectures = subprocess.check_output(['lipo', '-archs', executable], text=True).split()
    if architectures != [configuration.target.architecture]:
        raise ValueError(
            f'Expected one {configuration.target.architecture} slice, found: {architectures}')
    commands = parse_load_commands(subprocess.check_output(['otool', '-m', '-l', executable], text=True))
    if commands.minimum_macos != configuration.target.minimum_macos:
        raise ValueError(f'Unexpected deployment target: {commands.minimum_macos}')
    if expected_sdk is not None and commands.sdk_version != expected_sdk:
        raise ValueError(f'Linked SDK mismatch: expected {expected_sdk}, found {commands.sdk_version}')
    linked = subprocess.check_output(['otool', '-L', executable], text=True)
    dependencies = [line.strip().split(' (')[0] for line in linked.splitlines()[1:]]
    if not dependencies or any(not value.startswith(('/System/Library/', '/usr/lib/')) for value in dependencies):
        raise ValueError(f'Screen saver has a non-system dependency:\n{linked}')
    for language in configuration.localizations:
        strings = bundle / f'Contents/Resources/{language}.lproj/Localizable.strings'
        if not strings.is_file() or strings.is_symlink():
            raise ValueError(f'Missing localization: {strings}')
        checked(['plutil', '-lint', strings], stdout=subprocess.DEVNULL)
    checked(['codesign', '--verify', '--strict', bundle])
    return {'architectures': architectures, 'minimumMacOS': commands.minimum_macos,
            'sdk': commands.sdk_version, 'dependencies': dependencies}


def build(output, source=RESOURCES, configuration=CONFIG):
    output = validate_output(output)
    metadata = staged_metadata(source, configuration)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    sdk_version = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
    arch = platform.machine()
    if arch != configuration.target.architecture:
        raise ValueError(
            f'This product candidate requires a {configuration.target.architecture} build host, found {arch}.')
    target_info = json.loads(subprocess.check_output(['xcrun', 'swiftc', '-print-target-info'], text=True))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.screensaver-build-', dir=output.parent) as temporary:
        work = Path(temporary)
        bundle = work / configuration.screen_saver.bundle_name
        executable = bundle / 'Contents/MacOS' / metadata['CFBundleExecutable']
        executable.parent.mkdir(parents=True)
        resources = bundle / 'Contents/Resources'; resources.mkdir()
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
        for language in configuration.localizations:
            origin = Path(source) / f'{language}.lproj'
            if origin.is_symlink() or not (origin / 'Localizable.strings').is_file():
                raise FileNotFoundError(f'Missing localization source: {origin}')
            shutil.copytree(origin, resources / origin.name)
        objects = [
            compile_module(target, work, sdk, configuration)
            for target in configuration.topological_screen_saver_targets()
        ]
        search_paths = [Path(sdk) / 'usr/lib/swift', *map(Path, target_info['paths']['runtimeLibraryPaths'])]
        checked(['xcrun', 'clang', '-arch', arch, '-isysroot', sdk,
                 f'-mmacosx-version-min={configuration.target.minimum_macos}',
                 '-bundle', *objects, *[f'-L{path}' for path in search_paths], '-Wl,-rpath,/usr/lib/swift',
                 '-framework', 'ScreenSaver', '-framework', 'AppKit', '-framework', 'AVFoundation',
                 '-framework', 'CoreImage', '-framework', 'ImageIO', '-framework', 'QuartzCore',
                 '-framework', 'IOKit',
                 '-o', executable])
        checked(['plutil', '-lint', bundle / 'Contents/Info.plist'], stdout=subprocess.DEVNULL)
        checked(['codesign', '--force', '--sign', '-', '--timestamp=none', bundle], stdout=subprocess.DEVNULL)
        verification = verify_bundle(
            bundle, expected_sdk=sdk_version, configuration=configuration)
        publish_exclusively(bundle, output)
    print(json.dumps({'bundle': str(output), **verification}, sort_keys=True))
    return output
