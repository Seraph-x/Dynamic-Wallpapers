#!/usr/bin/env python3
"""Report RMS/tails and optionally assert a specific probe condition, never whole CEF acceptance."""
import json
import argparse
import math
from pathlib import Path
import re


# This fixture adds a .03-amplitude oscillator during the .2-gain window.
# Its input energy therefore differs slightly from the later .8-gain windows.
EXPECTED_GAIN_RATIO = 4.0
GAIN_RATIO_RELATIVE_TOLERANCE = .15
CAPTURE_SAMPLE_RATE = 48000
CAPTURE_CHANNELS = 2


def fields(line):
    return dict(re.findall(r"(\w+)=([^\s]+)", line))


def validate_measurements(raw):
    for index, sample in enumerate(raw):
        values = [float(sample[key]) for key in ("epoch", "sampleEpoch", "pts", "host", "rms")]
        values.extend(float(sample[key]) for key in ("lastNonzeroEpoch", "firstNonzeroEpoch", "hostPTS", "clockOffset")
                      if key in sample)
        if (not all(math.isfinite(value) for value in values)
                or float(sample["rms"]) < 0 or int(sample["samples"]) <= 0 or int(sample["samples"]) % CAPTURE_CHANNELS != 0):
            raise ValueError(f"Invalid capture measurement in buffer {index}: {sample}")
        if "lastNonzeroEpoch" in sample:
            last, start = float(sample["lastNonzeroEpoch"]), float(sample["sampleEpoch"])
            end = start + (int(sample["samples"]) // CAPTURE_CHANNELS - 1) / CAPTURE_SAMPLE_RATE
            tolerance = 2 * (math.ulp(start) + math.ulp(end) + math.ulp(last))
            if (last == -1 and float(sample["rms"]) > 0
                    or last != -1 and not start - tolerance <= last <= end + tolerance):
                raise ValueError(f"Invalid capture nonzero position in buffer {index}: {sample}")


def clock_report(raw):
    converted = all("hostPTS" in sample and "clockOffset" in sample for sample in raw)
    # Missing conversion evidence is permitted only in explicitly labeled reports.
    delays = [float(sample["host"]) - float(sample.get("hostPTS", sample["pts"])) for sample in raw]
    offsets = [float(sample["clockOffset"]) for sample in raw] if converted else None
    return {
        "clock_alignment": "sck_synchronization_clock_to_host" if converted else "legacy_assumed_host",
        "callback_delay_seconds": {"min": min(delays), "max": max(delays)},
        "clock_offset_seconds": {"min": min(offsets), "max": max(offsets)} if offsets else None,
    }


def summarize(samples, start, end):
    selected = [s for s in samples if start <= s[0] < end]
    if not selected:
        raise ValueError(f"No capture samples in [{start}, {end})")
    count = sum(s[2] for s in selected)
    return {"buffers": len(selected), "rms": math.sqrt(sum(s[1] ** 2 * s[2] for s in selected) / count),
            "max_buffer_rms": max(s[1] for s in selected),
            "nonzero_buffers": sum(s[3] for s in selected)}



def validate_run_completion(args, probe, capture):
    result_path = args.root / "result.json"
    if not result_path.is_file():
        raise ValueError("Acceptance requires result.json with actual process exit codes")
    execution = json.loads(result_path.read_text())
    for key in ("probe_exit", "capture_exit"):
        if type(execution.get(key)) is not int or execution[key] != 0:
            raise ValueError(f"Process failure or missing exit status: {key}={execution.get(key)}")
    completions = [line for line in capture.splitlines() if line.startswith("CAPTURE complete epoch=")]
    if len(completions) != 1 or capture.splitlines()[-1] != completions[0]:
        raise ValueError("Capture completion marker missing or not final")
    summaries = [fields(line) for line in probe.splitlines() if line.startswith("PROBE summary ")]
    if len(summaries) != 1:
        raise ValueError("Probe summary missing or duplicated")
    summary = summaries[0]
    if (summary.get("loaded") != "1" or summary.get("closed") != "1"
            or int(summary.get("paints", "0")) <= 0
            or (args.expect != "direct-audible" and int(summary.get("pcm", "0")) <= 0)):
        raise ValueError(f"Probe summary reports incomplete execution: {summary}")


def validate_gain_ratios(result):
    low = result["phases"][1]["interior_excluding_250ms_edges"]["rms"]
    for index in (2, 4):
        high = result["phases"][index]["interior_excluding_250ms_edges"]["rms"]
        ratio = high / low
        if not math.isclose(ratio, EXPECTED_GAIN_RATIO, rel_tol=0,
                            abs_tol=EXPECTED_GAIN_RATIO * GAIN_RATIO_RELATIVE_TOLERANCE):
            raise ValueError(f"Gain ratio phase {index}/1={ratio:.6f}; expected 4 +/- 15% for this fixture")


def capture_coverage(raw):
    if not all("hostPTS" in sample for sample in raw):
        return {"continuous": False, "reason": "hostPTS missing"}
    for previous, current in zip(raw, raw[1:]):
        start, next_start = float(previous["hostPTS"]), float(current["hostPTS"])
        duration = int(previous["samples"]) / (CAPTURE_SAMPLE_RATE * CAPTURE_CHANNELS)
        gap = next_start - start - duration
        # Only representational rounding, not a dropped sample/frame budget.
        tolerance = 2 * (math.ulp(start) + math.ulp(next_start) + math.ulp(duration))
        if abs(gap) > tolerance:
            return {"continuous": False, "reason": "Capture sample coverage gap or overlap", "gap_seconds": gap}
    return {"continuous": True, "start_epoch": float(raw[0]["sampleEpoch"]),
            "end_epoch": float(raw[-1]["sampleEpoch"]) + int(raw[-1]["samples"]) / (CAPTURE_SAMPLE_RATE * CAPTURE_CHANNELS)}


def observe_samples(raw, boundary, end=None):
    """Return tail milliseconds and silence separately: a boundary sample has a zero tail."""
    coverage = capture_coverage(raw)
    if (not coverage["continuous"]
            or not all("lastNonzeroEpoch" in sample and "clockOffset" in sample for sample in raw)):
        return None, None
    end = coverage["end_epoch"] if end is None else end
    if not coverage["start_epoch"] <= boundary < end <= coverage["end_epoch"]:
        return None, None
    last = max(float(sample["lastNonzeroEpoch"]) for sample in raw if float(sample["sampleEpoch"]) < end)
    if last >= end:
        # A crossing packet's final position cannot locate its last nonzero
        # sample before resume without the intervening sample positions.
        return None, None
    return max(0, (last - boundary) * 1000), last < boundary


def output_drain_report(probe, raw):
    records = [fields(line) for line in probe.splitlines() if line.startswith("PROBE output-drain-callback ")]
    if not records:
        return None
    if len(records) != 1:
        raise ValueError("Output drain callback duplicated")
    record = records[0]
    epoch, host = float(record["epoch"]), float(record["host"])
    if not math.isfinite(epoch) or not math.isfinite(host) or record["type"] != "2":
        raise ValueError("Invalid played-back callback")
    tail, silent = observe_samples(raw, epoch)
    return {"callback_type": "dataPlayedBack", "sample_tail_after_callback_ms": tail,
            "system_silent_after_callback": silent,
            "observation_end_epoch": capture_coverage(raw).get("end_epoch")}


def close_resource_report(probe, raw, required):
    records = [fields(line) for line in probe.splitlines() if line.startswith("PROBE close-resources ")]
    if not records:
        if required:
            raise ValueError("Close resource evidence missing")
        return None
    if len(records) != 1:
        raise ValueError("Close resource evidence duplicated")
    record = records[0]
    counts = {key: int(record[key]) for key in ("released", "streamsStarted", "streamsStopped", "callbacks", "errors")}
    if any(value < 0 for value in counts.values()):
        raise ValueError("Invalid close resource counters")
    epoch = float(record["epoch"])
    deadline = float(record["estimatedPresentationDeadline"])
    host = float(record["host"])
    if not all(math.isfinite(value) for value in (epoch, deadline, host)):
        raise ValueError("Invalid close resource times")
    released = counts["released"] == 1 and counts["streamsStarted"] == counts["streamsStopped"] and counts["callbacks"] == 0
    if required and not released:
        raise ValueError("Close resources remain active")
    release_tail, release_silent = observe_samples(raw, epoch)
    deadline_tail, deadline_silent = observe_samples(raw, epoch + deadline - host)
    return {**counts, "clean": released and counts["errors"] == 0,
            "sample_tail_after_release_ms": release_tail, "system_silent_after_release": release_silent,
            "sample_tail_after_estimated_presentation_ms": deadline_tail,
            "system_silent_after_estimated_presentation": deadline_silent}


def validate_expectations(args, probe, capture, samples, phases, result):
    if args.expect or args.require_continuous or args.require_released:
        validate_run_completion(args, probe, capture)
        if result["clock_alignment"] != "sck_synchronization_clock_to_host":
            raise ValueError("Acceptance requires explicit hostPTS and clockOffset in every capture buffer")
        if not result["capture_coverage"]["continuous"]:
            raise ValueError(result["capture_coverage"]["reason"])
    if args.require_continuous:
        stats = fields(next(line for line in probe.splitlines() if line.startswith("PROBE buffer ")))
        for key in ("overflowFrames", "missingFrames", "lateFrames", "invalidPackets", "discontinuities", "invalidRenders"):
            if key not in stats or int(stats[key]) != 0:
                raise ValueError(f"Continuity check failed: {key}={stats.get(key, 'missing')}")
    if args.expect:
        if [int(p["phase"]) for p in phases] != list(range(5)):
            raise ValueError("Incomplete phase sequence")
        if "CAPTURE ready epoch=" not in capture or "PROBE capture-ready epoch=" not in probe:
            raise ValueError("Acceptance requires capture readiness handshake")
        if samples[0][0] >= float(phases[0]["epoch"]):
            raise ValueError("Capture misses preparation start")
        if result["sample_tail_after_close_250ms_ms"] is None:
            raise ValueError("Capture does not establish post-close sample coverage")
        if args.expect == "bypass-silent":
            if "CAPTURE scope=exclude-other-apps" not in capture:
                raise ValueError("Bypass check requires the positive-control exclusion filter")
            if any(s[3] for s in samples):
                raise ValueError("Default-output path contains nonzero samples")
            if not re.search(r"pcm packets=\d+ .*rms=0\.[0-9]*[1-9]", probe):
                raise ValueError("No nonzero CEF PCM evidence")
        else:
            required_scope = "exclude-other-apps" if args.expect == "direct-audible" else "probe-application"
            if f"CAPTURE scope={required_scope}" not in capture:
                raise ValueError(f"Expected capture scope {required_scope}")
            if not result["system_silent_after_close_250ms"]:
                raise ValueError("Nonzero audio remains after close + 250ms; full tails remain reported")
            if args.expect == "native-gain" and result["phases"][0]["full"]["system_silent"] is not True:
                raise ValueError("Native preparation is not silent or lacks complete sample evidence")
            for phase in result["phases"]:
                rms = phase["interior_excluding_250ms_edges"]["rms"]
                should_sound = args.expect == "direct-audible" or phase["gain"] > 0
                if should_sound and rms <= 0.001:
                    raise ValueError(f"Expected audible phase {phase['phase']}: {rms}")
                silent = phase["interior_excluding_250ms_edges"]["system_silent"]
                if not should_sound and silent is not True:
                    raise ValueError(f"Expected silent phase {phase['phase']}: rms={rms} sample_silence={silent}")
            if args.expect == "native-gain":
                validate_gain_ratios(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--expect", choices=("direct-audible", "bypass-silent", "native-gain"))
    parser.add_argument("--require-continuous", action="store_true")
    parser.add_argument("--require-released", action="store_true", help="Require client/stream cleanup; audio errors and system tails remain reported")
    args = parser.parse_args()
    root = args.root
    probe = (root / "probe.log").read_text()
    capture = (root / "capture.log").read_text()
    capture_events = re.findall(r"^CAPTURE (\S+)", capture, re.MULTILINE)
    if any(any(word in event for word in ("error", "failed", "unexpected")) for event in capture_events):
        raise ValueError("Capture reports failure; inspect capture.log")
    phases = [fields(line) for line in probe.splitlines() if line.startswith("PROBE phase=")]
    close = float(next(fields(line)["epoch"] for line in probe.splitlines() if line.startswith("PROBE close-request")))
    raw = [fields(line) for line in capture.splitlines() if line.startswith("CAPTURE epoch=")]
    if not raw or any("sampleEpoch" not in s for s in raw):
        raise ValueError("Sample PTS missing; legacy callback-only logs cannot provide sample-time alignment")
    validate_measurements(raw)
    clock = "sampleEpoch"
    samples = [(float(s[clock]), float(s["rms"]), int(s["samples"]),
                float(s["rms"]) != 0 or float(s.get("lastNonzeroEpoch", -1)) != -1) for s in raw]
    result = {"clock": clock, "phases": [], "diagnostics": [line for line in probe.splitlines()
              if any(word in line for word in ("audio-error", "underflow", "summary"))]}
    for i, phase in enumerate(phases):
        start = float(phase["epoch"])
        end = float(phases[i + 1]["epoch"]) if i + 1 < len(phases) else close
        full = summarize(samples, start, end)
        full["system_silent"] = observe_samples(raw, start, end)[1]
        interior = summarize(samples, start + .25, end - .25)
        interior["system_silent"] = observe_samples(raw, start + .25, end - .25)[1]
        result["phases"].append({"phase": int(phase["phase"]), "gain": float(phase["gain"]),
                                 "full": full, "interior_excluding_250ms_edges": interior})
    if [int(phase["phase"]) for phase in phases] == list(range(5)):
        low = result["phases"][1]["interior_excluding_250ms_edges"]["rms"]
        result["gain_ratios"] = {
            f"phase_{index}_over_1": result["phases"][index]["interior_excluding_250ms_edges"]["rms"] / low if low > 0 else None
            for index in (2, 4)
        }
    result["after_close_full"] = summarize(samples, close, samples[-1][0] + .001)
    result["after_close_250ms"] = summarize(samples, close + .25, samples[-1][0] + .001)
    boundaries = [("mute", float(p["epoch"]), float(phases[i + 1]["epoch"]) if i + 1 < len(phases) else close)
                  for i, p in enumerate(phases) if p["phase"] == "3"] + [("close", close, None)]
    result["sample_tails_ms"] = {name: observe_samples(raw, start, end)[0] for name, start, end in boundaries}
    result["capture_coverage"] = capture_coverage(raw)
    result["sample_tail_after_close_250ms_ms"], result["system_silent_after_close_250ms"] = observe_samples(raw, close + .25)
    result["output_drain"] = output_drain_report(probe, raw)
    result["close_resources"] = close_resource_report(probe, raw, args.require_released)
    result.update(clock_report(raw))
    print(json.dumps(result, indent=2))
    validate_expectations(args, probe, capture, samples, phases, result)


if __name__ == "__main__":
    main()
