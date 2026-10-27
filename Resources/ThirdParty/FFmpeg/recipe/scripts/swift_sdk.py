#!/usr/bin/env python3
"""Run SwiftPM with the selected macOS SDK also passed to the Clang linker driver."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

from media_bundle_macho import parse_load_commands


def selected_sdk():
    path = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    if not path or not Path(path).is_absolute():
        raise ValueError(f'Invalid macOS SDK path returned by xcrun: {path!r}')
    return Path(path)


def sdk_version(sdk):
    return subprocess.check_output(['xcrun', '--sdk', str(sdk), '--show-sdk-version'], text=True).strip()


def command(action, arguments, *, sdk):
    # Swift 6.4 forwards --sysroot to Clang. Direct Clang invocation on this
    # toolchain needs -isysroot to derive ld's SDK version from SDKSettings.json.
    return ['swift', action, '--sdk', str(sdk),
            '-Xswiftc', '-Xclang-linker', '-Xswiftc', '-isysroot',
            '-Xswiftc', '-Xclang-linker', '-Xswiftc', str(sdk), *arguments]


def binary_sdk(binary):
    output = subprocess.check_output(['xcrun', 'otool', '-l', str(binary)], text=True)
    return parse_load_commands(output).sdk_version


def verify_linked_sdk(binary, *, expected):
    actual = binary_sdk(binary)
    def version(value):
        return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])
    if actual is None or version(actual) != version(expected):
        raise ValueError(f'Linked SDK mismatch: {binary}: expected {expected}, found {actual}')
    print(f'VERIFIED linked SDK: {actual}: {binary}', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'test'])
    parser.add_argument('--sdk', type=Path, help='explicit SDK; defaults to the selected Xcode macOS SDK')
    options, arguments = parser.parse_known_args()
    sdk = options.sdk if options.sdk is not None else selected_sdk()
    print(f'Swift compiler and Clang linker SDK: {sdk}', file=sys.stderr, flush=True)
    # Preserve the supervisor's process group, signals and exit status.
    os.execvp('swift', command(options.action, arguments, sdk=sdk))


if __name__ == '__main__':
    main()
