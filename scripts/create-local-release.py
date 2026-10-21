#!/usr/bin/env python3
"""Archive a verified candidate locally; never install, launch, upload or create a DMG."""
import argparse
from pathlib import Path
import subprocess
import sys
import zipfile

from media_release import create_local_release


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='completed application candidate')
    parser.add_argument('--output', type=Path, required=True, help='new release directory below this worktree dist')
    parser.add_argument('--notes', type=Path, required=True, help='release notes describing actual acceptance and limitations')
    args = parser.parse_args()
    create_local_release(root, app=args.app, output=args.output, notes=args.notes)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f'LOCAL RELEASE FAILED: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, file=sys.stderr)
        raise SystemExit(1)
