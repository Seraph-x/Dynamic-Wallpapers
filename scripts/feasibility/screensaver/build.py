#!/usr/bin/env python3
"""Build a real MH_BUNDLE probe. Does not install or select a system screen saver."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError

SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE.parents[1]))
from media_bundle import publish_exclusively


def run(arguments):
    subprocess.run(arguments, check=True)


def load_metadata(source):
    try:
        info = plistlib.loads((source / 'Info.plist').read_bytes())
    except (plistlib.InvalidFileException, ExpatError, ValueError) as error:
        raise ValueError(f'Invalid probe metadata: {error}') from error
    if not isinstance(info, dict):
        raise ValueError('Probe metadata must be a dictionary.')
    expected = {
        'CFBundlePackageType': 'BNDL',
        'CFBundleIdentifier': 'local.dynamicwallpaper.screensaver.probe',
        'CFBundleExecutable': 'DWNativeScreenSaverProbe',
        'NSPrincipalClass': 'DWNativeScreenSaverProbeView',
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'Invalid probe metadata: {key} must be {value!r}.')
    for key in ('CFBundleName', 'CFBundleVersion', 'CFBundleShortVersionString', 'LSMinimumSystemVersion'):
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f'Invalid probe metadata: {key} must be a nonempty string.')
    return info


def build(output, *, source=SOURCE):
    if output.exists() or output.is_symlink():
        raise FileExistsError(f'Output already exists: {output}')
    info = load_metadata(source)
    sources = [source / name for name in ('ProbeView.swift', 'ProbeAccess.swift',
                                         'ProbeConfiguration.swift', 'ProbePlayback.swift')]
    for path in sources:
        if not path.is_file():
            raise FileNotFoundError(f'Required probe source is missing: {path}')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    target_info = json.loads(subprocess.check_output(['xcrun', 'swiftc', '-print-target-info']))
    arch = platform.machine()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.screensaver-build-', dir=output.parent) as temporary:
        work = Path(temporary)
        bundle = work / 'Probe.saver'
        executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
        executable.parent.mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        obj = work / 'Probe.o'
        run(['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{arch}-apple-macosx14.0',
             '-swift-version', '5', '-module-name', 'DWNativeScreenSaverProbe',
             '-parse-as-library', '-whole-module-optimization', '-emit-object',
             *sources,
             '-o', obj])
        search_paths = [Path(sdk) / 'usr/lib/swift',
                        *target_info['paths']['runtimeLibraryPaths']]
        run(['xcrun', 'clang', '-arch', arch, '-isysroot', sdk, '-mmacosx-version-min=14.0',
             '-bundle', obj, *[f'-L{path}' for path in search_paths],
             '-Wl,-rpath,/usr/lib/swift', '-framework', 'ScreenSaver', '-framework', 'AppKit',
             '-o', executable])
        run(['plutil', '-lint', bundle / 'Contents/Info.plist'])
        run(['codesign', '--force', '--sign', '-', bundle])
        run(['codesign', '--verify', '--strict', bundle])
        publish_exclusively(bundle, output)
    print(f'BUILT PROBE (not installed): {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.output.absolute())


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'PROBE BUILD FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
