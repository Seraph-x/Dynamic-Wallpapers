#!/usr/bin/env python3
"""Exercise the test supervisor with real Python children, never Swift tests.

The 0.5-second budget belongs only to these negative controls. The Swift CLI
uses 600 seconds for a full suite and 60 for filtered tests. Set
RUNNER_TEST_EVIDENCE_DIR to retain fixture logs.
"""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

RUNNER = Path(__file__).with_name("test.py")
FIXTURE_BUDGET = 0.5
WATCHDOG_SECONDS = 6


def record_process(directory, role):
    record = {"pid": os.getpid(), "pgid": os.getpgrp(), "sid": os.getsid(0)}
    temporary = directory / f"{role}.tmp"
    temporary.write_text(json.dumps(record))
    temporary.replace(directory / f"{role}.json")


def wait_until(predicate, timeout):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)
    return True


def fixture(mode, directory):
    role = "descendant" if mode == "descendant" else "leader"
    if mode in {"ignore_term", "descendant"}:
        def observe_term(_number, _frame):
            (directory / f"{role}.term").write_text("SIGTERM received; still running\n")
        signal.signal(signal.SIGTERM, observe_term)
    if mode in {"descendant_survives", "exit_with_descendant"}:
        subprocess.Popen([sys.executable, __file__, "--fixture", "descendant", str(directory)])
        if not wait_until(lambda: (directory / "descendant.json").exists(), 2):
            raise RuntimeError("Descendant failed to report its identity")
    record_process(directory, role)
    if mode == "exit_with_descendant":
        return 0
    if mode.startswith("exit_"):
        return int(mode.removeprefix("exit_"))
    while True:
        signal.pause()


def worker(mode, directory):
    spec = importlib.util.spec_from_file_location("swift_test_supervisor", RUNNER)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    command = [sys.executable, __file__, "--fixture", mode, str(directory)]
    return runner.run_tests(command, timeout_seconds=FIXTURE_BUDGET)


class TestSwiftCommand(unittest.TestCase):
    def test_reaps_real_child_before_probing_its_zombie_group(self):
        spec = importlib.util.spec_from_file_location("swift_test_exit_race", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read(1)"],
                              stdin=subprocess.PIPE, start_new_session=True) as child:
            original_poll = child.poll
            boundary_observed = []

            def exit_after_poll_snapshot():
                result = original_poll()
                if not boundary_observed and result is None:
                    child.stdin.write(b"x")
                    child.stdin.flush()

                    def is_zombie():
                        state = subprocess.check_output(["ps", "-p", str(child.pid), "-o", "state="], text=True)
                        return state.strip().startswith("Z")

                    self.assertTrue(wait_until(is_zombie, 2), "Child never reached the controlled exit boundary")
                    if sys.platform == "darwin":
                        with self.assertRaises(PermissionError):
                            os.killpg(child.pid, 0)
                    boundary_observed.append(child.pid)
                return result

            with patch.object(child, "poll", side_effect=exit_after_poll_snapshot):
                self.assertTrue(runner.wait_for_group_exit(child, 2))
            self.assertEqual(child.returncode, 0)
            self.assertEqual(boundary_observed, [child.pid])
            with self.assertRaises(ProcessLookupError):
                os.killpg(child.pid, 0)

    def test_permission_denial_keeps_error_and_reports_reaped_leader(self):
        spec = importlib.util.spec_from_file_location("swift_test_diagnostic", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        class FinishedChild:
            pid = 12345
            returncode = 0
            def poll(self):
                return self.returncode
        output = io.StringIO()
        with patch.object(runner, "signal_group", side_effect=PermissionError(1, "Operation not permitted")):
            with contextlib.redirect_stderr(output), self.assertRaises(PermissionError):
                runner.wait_for_group_exit(FinishedChild(), 60)
        diagnostic = output.getvalue()
        self.assertIn("pgid=12345", diagnostic)
        self.assertIn("leader_returncode=0", diagnostic)
        self.assertIn("signal=0", diagnostic)
        self.assertIn("unix_time=", diagnostic)

    def test_full_and_filtered_budgets_preserve_arguments_and_status(self):
        spec = importlib.util.spec_from_file_location("swift_test_command", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        for arguments, budget in [([], 600), (["--filter", "AudioPlaybackTests"], 60),
                                  (["--filter=AudioPlaybackTests", "--skip-build"], 60)]:
            with self.subTest(arguments=arguments), patch.object(runner, "run_tests", return_value=7) as run:
                self.assertEqual(runner.main(arguments), 7)
                selection = [] if arguments else [
                    "--skip", r"^WallpaperAppTests\.WallpaperMirror(Capture|RawDiagnostic)Tests/"]
                run.assert_called_once_with([sys.executable, str(RUNNER.with_name("swift_sdk.py")), "test", "--disable-sandbox", *selection, *arguments],
                                            timeout_seconds=budget)


class TestSupervisor(unittest.TestCase):
    def setUp(self):
        evidence = os.environ.get("RUNNER_TEST_EVIDENCE_DIR")
        if evidence:
            Path(evidence).mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory() if not evidence else None
        self.directory = Path(self.temporary.name) if self.temporary else Path(
            tempfile.mkdtemp(prefix=f"{self._testMethodName}-", dir=evidence)
        )
        self.output = self.directory / "supervisor.log"
        self.process = None
        self.addCleanup(self.cleanup)

    def start(self, mode):
        with self.output.open("w") as output:
            self.process = subprocess.Popen(
                [sys.executable, "-u", __file__, "--worker", mode, str(self.directory)],
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
            )
        self.started = time.monotonic()
        self.assertTrue(wait_until(lambda: (self.directory / "leader.json").exists(), 2),
                        f"Fixture did not start: {self.output.read_text()}")

    def records(self):
        return [json.loads(path.read_text()) for path in self.directory.glob("*.json")]

    def alive(self, record):
        try:
            return os.getpgid(record["pid"]) == record["pgid"]
        except ProcessLookupError:
            return False

    def signal_owned(self, record, signum):
        try:
            if os.getpgid(record["pid"]) != record["pgid"] or os.getsid(record["pid"]) != record["sid"]:
                raise RuntimeError(f"Refusing to signal a changed process identity: {record}")
            command = subprocess.check_output(
                ["ps", "-p", str(record["pid"]), "-o", "command="], text=True,
            )
            if str(self.directory) not in command:
                raise RuntimeError(f"Refusing to signal a PID without the fixture token: {record}")
            os.kill(record["pid"], signum)
        except ProcessLookupError:
            pass

    def cleanup(self):
        if self.process and self.process.poll() is None:
            self.signal_owned({"pid": self.process.pid, "pgid": self.process.pid,
                               "sid": self.process.pid}, signal.SIGKILL)
            self.process.wait(timeout=2)
        records = self.records()
        for record in records:
            if self.alive(record):
                self.signal_owned(record, signal.SIGKILL)
        if not wait_until(lambda: not any(self.alive(record) for record in records), 2):
            raise RuntimeError(f"Fixture cleanup did not finish: {records}")
        if self.temporary:
            self.temporary.cleanup()

    def finish(self, expected):
        completed = wait_until(lambda: self.process.poll() is not None, WATCHDOG_SECONDS)
        elapsed = time.monotonic() - self.started
        records = self.records()
        print(f"\n{self._testMethodName}: exit={self.process.returncode}, "
              f"elapsed={elapsed:.3f}s, processes={records}", flush=True)
        self.assertTrue(completed, f"Supervisor remained blocked after {elapsed:.3f}s; "
                        f"log={self.output.read_text()!r}")
        self.assertEqual(self.process.returncode, expected, self.output.read_text())
        self.assertTrue(wait_until(lambda: not any(self.alive(record) for record in records), 1),
                        f"Owned fixture survived supervisor exit: {records}")
        return self.output.read_text()

    def test_timeout_kills_a_leader_that_ignores_term(self):
        self.start("ignore_term")
        self.assertTrue(wait_until(lambda: (self.directory / "leader.term").exists(), 2))
        log_before_cleanup = self.output.read_text()
        output = self.finish(124)
        self.assertIn("timeout", log_before_cleanup.lower())
        self.assertIn("SIGKILL", output)

    def test_timeout_kills_a_same_group_descendant_after_leader_exit(self):
        self.start("descendant_survives")
        output = self.finish(124)
        self.assertTrue((self.directory / "descendant.term").exists())
        self.assertIn("SIGKILL", output)

    def test_keyboard_interrupt_cleans_the_owned_group(self):
        self.start("ignore_term")
        self.signal_owned({"pid": self.process.pid, "pgid": self.process.pid,
                           "sid": self.process.pid}, signal.SIGINT)
        output = self.finish(130)
        self.assertIn("interrupt", output.lower())
        self.assertIn("SIGKILL", output)

    def test_repeated_interrupt_does_not_abandon_cleanup(self):
        self.start("ignore_term")
        worker_record = {"pid": self.process.pid, "pgid": self.process.pid,
                         "sid": self.process.pid}
        self.signal_owned(worker_record, signal.SIGINT)
        self.assertTrue(wait_until(lambda: (self.directory / "leader.term").exists(), 1),
                        "Interrupted supervisor did not send SIGTERM")
        self.signal_owned(worker_record, signal.SIGINT)
        output = self.finish(130)
        self.assertIn("cleanup", output.lower())

    def assert_mixed_signal_cleanup(self, first, second):
        self.start("ignore_term")
        worker_record = {"pid": self.process.pid, "pgid": self.process.pid,
                         "sid": self.process.pid}
        self.signal_owned(worker_record, first)
        self.assertTrue(wait_until(lambda: (self.directory / "leader.term").exists(), 1),
                        "Interrupted supervisor did not send SIGTERM")
        self.signal_owned(worker_record, second)
        output = self.finish(128 + first)
        self.assertIn(f"Received {second.name}", output)

    def test_sigterm_during_interrupt_cleanup_preserves_interrupt(self):
        self.assert_mixed_signal_cleanup(signal.SIGINT, signal.SIGTERM)

    def test_sigint_during_termination_cleanup_preserves_termination(self):
        self.assert_mixed_signal_cleanup(signal.SIGTERM, signal.SIGINT)

    def test_interrupt_during_timeout_cleanup_preserves_timeout(self):
        self.start("ignore_term")
        self.assertTrue(wait_until(lambda: (self.directory / "leader.term").exists(), 2))
        self.signal_owned({"pid": self.process.pid, "pgid": self.process.pid,
                           "sid": self.process.pid}, signal.SIGINT)
        self.finish(124)

    def test_ordinary_success_is_preserved(self):
        self.start("exit_0")
        output = self.finish(0)
        self.assertNotIn("ERROR", output)

    def test_ordinary_failure_is_preserved(self):
        self.start("exit_7")
        self.finish(7)

    def test_cooperative_timeout_still_fails(self):
        self.start("cooperative")
        output = self.finish(124)
        self.assertIn("timeout", output.lower())
        self.assertNotIn("SIGKILL", output)

    def test_successful_leader_cannot_leave_a_live_owned_group(self):
        self.start("exit_with_descendant")
        output = self.finish(124)
        self.assertIn("timeout", output.lower())
        self.assertIn("SIGKILL", output)

    def test_sigterm_cleans_the_owned_group(self):
        self.start("ignore_term")
        self.signal_owned({"pid": self.process.pid, "pgid": self.process.pid,
                           "sid": self.process.pid}, signal.SIGTERM)
        output = self.finish(143)
        self.assertIn("SIGTERM", output)
        self.assertIn("SIGKILL", output)

    def test_sigterm_during_timeout_cleanup_preserves_timeout(self):
        self.start("ignore_term")
        self.assertTrue(wait_until(lambda: (self.directory / "leader.term").exists(), 2))
        self.signal_owned({"pid": self.process.pid, "pgid": self.process.pid,
                           "sid": self.process.pid}, signal.SIGTERM)
        self.finish(124)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        sys.exit(worker(sys.argv[2], Path(sys.argv[3])))
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture":
        sys.exit(fixture(sys.argv[2], Path(sys.argv[3])))
    unittest.main()
