#!/usr/bin/env python3
"""Owned native fixture execution; called only by test-public-media --automation."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import shutil
import sys
import subprocess
import time


def run_client(application, arguments, directory, label):
    result = directory / f'{label}-result.json'
    output = directory / f'{label}-client.log'
    output.touch()
    # LaunchServices gives the signed test app its own TCC identity. Direct
    # subprocess execution instead inherits the calling development host's
    # responsibility chain. open's status alone does not prove client success;
    # -W also races with very short-lived clients before installing its kevent.
    command = ['open', '-n', '-g', '--stdout', str(output), '--stderr', str(output),
               '-a', str(application), '--args', *arguments, '--result-file', str(result)]
    launcher = subprocess.Popen(command)
    try:
        launcher.wait(timeout=5)
        if launcher.returncode != 0:
            raise RuntimeError(f'LaunchServices could not launch the owned client: {launcher.returncode}')
        deadline = time.monotonic() + 20
        value = None
        while time.monotonic() < deadline:
            if result.exists():
                value = json.loads(result.read_text())
                if value.get('status') != 'running' and not pid_exists(value['pid']):
                    break
            time.sleep(0.02)
        else:
            raise TimeoutError(f'Owned client result/process exit exceeded 20 seconds; see {output}')
        if value.get('status') != 'passed':
            raise RuntimeError(f'Owned client failed: {value}; see {output}')
        print(output.read_text(), end='', flush=True)
    finally:
        if result.exists():
            value = json.loads(result.read_text())
            if pid_exists(value['pid']):
                os.kill(value['pid'], signal.SIGTERM)
                deadline = time.monotonic() + 2
                while pid_exists(value['pid']) and time.monotonic() < deadline:
                    time.sleep(0.02)
                if pid_exists(value['pid']):
                    os.kill(value['pid'], signal.SIGKILL)
                    raise RuntimeError('Owned client did not exit during SIGTERM cleanup')
        if launcher.poll() is None:
            launcher.terminate()
            launcher.wait(timeout=2)


def pid_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


@contextmanager
def owned_tls(artifacts):
    directory = artifacts / f'tls-automation-{time.time_ns()}'
    directory.mkdir()
    helper = Path(__file__).resolve().parent.parent / 'Tests/MediaAutomationHarness/https-artwork-server.py'
    with (directory / 'server.log').open('wb') as output:
        process = subprocess.Popen([sys.executable, str(helper), str(directory)], stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 5
            while not (directory / 'server.json').exists():
                if process.poll() is not None:
                    raise RuntimeError(f'Owned TLS fixture exited {process.returncode}; see {directory / "server.log"}')
                if time.monotonic() >= deadline:
                    raise TimeoutError('Owned TLS readiness exceeded 5 seconds')
                time.sleep(0.02)
            yield json.loads((directory / 'server.json').read_text())
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
                raise RuntimeError('Owned TLS fixture failed to exit during SIGTERM cleanup')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('--authorize-owned-fixture', action='store_true')
    options = parser.parse_args()
    fixture = options.artifacts / 'MediaAutomationFixture.app/Contents/MacOS/MediaAutomationFixture'
    client = options.artifacts / 'MediaAutomationClient.app'
    with owned_tls(options.artifacts) as tls:
        for source in ['music', 'spotify']:
            directory = options.artifacts / f'run-{source}-{time.time_ns()}'
            directory.mkdir()
            (directory / 'mode').write_text('normal')
            fixture_png = Path(__file__).resolve().parent.parent / 'Tests/MediaAutomationHarness/Fixtures/owned-artwork.png'
            shutil.copy2(fixture_png, directory / 'owned-artwork.png')
            (directory / 'server.json').write_text(json.dumps(tls))
            (directory / 'artwork-url').write_text(tls['url'] + '/image')
            with (directory / 'fixture.log').open('wb') as log:
                process = subprocess.Popen([str(fixture), str(directory), source], stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 10
                    while not (directory / 'ready').exists():
                        if process.poll() is not None:
                            raise RuntimeError(f'Owned fixture exited {process.returncode}; see {directory / "fixture.log"}')
                        if time.monotonic() >= deadline:
                            raise TimeoutError('Owned fixture readiness exceeded 10 seconds')
                        time.sleep(0.02)
                    pid = int((directory / 'ready').read_text())
                    if pid != process.pid:
                        raise RuntimeError('Owned fixture PID does not match launched process')
                    command = [str(pid), source, str(directory)]
                    if options.authorize_owned_fixture:
                        command.append('--authorize-owned-fixture')
                    run_client(client, command, directory, 'transport')
                finally:
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)
                run_client(client, [str(pid), source, str(directory), '--expect-exited'], directory, 'exited')
    print('PUBLIC_MEDIA actual transport and artwork passed for both dictionary adapters; no vendor player/library was accessed.', flush=True)


if __name__ == '__main__':
    main()
