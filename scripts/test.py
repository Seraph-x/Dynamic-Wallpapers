#!/usr/bin/env python3
"""Run Swift tests with explicit suite budgets and bounded process-group cleanup."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from media_dependencies import verify_build_dependencies

TEST_TIMEOUT_SECONDS = 60
FULL_SWIFT_TIMEOUT_SECONDS = 600
MIRROR_EXPERIMENT_FILTER = r"^WallpaperAppTests\.WallpaperMirror(Capture|RawDiagnostic)Tests/"
TERM_GRACE_SECONDS = 2
KILL_GRACE_SECONDS = 2
GROUP_POLL_SECONDS = 0.05


def signal_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
        return True
    except ProcessLookupError:
        return False


def wait_for_group_exit(process, timeout_seconds, *, interrupted=lambda: False):
    deadline = time.monotonic() + timeout_seconds
    while True:
        # An unreaped leader already proves completion is pending. On Darwin,
        # probing its group during exit can report EPERM for a same-UID zombie.
        # Reap the leader first; then independently verify all remaining descendants.
        group_exists = True
        if process.poll() is not None:
            try:
                group_exists = signal_group(process.pid, 0)
            except PermissionError:
                print(f"ERROR: Process-group probe denied: unix_time={time.time():.6f} "
                      f"observer_pid={os.getpid()} uid={os.getuid()} euid={os.geteuid()} "
                      f"pgid={process.pid} signal=0 leader_returncode={process.returncode}; "
                      "group release is unverified (not a Keychain authorization result).",
                      file=sys.stderr, flush=True)
                raise
        if not group_exists:
            return True
        if interrupted():
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(GROUP_POLL_SECONDS, remaining))


def cleanup_group(process, reason):
    print(reason, file=sys.stderr, flush=True)
    # start_new_session makes the child's PID our PGID. Only this group is
    # owned here; descendants that move to other groups are not tracked.
    if signal_group(process.pid, signal.SIGTERM):
        print(f"Sent SIGTERM to process group {process.pid}; "
              f"cleanup grace is {TERM_GRACE_SECONDS} seconds.",
              file=sys.stderr, flush=True)
    if not wait_for_group_exit(process, TERM_GRACE_SECONDS):
        print(f"ERROR: Process group {process.pid} survived SIGTERM; sending SIGKILL.",
              file=sys.stderr, flush=True)
        signal_group(process.pid, signal.SIGKILL)
        if not wait_for_group_exit(process, KILL_GRACE_SECONDS):
            print(f"ERROR: Process group {process.pid} still exists after "
                  f"the {KILL_GRACE_SECONDS}-second SIGKILL cleanup deadline.",
                  file=sys.stderr, flush=True)
    try:
        process.wait(timeout=0)
    except subprocess.TimeoutExpired:
        print(f"ERROR: Direct child {process.pid} could not be reaped within cleanup deadlines.",
              file=sys.stderr, flush=True)


def run_tests(command, *, timeout_seconds=TEST_TIMEOUT_SECONDS, label="Swift tests"):
    """Use explicit budgets for full suites and short real-process negative controls."""
    status = None
    received_signals = []

    def record_signal(number, _frame):
        nonlocal status
        # Do not raise out of Popen or cleanup: ownership and the first outcome
        # must survive any subsequent interrupt, including mixed INT/TERM.
        received_signals.append(number)
        if status is None:
            status = 128 + number

    previous_handlers = {number: signal.signal(number, record_signal)
                         for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        process = subprocess.Popen(command, start_new_session=True)
        exited = wait_for_group_exit(process, timeout_seconds,
                                     interrupted=lambda: status is not None)
        if exited and status is None:
            return process.returncode
        if status is None:
            status = 124
        if status == 124:
            reason = f"ERROR: {label} exceeded the {timeout_seconds}-second timeout."
        else:
            name = signal.Signals(status - 128).name
            reason = f"ERROR: {label} interrupted by {name}; cleaning up their process group."
        try:
            cleanup_group(process, reason)
        except OSError as error:
            print(f"ERROR: Process-group cleanup failed: {error}", file=sys.stderr, flush=True)
        for number in received_signals:
            print(f"Received {signal.Signals(number).name}; bounded cleanup retained status {status}.",
                  file=sys.stderr, flush=True)
        return status
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


def main(arguments):
    experiments = "--mirror-experiments" in arguments
    swift_arguments = [value for value in arguments if value != "--mirror-experiments"]
    filtered = any(value == "--filter" or value.startswith("--filter=") for value in swift_arguments)
    specified = any(value in {"--specifier", "-s"} or value.startswith(("--specifier=", "-s="))
                    for value in swift_arguments)
    if experiments and (filtered or specified):
        print("ERROR: --mirror-experiments already selects the experimental suite. "
              "Use --filter on its own for a narrower explicit selection.", file=sys.stderr)
        return 2
    if experiments:
        selection = ["--filter", MIRROR_EXPERIMENT_FILTER]
        print("Swift test selection: SCStream experiments (not product acceptance).", flush=True)
    elif filtered or specified:
        selection = []
        selector = "--filter" if filtered else "--specifier/-s"
        print(f"Swift test selection: explicit {selector}, forwarded unchanged.", flush=True)
    else:
        selection = ["--skip", MIRROR_EXPERIMENT_FILTER]
        print("Swift test selection: product; SCStream experiments excluded. "
              "Run --mirror-experiments to select them explicitly.", flush=True)
    budget = TEST_TIMEOUT_SECONDS if filtered or specified or experiments else FULL_SWIFT_TIMEOUT_SECONDS
    print(f"Swift test budget: {budget} seconds (includes build).", flush=True)
    if not experiments and not filtered and not specified:
        verify_build_dependencies()
    return run_tests([sys.executable, str(Path(__file__).with_name("swift_sdk.py")),
                      "test", "--disable-sandbox", *selection, *swift_arguments], timeout_seconds=budget)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
