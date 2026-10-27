#!/usr/bin/env python3
"""Export real measured local media build records and refresh material hashes."""
import argparse
from pathlib import Path
import subprocess
import sys

from media_build_materials import export_ffmpeg_record, export_mpv_record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('modules', nargs='+', choices=('ffmpeg', 'mpv'))
    parser.add_argument('--ffmpeg-root', type=Path,
                        help='explicit read-only location of an existing verified FFmpeg build')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for module in options.modules:
        if module == 'ffmpeg':
            export_ffmpeg_record(root, ffmpeg_root=options.ffmpeg_root)
        else:
            export_mpv_record(root)
        print(f'EXPORTED actual {module} build evidence', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'MEDIA BUILD EVIDENCE EXPORT FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
