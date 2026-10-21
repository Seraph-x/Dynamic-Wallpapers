#!/usr/bin/env python3
"""Run the isolated, real fullscreen benchmark and record scoped CPU + whole-GPU data.

This never rebuilds or launches the installed wallpaper application. GPU counters
are system-wide, not attributable to this process. Readback evidence is excluded
from the performance windows. Every run uses a new output directory.
"""
import argparse
import json
import plistlib
from pathlib import Path
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / '.build/verification/live-fullscreen-wallpaper-20260913/performance'
EXECUTABLE = ARTIFACTS / 'MirrorCaptureBenchmark.app/Contents/MacOS/MirrorCaptureBenchmark'
INSTALLED = ROOT / 'dist/Dynamic Wallpaper.app/Contents/MacOS/DynamicWallpaper'
SAMPLE_INTERVAL = 0.5


def cpu_seconds(value):
    """Convert the cumulative mm:ss.cc / hh:mm:ss.cc output of macOS ps."""
    parts = value.split(':')
    if len(parts) not in (2, 3):
        raise ValueError(f'Unexpected ps CPU time: {value}')
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total


def process_snapshot(benchmark_pid):
    output = subprocess.check_output(
        ['ps', '-A', '-o', 'pid=,time=,rss=,comm='], text=True, timeout=3)
    selected = {}
    for line in output.splitlines():
        pid, elapsed, rss, path = line.strip().split(None, 3)
        if int(pid) == benchmark_pid:
            role = 'benchmark'
        elif path == str(INSTALLED):
            role = 'installed-wallpaper'
        elif Path(path).name in ('WindowServer', 'replayd'):
            role = Path(path).name
        else:
            continue
        if role in selected:
            raise RuntimeError(f'Ambiguous monitored process {role}')
        selected[role] = dict(pid=int(pid), cpuSeconds=cpu_seconds(elapsed), rssMiB=int(rss) / 1024)
    for role in ('WindowServer', 'replayd'):
        if role not in selected:
            raise RuntimeError(f'Missing monitored process {role}')
    return selected


def gpu_snapshot():
    raw = subprocess.check_output(['ioreg', '-r', '-c', 'IOAccelerator', '-d', '1', '-a'], timeout=3)
    nodes = plistlib.loads(raw)
    if len(nodes) != 1:
        raise RuntimeError(f'Expected one GPU on this benchmark host, got {len(nodes)}')
    stats = nodes[0]['PerformanceStatistics']
    for key in ('Device Utilization %', 'Renderer Utilization %', 'Tiler Utilization %'):
        if key not in stats:
            raise RuntimeError(f'GPU metric is unavailable: {key}')
    return dict(device=nodes[0]['IOClass'], statistics=stats)


def phase_rows(rows, result):
    # Both ends of a cumulative CPU delta must lie inside the exact Swift window.
    return [row for row in rows
            if result['startUnix'] <= row['unix']
            and row['endUnix'] <= result['endUnix']]


def summarize(rows, results):
    summary = []
    for result in results:
        samples = phase_rows(rows, result)
        if len(samples) < 3:
            raise RuntimeError(f'Insufficient system samples for {result["phase"]}: {len(samples)}')
        processes = {}
        for role in samples[0]['processes']:
            values = [row['processes'][role] for row in samples]
            if len({value['pid'] for value in values}) != 1:
                raise RuntimeError(f'Monitored process changed during {result["phase"]}: {role}')
            seconds = samples[-1]['unix'] - samples[0]['unix']
            processes[role] = dict(
                pid=values[0]['pid'], seconds=seconds,
                cpuPercentOneCore=(values[-1]['cpuSeconds'] - values[0]['cpuSeconds']) / seconds * 100,
                peakSampledRSSMiB=max(value['rssMiB'] for value in values))
        gpu = [row['gpu']['statistics']['Device Utilization %'] for row in samples]
        summary.append(dict(phase=result['phase'], mode=result['mode'], samples=len(samples),
                            processes=processes, wholeGPUPercent=dict(mean=statistics.mean(gpu),
                            median=statistics.median(gpu), min=min(gpu), max=max(gpu))))
    return summary


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def run(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    video = args.video.resolve(strict=True)
    command = [str(EXECUTABLE), str(video), str(output), args.order]
    write_json(output / 'command.json', dict(argv=command, timeoutSeconds=args.timeout,
        sampleIntervalSeconds=SAMPLE_INTERVAL, gpuScope='whole-system',
        cpuPercentScale='100% is one logical CPU, not the whole machine',
        performanceReadback=False))
    rows = []
    with (output / 'application.log').open('w') as log, (output / 'system-samples.jsonl').open('w') as raw:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + args.timeout
        try:
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f'Benchmark exceeded {args.timeout}s; PID {process.pid}')
                began = time.monotonic()
                row = dict(unix=time.time(), processes=process_snapshot(process.pid), gpu=gpu_snapshot())
                phase = output / 'phase.json'
                row['phase'] = json.loads(phase.read_text()) if phase.exists() else dict(state='startup')
                row['endUnix'] = time.time()
                raw.write(json.dumps(row) + '\n'); raw.flush()
                rows.append(row)
                time.sleep(max(0, SAMPLE_INTERVAL - (time.monotonic() - began)))
            write_json(output / 'exit.json', dict(returncode=process.returncode))
            if process.returncode != 0:
                raise RuntimeError(f'Benchmark exit {process.returncode}; see {output / "application.log"}')
            results = json.loads((output / 'results.json').read_text())
            write_json(output / 'system-summary.json', summarize(rows, results))
        except BaseException as error:
            write_json(output / 'failure.json', dict(error=repr(error), pid=process.pid))
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    print(f'Benchmark PID {process.pid} did not terminate; killing owned process', flush=True)
                    process.kill(); process.wait(timeout=3)
            write_json(output / 'exit.json', dict(returncode=process.returncode))
            raise
    print((output / 'application.log').read_text(), end='')
    print(f'System measurements: {output / "system-summary.json"}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--order', choices=('forward', 'reverse'), default='forward')
    parser.add_argument('--timeout', type=float, default=60, help='Observable per-run wall-clock timeout')
    arguments = parser.parse_args()
    if arguments.timeout <= 0:
        parser.error('--timeout must be positive')
    run(arguments)
