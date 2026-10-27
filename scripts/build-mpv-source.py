#!/usr/bin/env python3
"""Build or verify the pinned controlled libmpv closure; does not run playback."""
from pathlib import Path
import subprocess
import sys
import tarfile

from mpv_source_build import build


if __name__ == '__main__':
    try:
        build(Path(__file__).resolve().parents[1])
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f'CONTROLLED MPV BUILD FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
