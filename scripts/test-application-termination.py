#!/usr/bin/env python3
"""Exercise real Quit AppleEvents against the isolated application termination harness."""
from pathlib import Path
import subprocess
import tempfile
import time


def run_case(directory, mode):
    binary = directory / 'QuitHarness.app/Contents/MacOS/QuitHarness'
    requester = directory / 'request-quit'
    with tempfile.TemporaryFile(mode='w+') as output:
        process = subprocess.Popen([str(binary), mode], stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while True:
                output.seek(0)
                log = output.read()
                if 'QUIT_HARNESS READY' in log:
                    break
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f'{mode}: harness did not become ready\n{log}')
                time.sleep(0.02)
            request = [str(requester), str(process.pid)]
            if mode == "decline":
                request.append("--expect-cancel")
            subprocess.run(request, check=True, timeout=10)
            status = process.wait(timeout=10)
            output.seek(0)
            log = output.read()
            print(log, end='', flush=True)
            if status != 0 or 'QUIT_HARNESS PASS' not in log:
                raise RuntimeError(f'{mode}: exit={status}; normal termination was not verified')
        finally:
            if process.poll() is None:
                print(f'{mode}: failed test cleanup, sending SIGTERM to harness PID {process.pid}', flush=True)
                process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    folder = Path(__file__).resolve().parents[1] / '.build/verification/application-termination'
    for scenario in ('plain', 'sheet', 'hidden', 'decline', 'modal'):
        run_case(folder, scenario)
    print('5 application termination scenarios passed')
