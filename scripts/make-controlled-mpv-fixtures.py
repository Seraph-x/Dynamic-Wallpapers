#!/usr/bin/env python3
"""Generate real local codec/container fixtures with an explicitly selected encoder."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from mpv_source_inputs import sha256


CASES = (
    ('h264-aac.mkv', 'h264', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac']),
    ('vp9-opus.webm', 'vp9', ['-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-cpu-used', '8',
                           '-pix_fmt', 'yuv420p', '-c:a', 'libopus']),
    ('mpeg4-mp3.avi', 'mpeg4', ['-c:v', 'mpeg4', '-q:v', '3', '-pix_fmt', 'yuv420p',
                             '-c:a', 'libmp3lame']),
    ('av1-opus.mkv', 'av1', ['-c:v', 'libsvtav1', '-preset', '11', '-crf', '42',
                           '-pix_fmt', 'yuv420p', '-c:a', 'libopus']),
    ('zmbv-mp3.avi', 'zmbv', ['-c:v', 'zmbv', '-pix_fmt', 'bgr0', '-c:a', 'libmp3lame']),
)


def generate(output, ffmpeg):
    output.mkdir(parents=True, exist_ok=False)
    ffmpeg = Path(shutil.which(ffmpeg) or ffmpeg).resolve(strict=True)
    version = subprocess.check_output([str(ffmpeg), '-version'], text=True).splitlines()[0]
    records = []
    for name, codec, options in CASES:
        arguments = ['-nostdin', '-hide_banner', '-loglevel', 'error',
                     '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=12',
                     '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
                     '-t', '2', *options, '-threads', '2', name]
        subprocess.run([str(ffmpeg), *arguments], cwd=output, check=True)
        records.append({'file': name, 'video_codec': codec, 'sha256': sha256(output / name),
                         'command_arguments': arguments})
    arguments = ['-nostdin', '-hide_banner', '-loglevel', 'error', '-i', 'av1-opus.mkv',
                 '-c', 'copy', 'av1-opus.webm']
    subprocess.run([str(ffmpeg), *arguments], cwd=output, check=True)
    records.append({'file': 'av1-opus.webm', 'video_codec': 'av1',
                    'sha256': sha256(output / 'av1-opus.webm'), 'command_arguments': arguments})
    record = {'schema_version': 1, 'generator_version': version,
              'generator_sha256': sha256(ffmpeg), 'fixtures': records}
    (output / 'fixture-record.json').write_text(json.dumps(record, indent=2) + '\n')
    print(f'GENERATED {len(records)} actual encoded fixtures: {output}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='new fixture directory')
    parser.add_argument('--ffmpeg', required=True, help='explicit encoder executable')
    options = parser.parse_args()
    generate(options.output.resolve(), options.ffmpeg)
