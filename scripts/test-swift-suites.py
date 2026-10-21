#!/usr/bin/env python3
"""Verify suite selection at the subprocess boundary; no Swift tests are launched."""
import contextlib
import importlib.util
import io
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch


RUNNER = Path(__file__).with_name("test.py")
EXPERIMENTS = r"^WallpaperAppTests\.WallpaperMirror(Capture|RawDiagnostic)Tests/"


class SwiftSuiteSelectionTests(unittest.TestCase):
    def run_case(self, arguments):
        spec = importlib.util.spec_from_file_location("swift_suite_runner", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        output = io.StringIO()
        events = []
        with patch.object(runner, "verify_build_dependencies", create=True,
                          side_effect=lambda: events.append("preflight")) as verify, \
             patch.object(runner, "run_tests", side_effect=lambda *_args, **_kwargs: events.append("run") or 7) as run:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                status = runner.main(arguments)
        return status, run, verify, events, output.getvalue()

    def test_default_product_suite_explicitly_excludes_only_stream_experiments(self):
        arguments = ["--skip-build"]
        status, run, verify, events, output = self.run_case(arguments)
        self.assertEqual(status, 7)
        run.assert_called_once_with(
            [sys.executable, str(RUNNER.with_name("swift_sdk.py")), "test", "--disable-sandbox", "--skip", EXPERIMENTS, "--skip-build"],
            timeout_seconds=600)
        self.assertIn("SCStream experiments excluded", output)
        self.assertIn("--mirror-experiments", output)
        self.assertEqual(arguments, ["--skip-build"])
        verify.assert_called_once_with()
        self.assertEqual(events, ["preflight", "run"])

    def test_explicit_experiment_suite_keeps_the_filtered_budget_and_exit_status(self):
        arguments = ["--mirror-experiments", "--skip-build"]
        status, run, verify, _, output = self.run_case(arguments)
        self.assertEqual(status, 7)
        run.assert_called_once_with(
            [sys.executable, str(RUNNER.with_name("swift_sdk.py")), "test", "--disable-sandbox", "--filter", EXPERIMENTS, "--skip-build"],
            timeout_seconds=60)
        self.assertIn("SCStream experiments", output)
        self.assertNotIn("experiments excluded", output)
        self.assertEqual(arguments, ["--mirror-experiments", "--skip-build"])
        verify.assert_not_called()

    def test_explicit_filters_are_never_silently_rewritten(self):
        for arguments in [["--filter", "WallpaperMirrorCaptureTests"],
                          ["--filter=WallpaperScreenshotProducerTests", "--skip-build"]]:
            with self.subTest(arguments=arguments):
                status, run, verify, _, output = self.run_case(arguments)
                self.assertEqual(status, 7)
                run.assert_called_once_with(
                    [sys.executable, str(RUNNER.with_name("swift_sdk.py")), "test", "--disable-sandbox", *arguments], timeout_seconds=60)
                self.assertIn("explicit --filter", output)
                verify.assert_not_called()

    def test_legacy_explicit_specifiers_keep_selection_and_use_targeted_budget(self):
        target = "WallpaperAppTests.WallpaperMirrorCaptureTests/testOwnDesktopVideoKeepsUpdatingWithoutChangingSpaces"
        for arguments in [["--specifier", target], [f"--specifier={target}"], ["-s", target], [f"-s={target}"]]:
            with self.subTest(arguments=arguments):
                status, run, verify, _, output = self.run_case(arguments)
                self.assertEqual(status, 7)
                run.assert_called_once_with(
                    [sys.executable, str(RUNNER.with_name("swift_sdk.py")), "test", "--disable-sandbox", *arguments], timeout_seconds=60)
                self.assertIn("explicit --specifier/-s", output)
                verify.assert_not_called()

    def test_experiment_mode_rejects_a_second_selection_instead_of_unioning_filters(self):
        for selection in [["--filter", "AudioPlaybackTests"], ["--filter=AudioPlaybackTests"],
                          ["--specifier", "AudioPlaybackTests/testPlayback"], ["-s=AudioPlaybackTests/testPlayback"]]:
            with self.subTest(selection=selection):
                status, run, verify, _, output = self.run_case(["--mirror-experiments", *selection])
                self.assertEqual(status, 2)
                run.assert_not_called()
                verify.assert_not_called()
                self.assertIn("Use --filter on its own", output)

    def test_shared_mirror_and_screenshot_tests_are_not_classified_as_experiments(self):
        _, run, _, _, _ = self.run_case([])
        command = run.call_args.args[0]
        self.assertIn("--skip", command)
        pattern = command[command.index("--skip") + 1]
        for name in ["WallpaperMirrorCaptureTests", "WallpaperMirrorRawDiagnosticTests"]:
            self.assertIsNotNone(re.search(pattern, f"WallpaperAppTests.{name}/testCapture"))
        for name in ["WallpaperMirrorStreamTests", "WallpaperMirrorSessionTests", "WallpaperMirrorFrameOutputTests",
                     "WallpaperScreenshotCaptureTests", "WallpaperScreenshotProducerTests", "AppGlassWindowTests"]:
            self.assertIsNone(re.search(pattern, f"WallpaperAppTests.{name}/testCapture"))


if __name__ == "__main__":
    unittest.main()
