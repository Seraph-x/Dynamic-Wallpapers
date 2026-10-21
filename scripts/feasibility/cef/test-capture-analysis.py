#!/usr/bin/env python3
"""Synthetic log regression tests; never launch a browser or capture audio."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ANALYZER = Path(__file__).with_name("analyze-capture.py")


class CaptureAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.probe = "PROBE capture-ready epoch=99.99\n"
        for index, (start, gain) in enumerate(((100, 0), (104, .2), (106, .8), (108, 0), (110, .8))):
            self.probe += f"PROBE phase={index} epoch={start} gain={gain}\n"
        self.probe += "PROBE close-request epoch=114\nPROBE summary loaded=1 paints=30 pcm=1000 closed=1\n"
        self.capture = "CAPTURE scope=probe-application\nCAPTURE ready epoch=99.98\n"
        for index in range(901):
            timestamp = 99.98 + index * .02
            rms = .01 if 104 <= timestamp < 106 else .04 if 106 <= timestamp < 108 or 110 <= timestamp < 114 else 0
            self.capture += (f"CAPTURE epoch={timestamp + .03} samples=1920 rms={rms} "
                             f"pts={timestamp - .02} hostPTS={timestamp} clockOffset=0.02 "
                             f"host={timestamp + .03} sampleEpoch={timestamp} "
                             f"lastNonzeroEpoch={timestamp + .019 if rms else -1}\n")
        self.capture += "CAPTURE complete epoch=119\n"
        self.result = {"probe_exit": 0, "capture_exit": 0}

    def analyze(self, expect="native-gain", require_continuous=False, require_released=False):
        (self.root / "probe.log").write_text(self.probe)
        (self.root / "capture.log").write_text(self.capture)
        if self.result is not None:
            (self.root / "result.json").write_text(json.dumps(self.result))
        command = [sys.executable, str(ANALYZER), str(self.root)]
        if expect:
            command += ["--expect", expect]
        if require_continuous:
            command += ["--require-continuous"]
        if require_released:
            command += ["--require-released"]
        return subprocess.run(command, capture_output=True, text=True, timeout=60)

    def assert_rejected(self, message):
        result = self.analyze()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def update_sample(self, timestamp, **values):
        lines, changed = [], 0
        for line in self.capture.splitlines():
            match = re.search(r"sampleEpoch=([^ ]+)", line)
            if match and abs(float(match[1]) - timestamp) < 1e-8:
                for key, value in values.items():
                    line, count = re.subn(rf"\b{key}=[^\s]+", f"{key}={value}", line)
                    self.assertEqual(count, 1, key)
                changed += 1
            lines.append(line)
        self.assertEqual(changed, 1)
        self.capture = "\n".join(lines) + "\n"

    def remove_samples(self, *timestamps):
        lines, removed = [], 0
        for line in self.capture.splitlines():
            match = re.search(r"sampleEpoch=([^ ]+)", line)
            if match and any(abs(float(match[1]) - timestamp) < 1e-8 for timestamp in timestamps):
                removed += 1
            else:
                lines.append(line)
        self.assertEqual(removed, len(timestamps))
        self.capture = "\n".join(lines) + "\n"

    def add_close_observations(self, epoch=114.01):
        self.probe += f"PROBE output-drain-callback type=2 host={epoch} epoch={epoch}\n"
        self.probe += ("PROBE close-resources released=1 streamsStarted=1 streamsStopped=1 "
                       f"callbacks=0 errors=1 epoch={epoch} host={epoch} estimatedPresentationDeadline={epoch}\n")

    def test_valid_native_gain(self):
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_converted_host_clock_used_for_delay(self):
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["clock_alignment"], "sck_synchronization_clock_to_host")
        self.assertAlmostEqual(report["callback_delay_seconds"]["min"], .03)
        self.assertAlmostEqual(report["callback_delay_seconds"]["max"], .03)
        self.assertAlmostEqual(report["clock_offset_seconds"]["min"], .02)
        self.assertAlmostEqual(report["clock_offset_seconds"]["max"], .02)

    def test_missing_clock_evidence_rejected_for_all_assertions(self):
        original = self.capture
        self.probe += ("PROBE buffer overflowFrames=0 missingFrames=0 lateFrames=0 "
                       "invalidPackets=0 discontinuities=0 invalidRenders=0\n")
        for field in ("hostPTS", "clockOffset"):
            for continuous in (False, True):
                with self.subTest(field=field, continuous=continuous):
                    self.capture = re.sub(rf" {field}=[^\s]+", "", original, count=1)
                    result = self.analyze(expect=False if continuous else "native-gain",
                                          require_continuous=continuous)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("explicit hostPTS and clockOffset", result.stderr)

    def test_direct_scope_with_zero_pcm_summary(self):
        self.probe = self.probe.replace("pcm=1000", "pcm=0")
        self.capture = self.capture.replace("scope=probe-application", "scope=exclude-other-apps")
        lines = []
        for line in self.capture.splitlines():
            match = re.search(r"sampleEpoch=([^ ]+)", line)
            if match and 100 <= float(match[1]) < 114:
                line = re.sub(r"rms=([^ ]+)", "rms=0.04", line)
                line = re.sub(r"lastNonzeroEpoch=([^ ]+)", f"lastNonzeroEpoch={float(match[1]) + .019}", line)
            lines.append(line)
        self.capture = "\n".join(lines) + "\n"
        result = self.analyze("direct-audible")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bypass_scope_requires_nonzero_pcm(self):
        self.capture = self.capture.replace("scope=probe-application", "scope=exclude-other-apps")
        self.capture = re.sub(r"rms=([^ ]+)", "rms=0", self.capture)
        self.capture = re.sub(r"lastNonzeroEpoch=[^\s]+", "lastNonzeroEpoch=-1", self.capture)
        self.probe += "PROBE pcm packets=100 frames=480 rms=0.05\n"
        result = self.analyze("bypass-silent")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_nonzero_high_gain_outside_tolerance_rejected(self):
        self.capture = self.capture.replace("rms=0.04", "rms=0.047")
        self.assert_rejected("Gain ratio")

    def test_fixed_volume_rejected(self):
        self.capture = self.capture.replace("rms=0.04", "rms=0.01")
        self.assert_rejected("Gain ratio")

    def test_fixture_dynamic_source_tolerance(self):
        self.capture = self.capture.replace("rms=0.01", "rms=0.011")
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_run_result_rejected(self):
        self.result = None
        self.assert_rejected("result.json")

    def test_both_process_failures_rejected(self):
        for key in self.result:
            with self.subTest(key=key):
                self.result = {"probe_exit": 0, "capture_exit": 0, key: 1}
                self.assert_rejected("Process failure")

    def test_missing_capture_completion_rejected(self):
        self.capture = self.capture.replace("CAPTURE complete epoch=119\n", "")
        self.assert_rejected("Capture completion")

    def test_failed_summary_rejected(self):
        self.probe = self.probe.replace("closed=1", "closed=0")
        self.assert_rejected("Probe summary")

    def test_missing_summary_rejected(self):
        self.probe = self.probe[:self.probe.index("PROBE summary")]
        self.assert_rejected("Probe summary")

    def test_capture_errors_rejected(self):
        original = self.capture
        for error in ("unexpected-audio-format", "ready-write-error", "copy-error", "failed:", "error"):
            with self.subTest(error=error):
                self.capture = original + f"CAPTURE {error} test failure\n"
                self.assert_rejected("Capture reports failure")

    def test_nonfinite_measurements_and_invalid_counts_rejected(self):
        original = self.capture
        for field, value in (("rms", "nan"), ("rms", "inf"), ("rms", "-0.1"),
                             ("sampleEpoch", "nan"), ("epoch", "inf"), ("pts", "nan"),
                             ("host", "inf"), ("lastNonzeroEpoch", "nan"),
                             ("hostPTS", "nan"), ("hostPTS", "inf"),
                             ("clockOffset", "nan"), ("clockOffset", "inf"),
                             ("samples", "0"), ("samples", "-1")):
            with self.subTest(field=field, value=value):
                self.capture = re.sub(rf"(?m)(^CAPTURE epoch=.*?\b{field}=|^CAPTURE {field}=)[^\s]+",
                                      lambda match: match[1] + value, original, count=1)
                self.assert_rejected("Invalid capture measurement")

    def test_nonzero_rms_with_silent_marker_is_rejected(self):
        self.update_sample(114.26, rms=.04)
        self.assert_rejected("Invalid capture nonzero position")

    def test_nonzero_position_outside_buffer_is_rejected(self):
        original = self.capture
        for position in (-2, 113.9, 114.28):
            with self.subTest(position=position):
                self.capture = original
                self.update_sample(114.26, rms=.04, lastNonzeroEpoch=position)
                self.assert_rejected("Invalid capture nonzero position")

    def test_nonzero_marker_with_zero_rms_is_not_silent_preparation(self):
        self.update_sample(102, lastNonzeroEpoch=102.001)
        self.assert_rejected("Native preparation is not silent")

    def test_nonzero_packet_crossing_preparation_start_is_rejected(self):
        self.update_sample(99.98, samples=3840, rms=.04, lastNonzeroEpoch=100.01)
        self.remove_samples(100)
        self.assert_rejected("Native preparation is not silent")

    def test_nonzero_packet_crossing_mute_250ms_is_rejected(self):
        self.update_sample(108.24, rms=.04, lastNonzeroEpoch=108.259)
        self.assert_rejected("Expected silent phase 3")

    def test_nonzero_marker_with_zero_rms_is_not_silent_bypass(self):
        self.capture = self.capture.replace("scope=probe-application", "scope=exclude-other-apps")
        self.capture = re.sub(r"rms=([^ ]+)", "rms=0", self.capture)
        self.probe += "PROBE pcm packets=100 frames=480 rms=0.05\n"
        result = self.analyze("bypass-silent")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Default-output path contains nonzero samples", result.stderr)

    def test_release_requires_client_and_stream_completion_evidence(self):
        result = self.analyze(require_released=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Close resource evidence missing", result.stderr)

    def test_release_preserves_audio_errors_and_reports_tail(self):
        self.probe += ("PROBE close-resources released=1 streamsStarted=1 streamsStopped=1 "
                       "callbacks=0 errors=1 epoch=114.01 host=114.01 estimatedPresentationDeadline=114.02\n")
        result = self.analyze(require_released=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["close_resources"]["errors"], 1)
        self.assertFalse(report["close_resources"]["clean"])

    def test_release_rejects_unmatched_streams_or_callbacks(self):
        for field, value in (("released", 0), ("streamsStopped", 0), ("callbacks", 1)):
            with self.subTest(field=field):
                original = self.probe
                fields = dict(released=1, streamsStarted=1, streamsStopped=1, callbacks=0,
                              errors=0, epoch=114.01, host=114.01, estimatedPresentationDeadline=114.02)
                fields[field] = value
                self.probe += "PROBE close-resources " + " ".join(f"{k}={v}" for k, v in fields.items()) + "\n"
                result = self.analyze(require_released=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Close resources remain active", result.stderr)
                self.probe = original

    def test_played_back_callback_does_not_hide_later_system_samples(self):
        self.probe += "PROBE output-drain-callback type=2 host=113.98 epoch=113.98\n"
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stderr)
        drain = json.loads(result.stdout)["output_drain"]
        self.assertGreater(drain["sample_tail_after_callback_ms"], 0)
        self.assertFalse(drain["system_silent_after_callback"])

    def test_capture_gaps_cannot_pass_with_sparse_phase_samples(self):
        keep = (99.98, 101, 105, 107, 109, 111, 115)
        self.capture = "\n".join(line for line in self.capture.splitlines()
            if not line.startswith("CAPTURE epoch=") or any(
                abs(float(re.search(r"sampleEpoch=([^ ]+)", line)[1]) - t) < 1e-8 for t in keep)) + "\n"
        self.assert_rejected("Capture sample coverage gap")

    def test_close_tail_crossing_250ms_buffer_boundary_is_rejected(self):
        lines = []
        for line in self.capture.splitlines():
            match = re.search(r"sampleEpoch=([^ ]+)", line)
            if match and abs(float(match[1]) - 114.24) < 1e-8:
                line = line.replace("rms=0 ", "rms=0.04 ").replace("lastNonzeroEpoch=-1", "lastNonzeroEpoch=114.259")
            lines.append(line)
        self.capture = "\n".join(lines) + "\n"
        self.assert_rejected("Nonzero audio remains after close + 250ms")

    def test_nonzero_exactly_at_close_250ms_is_rejected(self):
        self.update_sample(114.24, rms=.04, lastNonzeroEpoch=114.25)
        self.assert_rejected("Nonzero audio remains after close + 250ms")

    def test_nonzero_exactly_at_drain_callback_is_not_silence(self):
        self.update_sample(114, rms=.04, lastNonzeroEpoch=114.01)
        self.probe += "PROBE output-drain-callback type=2 host=114.01 epoch=114.01\n"
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stderr)
        drain = json.loads(result.stdout)["output_drain"]
        self.assertEqual(drain["sample_tail_after_callback_ms"], 0)
        self.assertIs(drain["system_silent_after_callback"], False)

    def test_nonzero_exactly_at_release_is_not_silence(self):
        self.update_sample(114, rms=.04, lastNonzeroEpoch=114.01)
        self.probe += ("PROBE close-resources released=1 streamsStarted=1 streamsStopped=1 "
                       "callbacks=0 errors=1 epoch=114.01 host=114.01 estimatedPresentationDeadline=114.01\n")
        result = self.analyze(require_released=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        release = json.loads(result.stdout)["close_resources"]
        self.assertEqual(release["sample_tail_after_release_ms"], 0)
        self.assertIs(release.get("system_silent_after_release"), False)
        self.assertIs(release.get("system_silent_after_estimated_presentation"), False)

    def test_drain_after_capture_is_unknown(self):
        self.probe += "PROBE output-drain-callback type=2 host=130 epoch=130\n"
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["output_drain"]["system_silent_after_callback"])

    def test_incomplete_evidence_reports_unknown_tails(self):
        original = self.capture
        self.add_close_observations()
        for missing in ("packet", "clockOffset", "lastNonzeroEpoch"):
            with self.subTest(missing=missing):
                self.capture = original
                if missing == "packet":
                    self.remove_samples(108.04)
                else:
                    self.capture = re.sub(rf" {missing}=[^\s]+", "", self.capture, count=1)
                result = self.analyze(expect=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report.get("sample_tails_ms"), {"mute": None, "close": None})
                self.assertIsNone(report["system_silent_after_close_250ms"])
                self.assertIsNone(report["output_drain"]["system_silent_after_callback"])
                self.assertIsNone(report["output_drain"]["sample_tail_after_callback_ms"])
                release = report["close_resources"]
                for key in ("sample_tail_after_release_ms", "system_silent_after_release",
                            "sample_tail_after_estimated_presentation_ms", "system_silent_after_estimated_presentation"):
                    self.assertIsNone(release[key], key)

    def test_drain_and_release_capture_end_boundaries(self):
        original = self.probe
        for epoch, silent in ((99.97, None), (117.99, True), (118, None), (130, None)):
            with self.subTest(epoch=epoch):
                self.probe = original
                self.add_close_observations(epoch)
                result = self.analyze(expect=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertIs(report["output_drain"]["system_silent_after_callback"], silent)
                self.assertIs(report["close_resources"]["system_silent_after_release"], silent)
                self.assertIs(report["close_resources"]["system_silent_after_estimated_presentation"], silent)

    def test_bypass_silence_requires_nonzero_position_evidence(self):
        self.capture = self.capture.replace("scope=probe-application", "scope=exclude-other-apps")
        self.capture = re.sub(r"rms=[^\s]+", "rms=0", self.capture)
        self.capture = re.sub(r"lastNonzeroEpoch=[^\s]+", "lastNonzeroEpoch=-1", self.capture)
        self.capture = re.sub(r" lastNonzeroEpoch=[^\s]+", "", self.capture, count=1)
        self.probe += "PROBE pcm packets=100 frames=480 rms=0.05\n"
        result = self.analyze("bypass-silent")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Capture does not establish post-close sample coverage", result.stderr)

    def test_close_tail_uses_actual_buffer_duration(self):
        self.update_sample(113.96, samples=5760, rms=.04, lastNonzeroEpoch=114.019)
        self.remove_samples(113.98, 114)
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertAlmostEqual(json.loads(result.stdout)["sample_tails_ms"]["close"], 19)

    def test_full_tail_report_is_not_capped_at_250ms(self):
        original = self.capture
        for name, start in (("mute", 108), ("close", 114)):
            with self.subTest(boundary=name):
                self.capture = original
                self.update_sample(start + .4, rms=.04, lastNonzeroEpoch=start + .419)
                result = self.analyze(expect=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertAlmostEqual(json.loads(result.stdout)["sample_tails_ms"][name], 419)

    def test_mute_tail_crossing_resume_without_sample_positions_is_unknown(self):
        self.update_sample(109.98, samples=3840, rms=.04, lastNonzeroEpoch=110.019)
        self.remove_samples(110)
        result = self.analyze(expect=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["sample_tails_ms"]["mute"])

    def test_historical_logs_still_report_without_assertion(self):
        self.result = None
        self.capture = self.capture.replace("CAPTURE complete epoch=119\n", "")
        self.capture = re.sub(r" (hostPTS|clockOffset)=[^\s]+", "", self.capture)
        result = self.analyze(expect=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(report["phases"]), 5)
        self.assertEqual(report["clock_alignment"], "legacy_assumed_host")
        self.assertIsNone(report["clock_offset_seconds"])
        self.assertAlmostEqual(report["callback_delay_seconds"]["min"], .05)


if __name__ == "__main__":
    unittest.main()
