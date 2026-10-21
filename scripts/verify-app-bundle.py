#!/usr/bin/env python3
"""Read-only verification of candidate contents, Mach-O closure and signatures."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from media_bundle import verify_candidate
from product_configuration import load as load_product_configuration


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--report', type=Path, required=True, help='new JSON evidence file outside the app')
    args = parser.parse_args()
    app = args.app.resolve()
    if args.report.resolve().is_relative_to(app):
        raise ValueError('Verification report must not mutate the signed app')
    if args.report.exists():
        raise FileExistsError(f'Report exists: {args.report}')
    root = Path(__file__).resolve().parents[1]
    configuration = load_product_configuration(root / 'scripts/product-configuration.json')
    names = [entry['file'] for entry in json.loads((root / 'scripts/feasibility/mpv/libraries.json').read_text())]
    result = verify_candidate(app, names, configuration=configuration)
    result['bundle'] = str(app)
    with args.report.open('x') as stream:
        json.dump(result, stream, indent=2); stream.write('\n')
    print(f'VERIFIED static bundle/signature closure: {app}; runtime and public distribution readiness are separate.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'BUNDLE VERIFICATION FAILED: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, file=sys.stderr)
        raise SystemExit(1)
