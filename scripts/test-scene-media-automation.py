#!/usr/bin/env python3
"""Exercise actual Main media ownership/CEF using owned Apple Events and TLS only."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
AUTOMATION = runpy.run_path(str(ROOT / 'scripts/run-media-automation.py'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--authorize-owned-fixture', action='store_true')
    options = parser.parse_args()
    run = ROOT / '.build/verification/scene-media-automation' / str(uuid.uuid4())
    run.mkdir(parents=True)
    fixture = ROOT / '.build/verification/public-media/MediaAutomationFixture.app/Contents/MacOS/MediaAutomationFixture'
    application = ROOT / '.build/dependencies/cef/SceneSwiftTests.app'
    if not fixture.is_file() or not (application / 'Contents/MacOS/SceneSwiftTests').is_file():
        parser.error('Build public-media fixture and scene-swift test apps first')
    results = {}
    overall = 'failed'
    (run / 'inputs.json').write_text(json.dumps({
        'executable_sha256': hashlib.sha256((application / 'Contents/MacOS/SceneSwiftTests').read_bytes()).hexdigest(),
        'fixture_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
        'phase_timeout_seconds': 60,
        'scope': 'owned fixtures only; actual Main scene owner, Apple Events, TLS and CEF',
    }, indent=2) + '\n')
    print(f'SCENE_MEDIA_AUTOMATION artifacts={run}', flush=True)
    try:
        with AUTOMATION['owned_tls'](run) as tls:
            for source in ('music', 'spotify'):
                directory = run / source
                directory.mkdir()
                for name, value in [('mode', 'normal'), ('receipts.json', '[]'), ('artwork-url', tls['url'] + '/image')]:
                    (directory / name).write_text(value)
                shutil.copy2(ROOT / 'Tests/MediaAutomationHarness/Fixtures/owned-artwork.png', directory / 'owned-artwork.png')
                (directory / 'server.json').write_text(json.dumps(tls))
                for form in ('Loose', 'Package'):
                    shutil.copytree(ROOT / f'Tests/Fixtures/SceneAnimated{form}', directory / form.lower())
                subprocess.run(['node', str(ROOT / 'scripts/make-native-system-media-fixtures.mjs'), str(directory / 'media'), source], check=True)
                with (directory / 'fixture.log').open('wb') as output:
                    process = subprocess.Popen([str(fixture), str(directory), source], stdout=output, stderr=subprocess.STDOUT)
                    try:
                        deadline = time.monotonic() + 10
                        while not (directory / 'ready').exists():
                            if process.poll() is not None:
                                raise RuntimeError(f'Owned fixture exited {process.returncode}')
                            if time.monotonic() >= deadline:
                                raise TimeoutError('Owned media fixture readiness exceeded 10 seconds')
                            time.sleep(0.02)
                        pid = int((directory / 'ready').read_text())
                        if pid != process.pid:
                            raise RuntimeError('Owned fixture PID mismatch')
                        (directory / 'scene-fixture.json').write_text(json.dumps({
                            'source': source, 'pid': pid, 'authorize': options.authorize_owned_fixture,
                        }))
                        arguments = [str(ROOT / 'Sources/WallpaperApp/Resources/SceneRuntime'),
                                     str(directory / 'loose'), str(directory / 'package'), str(directory / 'context'),
                                     '--system-media', str(directory)]
                        results[source] = 'running'
                        AUTOMATION['run_client'](application, arguments, directory, 'scene', timeout_seconds=60)
                        log = (directory / 'scene-client.log').read_text()
                        for form in ('loose', 'package'):
                            expected = (f'SCENE_MEDIA_SWIFT PASS source={source} representation={form} '
                                'actualAppleEvents=1 actualArtwork=1 metadataPixels=1 fiveSceneControls=1 defaultOff=1 '
                                'preparingPrivate=1 sharedPlaying=1 pausedClears=1 artworkFailureIndependent=1 '
                                'transportFailureVisible=1 explicitRetry=1 disabledClears=1 closed=1')
                            if expected not in log:
                                raise ValueError(f'Missing actual {source}/{form} acceptance record')
                        if 'SCENE_SWIFT SHUTDOWN activePages=0' not in log or 'DWWEB after-runtime-shutdown' not in log:
                            raise ValueError('Actual CEF shutdown was not observed')
                        results[source] = 'passed'
                    except Exception:
                        results[source] = 'failed'
                        raise
                    finally:
                        if process.poll() is None:
                            process.terminate()
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            process.kill(); process.wait(timeout=2)
                            results[source] = 'failed'
                            raise RuntimeError('Owned media fixture failed SIGTERM cleanup')
        overall = 'passed'
    finally:
        (run / 'result.json').write_text(json.dumps({'status': overall, 'adapters': results}, indent=2) + '\n')
    print('SCENE_MEDIA_AUTOMATION both owned dictionary adapters passed real Main/CEF integration', flush=True)


if __name__ == '__main__':
    main()
