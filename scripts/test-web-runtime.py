#!/usr/bin/env python3
"""Build and exercise the real product CEF frame/lifecycle bridge, never the installed app."""
import json
import argparse
import pathlib
import runpy
import shutil
import uuid

def positive_seconds(value):
    seconds = int(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError('timeout must be a positive number of seconds')
    return seconds

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--timeout', type=positive_seconds, default=60,
                    help='explicit total build/run budget in seconds (default: 60)')
options = parser.parse_args()

ROOT = pathlib.Path(__file__).resolve().parent.parent
run = ROOT / '.build/verification/web-runtime' / str(uuid.uuid4())
run.mkdir(parents=True)
shutil.copytree(ROOT / 'Tests/WebRuntimeHarness/fixture', run / 'project')
command = ['bash', str(ROOT / 'scripts/build-web-runtime-test.sh'), str(run)]
(run / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
print(f'WEB_RUNTIME artifacts={run} timeout_seconds={options.timeout}', flush=True)
status = 1
try:
    supervisor = runpy.run_path(str(ROOT / 'scripts/test.py'))['run_tests']
    status = supervisor(command, timeout_seconds=options.timeout, label='CEF product runtime tests')
finally:
    (run / 'result.json').write_text(json.dumps({'test_exit': status, 'timeout_seconds': options.timeout,
        'scope': 'product-bridge-frame-and-lifecycle'}) + '\n')
print(f'WEB_RUNTIME test_exit={status}; see {run / "test.log"}', flush=True)
raise SystemExit(status)
