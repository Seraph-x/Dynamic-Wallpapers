#!/usr/bin/env python3
"""Actual software decode and app-equivalent conversion; never launches Main."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'Resources/ThirdParty/MPV/acceptance/fixtures'
CASES = ('av1-opus.mkv', 'av1-opus.webm', 'h264-aac.mkv',
         'vp9-opus.webm', 'mpeg4-mp3.avi', 'zmbv-mp3.avi')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(command, log):
    result = subprocess.run(list(map(str, command)), capture_output=True, timeout=60)
    log.write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'Actual tool exited {result.returncode}; see {log.name}: '
                           + result.stderr.decode(errors='replace')[-1800:])
    return result


def probe(ffprobe, path, directory):
    result = run([ffprobe, '-v', 'error', '-show_streams', '-show_format',
                  '-count_frames', '-of', 'json', path], directory / (path.name + '-probe.log'))
    return json.loads(result.stdout)


def decode(ffmpeg, path, size, directory):
    video = run([ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'info', '-xerror',
                 '-hwaccel', 'none', '-i', path, '-map', '0:v:0', '-an',
                 '-pix_fmt', 'rgba', '-f', 'rawvideo', '-'], directory / (path.name + '-rgba.log'))
    stride = size[0] * size[1] * 4
    if len(video.stdout) < stride * 2 or len(video.stdout) % stride:
        raise ValueError(f'Actual decoded frame size/count is invalid: {path.name}')
    first, last = video.stdout[:stride], video.stdout[-stride:]
    if first == last:
        raise ValueError(f'Actual moving fixture did not produce changing pixels: {path.name}')
    audio = run([ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-xerror',
                 '-i', path, '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '48000',
                 '-c:a', 'pcm_s16le', '-f', 's16le', '-'], directory / (path.name + '-pcm.log')).stdout
    if len(audio) < 48000 or not any(audio):
        raise ValueError(f'Actual audio did not decode: {path.name}')
    return {'frame_count': len(video.stdout) // stride, 'first_rgba_sha256': sha(first),
            'last_rgba_sha256': sha(last), 'pcm_bytes': len(audio), 'pcm_sha256': sha(audio),
            'software_av1_decoder_observed': b'libdav1d' in video.stderr}


def acceptance(ffmpeg, ffprobe, directory):
    outcomes = []
    for name in CASES:
        source = FIXTURES / name
        info = probe(ffprobe, source, directory)
        video = next(stream for stream in info['streams'] if stream['codec_type'] == 'video')
        size = (video['width'], video['height'])
        decoded = decode(ffmpeg, source, size, directory)
        if name.startswith('av1') and not decoded['software_av1_decoder_observed']:
            raise ValueError('Default AV1 decoding did not use the built software decoder')
        output = directory / (name + '.mp4')
        # Same offline stream selection, metadata removal and encoder settings as
        # TranscodePlan; the explicit input flag additionally forbids HW decode.
        run([ffmpeg, '-nostdin', '-hide_banner', '-v', 'error', '-xerror', '-n',
             '-protocol_whitelist', 'file', '-format_whitelist', 'mov,matroska,webm,avi',
             '-hwaccel', 'none', '-i', source, '-map', '0:v:0', '-map', '0:a:0',
             '-map_metadata', '-1', '-map_chapters', '-1', '-sn', '-dn',
             '-c:v', 'h264_videotoolbox', '-allow_sw', '0', '-b:v', '8M', '-pix_fmt', 'yuv420p',
             '-c:a', 'aac', '-fps_mode:v', 'vfr', '-enc_time_base:v', 'demux',
             '-movflags', '+faststart', '-f', 'mp4', output], directory / (name + '-convert.log'))
        converted_info = probe(ffprobe, output, directory)
        streams = converted_info['streams']
        if [stream['codec_name'] for stream in streams] != ['h264', 'aac']:
            raise ValueError(f'Unexpected actual converted streams: {name}')
        if (streams[0]['width'], streams[0]['height']) != size:
            raise ValueError(f'Conversion changed actual fixture dimensions: {name}')
        converted = decode(ffmpeg, output, size, directory)
        if abs(converted['frame_count'] - decoded['frame_count']) > 0:
            raise ValueError(f'Conversion lost actual frames: {name}')
        outcomes.append({'fixture': name, 'fixture_sha256': sha(source.read_bytes()),
                         'decoded': decoded, 'converted': converted,
                         'converted_sha256': sha(output.read_bytes())})
        print('PASS actual software decode + H.264/AAC conversion:', name, flush=True)
    return outcomes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', type=Path, default=ROOT / '.build/dependencies/ffmpeg/install/bin/ffmpeg')
    parser.add_argument('--ffprobe', type=Path, default=ROOT / '.build/dependencies/ffmpeg/install/bin/ffprobe')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    outcomes = acceptance(args.ffmpeg, args.ffprobe, args.output)
    record = {'schema_version': 1, 'ffmpeg_sha256': sha(args.ffmpeg.read_bytes()),
              'ffprobe_sha256': sha(args.ffprobe.read_bytes()), 'cases': outcomes,
              'runner_source_sha256': sha(Path(__file__).read_bytes())}
    (args.output / 'acceptance.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
