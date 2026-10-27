"""Retain only complete, byte-bound actual native media acceptance evidence."""
import json
from pathlib import Path
import shutil

from mpv_source_inputs import sha256, source_file


REQUIRED_FIXTURES = {'h264-aac.mkv', 'vp9-opus.webm', 'mpeg4-mp3.avi',
                     'av1-opus.mkv', 'av1-opus.webm', 'zmbv-mp3.avi'}


def verify_native_acceptance(root, path, fixtures):
    root, path, fixtures = Path(root), Path(path), Path(fixtures)
    summary = json.loads(path.read_text())
    phases = summary.get('phases', [])
    if (summary.get('schema_version') != 1 or summary.get('passed') is not True
            or summary.get('phase_count') != 6 or len(phases) != 6
            or {phase['fixture'] for phase in phases} != REQUIRED_FIXTURES):
        raise ValueError('A complete six-fixture actual native acceptance record is required')
    if summary['build_record_sha256'] != sha256(root / '.build/media-source-complete/mpv/build-record.json'):
        raise ValueError('Native acceptance belongs to different built libraries')
    for key, relative in {
            'bridge_source_sha256': 'Sources/MPVBridge/MPVBridge.mm',
            'harness_source_sha256': 'Tests/MPVBridgeHarness/source-acceptance.mm',
            'runner_source_sha256': 'scripts/test-controlled-mpv.py'}.items():
        if summary[key] != sha256(root / relative):
            raise ValueError(f'Native acceptance source changed: {relative}')
    if summary['fixture_record_sha256'] != sha256(source_file(fixtures, 'fixture-record.json')):
        raise ValueError('Native fixture generation record changed')
    for phase in phases:
        if phase['fixture_sha256'] != sha256(source_file(fixtures, phase['fixture'])):
            raise ValueError(f'Native fixture changed: {phase["fixture"]}')
        measured = phase['measured']
        if (measured.get('passed') is not True or measured.get('nativeHandleAndRendererFreed') is not True
                or measured.get('callbacksAfterCloseCompletion') != 0
                or measured.get('audioOutput') != 'coreaudio'
                or measured.get('frameCount', 0) < 20 or measured.get('distinctPixelHashes', 0) < 8
                or measured.get('loops', 0) < 1 or measured.get('maximumAudioPTS', 0) < 0.5):
            raise ValueError(f'Actual native result is incomplete: {phase["fixture"]}')
        for relative, expected in phase['artifacts'].items():
            if sha256(source_file(path.parent, relative)) != expected:
                raise ValueError(f'Native acceptance artifact changed: {relative}')
        if json.loads(source_file(path.parent, phase['report']).read_text()) != measured:
            raise ValueError('Native measured result differs from its actual report')
    return summary


def export_native_acceptance(root, path, fixtures):
    from media_build_materials import refresh_material_manifest
    root, path, fixtures = Path(root), Path(path), Path(fixtures)
    summary = verify_native_acceptance(root, path, fixtures)
    destination = root / 'Resources/ThirdParty/MPV/acceptance'
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, destination / 'acceptance.json')
    for phase in summary['phases']:
        for relative in phase['artifacts']:
            shutil.copyfile(source_file(path.parent, relative), destination / relative)
    fixture_destination = destination / 'fixtures'
    fixture_destination.mkdir(exist_ok=True)
    for name in ['fixture-record.json', *sorted(REQUIRED_FIXTURES)]:
        shutil.copyfile(source_file(fixtures, name), fixture_destination / name)
    status_path = root / 'Resources/ThirdParty/distribution-status.json'
    status = json.loads(status_path.read_text())
    status['components']['mpv'].update(
        complete=True, scope='Complete corresponding source, exact patches, original notices, '
        'real source-build record and six actual product-bridge acceptance phases retained; '
        'CoreAudio clock/output, software pixels, VT-copy, AV1 software decoding, loops, settings '
        'and strict teardown measured; acoustic speaker output not measured')
    status['scope'] = ('Corresponding source, notices and measured media build records; '
                        'application/release functional acceptance is recorded separately.')
    status['unresolved'] = []
    status_path.write_text(json.dumps(status, indent=2) + '\n')
    refresh_material_manifest(root)
    return summary
