#!/usr/bin/env python3
"""Exercise owned media fixtures and retain evidence for current built products.

Runs real audio/video decoding and hardware conversion. Requires the prepared
controlled tools and a logged-in macOS host; never installs or launches Main.
"""
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile

from media_acceptance_materials import export_native_acceptance
from media_build_materials import (export_ffmpeg_record, export_mpv_record,
                                   refresh_material_manifest, verify_material_build_records)
from media_bundle_materials import verify_distribution_materials
from media_dependencies import load_lock


def verify(root):
    artifacts = root / '.build/verification'
    artifacts.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='current-media-', dir=artifacts))
    fixtures = work / 'fixtures'
    shutil.copytree(root / 'Resources/ThirdParty/MPV/acceptance/fixtures', fixtures)
    native = runpy.run_path(str(root / 'scripts/test-controlled-mpv.py'))['run'](root, fixtures, None)
    conversion = work / 'conversion'
    subprocess.run([sys.executable, str(root / 'scripts/test-ffmpeg-av1-tools.py'),
                    '--output', str(conversion)], check=True)
    export_ffmpeg_record(root)
    export_mpv_record(root)
    export_native_acceptance(root, native / 'acceptance.json', fixtures)
    shutil.copy2(conversion / 'acceptance.json',
                 root / 'Resources/ThirdParty/FFmpeg/acceptance/software-transcode.json')
    refresh_material_manifest(root)
    verify_material_build_records(root, load_lock(root / 'scripts/media-dependencies.json', root))
    status = verify_distribution_materials(root / 'Resources/ThirdParty')
    if status['complete'] is not True:
        raise ValueError('Current media acceptance did not establish complete material records')
    receipt = {'native_acceptance': str(native / 'acceptance.json'),
               'conversion_acceptance': str(conversion / 'acceptance.json'),
               'materials_complete': True}
    (work / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'CURRENT MEDIA VERIFIED: {work / "result.json"}', flush=True)


if __name__ == '__main__':
    verify(Path(__file__).resolve().parents[1])
