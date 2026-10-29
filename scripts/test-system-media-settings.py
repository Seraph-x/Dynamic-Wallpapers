#!/usr/bin/env python3
"""Verify actual Main settings/consent against owned native player and TLS fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / 'scripts/run-media-automation.py'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--authorize-owned-fixture', action='store_true')
    options = parser.parse_args()
    if not options.authorize_owned_fixture:
        parser.error('This actual consent-button test requires explicit --authorize-owned-fixture')
    app = ROOT / '.build/verification/media-settings-host/SystemMediaSettingsTests.app'
    executable = app / 'Contents/MacOS/SystemMediaSettingsTests'
    fixture = ROOT / '.build/verification/public-media/MediaAutomationFixture.app/Contents/MacOS/MediaAutomationFixture'
    if not executable.is_file() or not fixture.is_file():
        parser.error('Build the settings host and owned public-media fixture first')
    run = ROOT / '.build/verification/media-settings-automation' / str(uuid.uuid4())
    run.mkdir(parents=True)
    print(f'MEDIA_SETTINGS artifacts={run}', flush=True)
    (run / 'inputs.json').write_text(json.dumps({
        'application_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'fixture_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
        'scope': 'production Main view and models; owned Automation/TLS only; backend demand is a fixture signal',
        'phase_timeout_seconds': 60,
    }, indent=2) + '\n')
    results, status = {}, 'failed'
    try:
        with HELPERS['owned_tls'](run) as tls:
            for source in ('music', 'spotify'):
                directory = run / source
                with HELPERS['owned_player'](fixture, directory, source=source, tls=tls) as pid:
                    (directory / 'scene-fixture.json').write_text(json.dumps({'source': source, 'pid': pid, 'authorize': True}))
                    results[source] = 'running'
                    try:
                        HELPERS['run_client'](app, [str(directory)], directory, 'settings', timeout_seconds=60)
                        expected = (f'MEDIA_SETTINGS PASS source={source} actualProductionView=1 threeChoices=1 '
                            'selectionNoRead=1 explicitConsent=1 actualAppleEvents=1 actualArtworkPixels=1 '
                            'artworkRetryIndependent=1 providerFailureVisible=1 persistedOff=1 resourcesReleased=1')
                        if expected not in (directory / 'settings-client.log').read_text():
                            raise ValueError('Owned settings host exited without its complete actual UI/native acceptance record')
                        results[source] = 'passed'
                    except Exception:
                        results[source] = 'failed'
                        raise
        status = 'passed'
    finally:
        (run / 'result.json').write_text(json.dumps({'status': status, 'adapters': results}, indent=2) + '\n')
    print('MEDIA_SETTINGS actual Main controls and owned native consent/artwork passed for both adapters', flush=True)


if __name__ == '__main__':
    main()
