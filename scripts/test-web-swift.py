#!/usr/bin/env python3
"""Run Swift/CEF lifecycle tests; opt into SCStream with --mirror-experiments.

Build first with scripts/build-web-swift-test.sh. Start this only after the user
is ready for macOS/Keychain interaction; the budget applies to execution alone.
The optional mirror experiments also enter native fullscreen and capture pixels,
requiring screen-capture permission and macOS 14.4+.
"""
import argparse
import hashlib
import json
import pathlib
import runpy
import shutil
import uuid


LIFECYCLE_RECORD = ('WEB_SWIFT PASS frame=1 fit=1 pauseClosed=1 retainedFrame=1 '
                    'resumeReloaded=1 shutdown=1 audio=muted-only')
MIRROR_RECORD = ('WEB_SWIFT_MIRROR PASS fullscreen=1 displayedChanges=1 sustained=1 '
                'uniquePage=1 audio=screen-only cleanup=1')


def positive_seconds(value):
    seconds = int(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError('timeout must be a positive number of seconds')
    return seconds


def make_command(executable, run, mirror_experiments):
    if mirror_experiments:
        return ['bash', '-c', 'exec "$1" "$2" "$3" "$4" > "$5" 2>&1', 'web-swift-tests',
                str(executable), str(run / 'project'), '--mirror-experiments',
                str(run / 'mirror-project'), str(run / 'test.log')]
    return ['bash', '-c', 'exec "$1" "$2" > "$3" 2>&1', 'web-swift-tests',
            str(executable), str(run / 'project'), str(run / 'test.log')]


def validate_success_records(log, mode):
    records = log.splitlines()
    expected = [f'WEB_SWIFT MODE {mode}', LIFECYCLE_RECORD]
    if mode == 'mirror-experiments':
        expected.append(MIRROR_RECORD)
    elif MIRROR_RECORD in records:
        raise ValueError('Lifecycle-only run unexpectedly executed the SCStream mirror experiment')
    if any(record not in records for record in expected):
        raise ValueError(f'Integration app exited without complete {mode} success records')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=positive_seconds, default=60,
                        help='execution budget in seconds, excluding build (default: 60)')
    parser.add_argument('--mirror-experiments', action='store_true',
                        help='also run the explicit SCStream fullscreen experiment; failures remain fatal')
    options = parser.parse_args()
    mode = 'mirror-experiments' if options.mirror_experiments else 'lifecycle'
    root = pathlib.Path(__file__).resolve().parent.parent
    executable = root / '.build/dependencies/cef/WebSwiftTests.app/Contents/MacOS/WebSwiftTests'
    if not executable.is_file():
        parser.error('Build the integration app with scripts/build-web-swift-test.sh first')
    run = root / '.build/verification/web-swift' / str(uuid.uuid4())
    run.mkdir(parents=True)
    shutil.copytree(root / 'Tests/WebRuntimeHarness/fixture', run / 'project')
    if options.mirror_experiments:
        shutil.copytree(root / 'Tests/WebRuntimeHarness/mirror-fixture', run / 'mirror-project')
    command = make_command(executable, run, options.mirror_experiments)
    (run / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    print(f'WEB_SWIFT mode={mode} artifacts={run} timeout_seconds={options.timeout}', flush=True)
    status = 1
    try:
        supervisor = runpy.run_path(str(root / 'scripts/test.py'))['run_tests']
        child_status = supervisor(command, timeout_seconds=options.timeout, label='Swift CEF integration tests')
        if child_status == 0:
            validate_success_records((run / 'test.log').read_text(), mode)
        status = child_status
    finally:
        (run / 'result.json').write_text(json.dumps({
            'test_exit': status, 'timeout_seconds': options.timeout, 'mode': mode,
            'executable_sha256': digest, 'scope': 'swift-cef-muted-frame-pause-reload-shutdown'
            + ('-fullscreen-mirror' if options.mirror_experiments else ''),
        }, indent=2) + '\n')
    print(f'WEB_SWIFT test_exit={status}; see {run / "test.log"}', flush=True)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
