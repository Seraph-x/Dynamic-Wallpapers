#!/usr/bin/env python3
"""Compile a header-matched FFmpeg decoder audit; never initializes mpv or audio."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from media_build_materials import normalized_ffmpeg_configuration
from mpv_source_inputs import sha256
from swift_sdk import selected_sdk


def audit(root, runtime, headers):
    runtime, headers = Path(runtime).resolve(), Path(headers).resolve()
    image = runtime / 'libavcodec.61.dylib'
    before = sha256(image)
    base = Path(root) / '.build/media-source-complete/audits'
    base.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='codecs-', dir=base))
    executable = directory / 'codec-audit'
    subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-mmacosx-version-min=14.0',
                    '-isysroot', str(selected_sdk()), '-I', str(headers),
                    '-Wl,-rpath,' + str(runtime), str(Path(root) / 'scripts/mpv-codec-audit.c'),
                    '-o', str(executable)], check=True)
    environment = dict(os.environ, DYLD_LIBRARY_PATH=str(runtime))
    raw = subprocess.check_output([str(executable), str(image)], env=environment, text=True)
    result = json.loads(raw)
    if sha256(image) != before:
        raise ValueError('Decoder audit input changed while enumerating')
    configuration = result.pop('configuration')
    result['configure_options'], _prefix = normalized_ffmpeg_configuration(configuration)
    result['configuration_sha256'] = hashlib.sha256(configuration.encode()).hexdigest()
    result['libavcodec_sha256'] = before
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--headers', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = audit(Path(__file__).resolve().parents[1], args.runtime, args.headers)
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2); stream.write('\n')
    print(f'ACTUAL decoder audit: {len(result["decoders"])} decoders; {args.output}', flush=True)
