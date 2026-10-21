#!/usr/bin/env python3
"""Build or package a new local app candidate. Does not launch or publish it."""
import argparse
from contextlib import ExitStack
from pathlib import Path
import subprocess
import sys
import tempfile

from media_bundle import package, validate_output
from media_dependencies import verify_build_dependencies
from media_dependencies import load_lock
from ffmpeg_build_record import current_build_environment, verify_record
from screensaver_bundle import build as build_screensaver
from product_configuration import load as load_product_configuration
from swift_sdk import command, selected_sdk, sdk_version, verify_linked_sdk


def verify_ffmpeg_for_build(root):
    lock = load_lock(root / 'scripts/media-dependencies.json', root)
    sdk, toolchain = current_build_environment()
    return verify_record(root, lock, sdk_version=sdk, toolchain_version=toolchain)


def main():
    root = Path(__file__).resolve().parents[1]
    configuration = load_product_configuration(root / 'scripts/product-configuration.json')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, help='existing release executable; bypass SwiftPM entirely')
    parser.add_argument('--screensaver', type=Path,
                        help='verified .saver input; required with --binary')
    parser.add_argument('--output', type=Path,
                        default=root / 'dist' / configuration.application.bundle_name,
                        help='new .app below this worktree dist; existing targets are never replaced')
    parser.add_argument('--icon', type=Path, help='existing .icns; defaults to Resources/AppIcon.icns')
    args = parser.parse_args()
    if args.binary is not None and args.screensaver is None:
        parser.error('--binary requires an explicit --screensaver; packaging never reuses or builds one implicitly')
    output = validate_output(root, args.output)
    with ExitStack() as stack:
        binary = args.binary
        screensaver = args.screensaver
        if binary is None:
            verify_build_dependencies()
            verify_ffmpeg_for_build(root)
            sdk = selected_sdk()
            subprocess.run(command('build', ['-c', 'release', '--disable-sandbox'], sdk=sdk), cwd=root, check=True)
            directory = subprocess.check_output(command('build', ['-c', 'release', '--show-bin-path',
                                                 '--disable-sandbox'], sdk=sdk), cwd=root, text=True).strip()
            binary = Path(directory) / configuration.application.executable
            verify_linked_sdk(binary, expected=sdk_version(sdk))
            if screensaver is None:
                temporary = Path(stack.enter_context(tempfile.TemporaryDirectory(
                    prefix='screensaver-for-app-', dir=root / '.build')))
                screensaver = build_screensaver(
                    temporary / configuration.screen_saver.bundle_name)
        package(root, binary=binary.absolute(), screensaver=screensaver.absolute(),
                output=output, icon=args.icon)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'PACKAGING FAILED: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, file=sys.stderr)
        raise SystemExit(1)
