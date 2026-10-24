#!/usr/bin/env python3
"""Run actual Swift SceneSurface/CEF integration; build separately first."""
import argparse
import hashlib
import json
import pathlib
import runpy
import shutil
import uuid


def positive_seconds(value):
    seconds = int(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError('timeout must be positive')
    return seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=positive_seconds, default=60)
    parser.add_argument('--runtime-root', type=pathlib.Path, help='explicit packaged SceneRuntime directory')
    options = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    executable = root / '.build/dependencies/cef/SceneSwiftTests.app/Contents/MacOS/SceneSwiftTests'
    if not executable.is_file():
        parser.error('Build with scripts/build-scene-swift-test.sh first')
    run = root / '.build/verification/scene-swift' / str(uuid.uuid4())
    run.mkdir(parents=True)
    for representation in ('Loose', 'Package'):
        shutil.copytree(root / f'Tests/Fixtures/SceneAnimated{representation}', run / representation.lower())
    runtime = options.runtime_root if options.runtime_root is not None else root / 'Sources/WallpaperApp/Resources/SceneRuntime'
    if not (runtime / 'index.html').is_file():
        parser.error('Missing scene runtime index.html')
    command = ['bash', '-c', 'exec > "$1" 2>&1; shift; exec "$@"', 'scene-swift-test',
               str(run / 'test.log'), str(executable), str(runtime.resolve()),
               str(run / 'loose'), str(run / 'package'), str(run / 'context')]
    (run / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    print(f'SCENE_SWIFT artifacts={run} timeout_seconds={options.timeout}', flush=True)
    status = 1
    try:
        supervise = runpy.run_path(str(root / 'scripts/test.py'))['run_tests']
        status = supervise(command, timeout_seconds=options.timeout, label='Swift scene CEF integration')
        if status == 0:
            log = (run / 'test.log').read_text().splitlines()
            suffix = ('silentPrepare=1 animated=1 pauseRetained=1 resumeSamePage=1 '
                      'nativeGain=1 pointerPixels=1 closed=1')
            expected = [f'SCENE_SWIFT PASS representation={value} {suffix}' for value in ('loose', 'package')]
            expected.append('SCENE_SWIFT SHUTDOWN activePages=0')
            if any(record not in log for record in expected):
                status = 1
                raise ValueError('Swift integration exited without all scene acceptance records')
    finally:
        (run / 'result.json').write_text(json.dumps({'test_exit': status,
            'timeout_seconds': options.timeout, 'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
            'scope': 'actual-swift-scene-surface-cef-controls-and-release'}, indent=2) + '\n')
    print(f'SCENE_SWIFT test_exit={status} log={run / "test.log"}', flush=True)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
