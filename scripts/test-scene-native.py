#!/usr/bin/env python3
"""Exercise real CEF scene pixels, controls and resource release in an isolated app."""
import argparse
import json
import pathlib
import os
import runpy
import subprocess
import uuid


def positive_seconds(value):
    seconds = int(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError('timeout must be positive')
    return seconds


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-timeout', type=positive_seconds, default=180)
parser.add_argument('--timeout', type=positive_seconds, default=60)
options = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
run = root / '.build/verification/scene-native' / str(uuid.uuid4())
run.mkdir(parents=True)
(run / 'test-settings.json').write_text(json.dumps({
    'keychain_mode': os.environ.get('SCENE_NATIVE_TEST_KEYCHAIN', 'system'),
    'credential_fixture_scope': 'native test host only; does not validate system Keychain access',
}, indent=2) + '\n')
subprocess.run(['node', str(root / 'scripts/make-system-media-fixtures.mjs'), str(run / 'media')], check=True)
app = run / 'SceneNativeTests.app'
frameworks = app / 'Contents/Frameworks'
# The product configuration owns the helper name; do not duplicate its executable.
product = json.loads(subprocess.check_output(
    ['python3', str(root / 'scripts/product_configuration.py'), '--emit', 'shell-json'], text=True))
helper_name = product['application']['executable'] + ' Helper'
commands = {
    'build': ['bash', str(root / 'scripts/build-scene-native-test.sh'), str(run)],
    'protocol': [str(run / 'protocol-tests')],
    'runtime': [str(app / 'Contents/MacOS/SceneNativeTests'),
                str(frameworks / 'Chromium Embedded Framework.framework'),
                str(frameworks / f'{helper_name}.app/Contents/MacOS' / helper_name),
                str(run / 'context'), str(root / 'Sources/WallpaperApp/Resources/SceneRuntime'),
                str(root / 'Tests/Fixtures/SceneAnimatedLoose'),
                str(root / 'Tests/Fixtures/SceneAnimatedPackage'), str(run / 'media')],
}
(run / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
supervise = runpy.run_path(str(root / 'scripts/test.py'))['run_tests']
print(f'SCENE_NATIVE artifacts={run}', flush=True)
results = {}
try:
    for stage, command in commands.items():
        logged = ['bash', '-c', 'exec > "$1" 2>&1; shift; exec "$@"',
                  'scene-native-test', str(run / f'{stage}.log'), *command]
        budget = options.build_timeout if stage == 'build' else options.timeout
        results[stage] = supervise(logged, timeout_seconds=budget, label=f'Scene native {stage}')
        if stage == 'runtime' and results[stage] == 0:
            log = (run / 'runtime.log').read_text()
            required = ['DWWEB after-runtime-shutdown'] + [
                f'SCENE_NATIVE_MEDIA PASS representation={form} actualPixels=1 neutralColors=1 fiveNativeControls=1 invalidRejected=1 emptyTexturesClear=1 decoderErrorVisible=1 samePNGNewIdentity=1 explicitRetry=1 closeCancels=1 resourcesReleased=1'
                for form in ('loose', 'package')]
            required.extend(f'SCENE_NATIVE_MEDIA_BOUNDARY PASS mode={mode} actualEngine=1 blocked=1 callbacks=0 released=1'
                            for mode in ('stale', 'frame'))
            if os.environ.get('SCENE_NATIVE_TEST_KEYCHAIN', 'system') == 'isolated':
                required.append('DWWEB native-test keychain=isolated')
            if any(value not in log for value in required):
                results[stage] = 1
                raise ValueError('Native media run exited without its actual acceptance/shutdown receipts')
        print(f'SCENE_NATIVE {stage}_exit={results[stage]} log={run / (stage + ".log")}', flush=True)
        if results[stage] != 0:
            break
finally:
    (run / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(next((status for status in results.values() if status != 0), 0))
