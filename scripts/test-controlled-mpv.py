#!/usr/bin/env python3
"""Build separately, then run each actual product-bridge media phase within 60 seconds."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from media_dependencies import load_lock, mpv_prepared_root
from mpv_source_build import verify_built
from mpv_source_inputs import sha256, source_file
from swift_sdk import selected_sdk
from test import run_tests


def build_harness(root, output, runtime):
    source = root / 'Tests/MPVBridgeHarness/source-acceptance.mm'
    command = ['/usr/bin/clang++', '-std=c++17', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
               '-arch', 'arm64', '-mmacosx-version-min=14.0', '-isysroot', str(selected_sdk()),
               '-I', str(runtime / 'include'), '-I', str(root / 'Sources/MPVBridge/include'),
               str(source), str(runtime / 'runtime-lib/libmpv.2.dylib'), '-framework', 'Foundation',
               '-Wl,-rpath,' + str(runtime / 'runtime-lib'), '-o', str(output)]
    subprocess.run(command, check=True, timeout=60)


def run(root, fixtures, selected):
    lock = load_lock(root / 'scripts/media-dependencies.json', root)
    verify_built(root)
    runtime = mpv_prepared_root(root, lock)
    build_record_sha = sha256(runtime / 'build-record.json')
    sources = {relative: sha256(root / relative) for relative in (
        'Sources/MPVBridge/MPVBridge.mm', 'Tests/MPVBridgeHarness/source-acceptance.mm',
        'scripts/test-controlled-mpv.py')}
    record_path = source_file(fixtures, 'fixture-record.json')
    fixture_record = json.loads(record_path.read_text())
    entries = fixture_record['fixtures']
    if selected:
        entries = [entry for entry in entries if entry['file'] in selected]
        if {entry['file'] for entry in entries} != set(selected):
            raise ValueError('Requested fixture is not in the actual generation record')
    if not entries:
        raise ValueError('No actual native fixtures selected')
    base = root / '.build/media-source-complete/acceptance'
    base.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='native-', dir=base))
    harness = output / 'source-acceptance'
    build_harness(root, harness, runtime)
    reports = []
    for entry in entries:
        media = source_file(fixtures, entry['file'])
        if sha256(media) != entry['sha256']:
            raise ValueError(f'Fixture SHA256 differs from actual generation record: {entry["file"]}')
        report = output / (media.name + '.json')
        print(f'ACTUAL NATIVE PHASE {media.name}; budget=60s', flush=True)
        status = run_tests([str(harness), str(media), str(report), entry['video_codec']],
                           timeout_seconds=60, label=f'controlled libmpv {media.name}')
        if status:
            raise SystemExit(status)
        measured = json.loads(report.read_text())
        if measured.get('passed') is not True or measured.get('nativeHandleAndRendererFreed') is not True:
            raise ValueError(f'Actual native report did not pass strict teardown: {media.name}')
        artifacts = {report.name: sha256(report)}
        for field in ('firstRGBAFile', 'lastRGBAFile'):
            artifacts[measured[field]] = sha256(source_file(output, measured[field]))
        reports.append({'fixture': entry['file'], 'fixture_sha256': entry['sha256'],
                         'report': report.name, 'artifacts': artifacts, 'measured': measured})
    verify_built(root)
    if sha256(runtime / 'build-record.json') != build_record_sha:
        raise ValueError('Controlled runtime build record changed during native acceptance')
    for relative, expected in sources.items():
        if sha256(root / relative) != expected:
            raise ValueError(f'Native acceptance source changed during execution: {relative}')
    summary = {'schema_version': 1, 'passed': True, 'native_phase_budget_seconds': 60,
               'build_record_sha256': build_record_sha,
               'fixture_record_sha256': sha256(record_path),
               'bridge_source_sha256': sources['Sources/MPVBridge/MPVBridge.mm'],
               'harness_source_sha256': sources['Tests/MPVBridgeHarness/source-acceptance.mm'],
               'runner_source_sha256': sources['scripts/test-controlled-mpv.py'],
               'phase_count': len(reports), 'phases': reports}
    (output / 'acceptance.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'ACTUAL NATIVE ACCEPTANCE: {output / "acceptance.json"}', flush=True)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--case', action='append', help='explicit fixture basename; omitted runs all')
    args = parser.parse_args()
    try:
        run(Path(__file__).resolve().parents[1], args.fixtures.resolve(strict=True), args.case)
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f'CONTROLLED MPV ACCEPTANCE FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
