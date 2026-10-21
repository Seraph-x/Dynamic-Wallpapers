#!/usr/bin/env python3
"""Negative-control unit test of runner bookkeeping. Does NOT execute CEF or count as a browser test."""
import io
import json
import pathlib
import runpy
import subprocess
import sys
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent


class MalformedChildOutput:
    """Only the child boundary is injected; the real runner writes the real result artifact."""
    returncode = 0

    def __init__(self, _command, *, stdout, **_kwargs):
        stdout.write("SOURCE_RESULT null\n")

    def wait(self, timeout):
        return self.returncode


class SourceRunnerTests(unittest.TestCase):
    def testOptimizedInterpreterStillRejectsMalformedSuccessfulOutput(self):
        result = subprocess.run(
            [sys.executable, "-O", __file__,
             "SourceRunnerTests.testMalformedSuccessfulChildOutputCannotRecordSuccessfulTestExit"],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def testMalformedSuccessfulChildOutputCannotRecordSuccessfulTestExit(self):
        output_root = ROOT / ".build/verification/cef-source"
        before = set(output_root.iterdir()) if output_root.exists() else set()
        caught = None
        with patch.object(subprocess, "run"), patch.object(subprocess, "Popen", MalformedChildOutput):
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                try:
                    runpy.run_path(str(ROOT / "scripts/test-cef-source.py"), run_name="__main__")
                except (SystemExit, TypeError) as error:
                    caught = error
        created = set(output_root.iterdir()) - before
        self.assertEqual(len(created), 1)
        result_root = created.pop()
        (result_root / "RUNNER-NEGATIVE-CONTROL.txt").write_text("Injected malformed child log; NOT a CEF execution.\n")
        result = json.loads((result_root / "result.json").read_text())
        self.assertIsNotNone(caught)
        self.assertNotEqual(result["test_exit"], 0, f"Malformed child log falsely marked passed: {result_root}")


if __name__ == "__main__":
    unittest.main()
