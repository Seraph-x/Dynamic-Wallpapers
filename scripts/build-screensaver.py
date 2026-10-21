#!/usr/bin/env python3
"""Build a new independent Dynamic Wallpaper screen saver candidate; never installs it."""
import argparse
from pathlib import Path
import subprocess
import sys

from screensaver_bundle import build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    arguments = parser.parse_args()
    build(arguments.output)


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'SCREEN SAVER BUILD FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
