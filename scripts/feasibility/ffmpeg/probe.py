#!/usr/bin/env python3
"""Verify bundled VideoToolbox/AAC encoding and real process cancellation."""
import argparse
import hashlib
import json
from pathlib import Path
import selectors
import subprocess
import tempfile
import time


def transcode(binary, source, target, cancel):
    command = [str(binary), "-nostdin", "-hide_banner", "-v", "error", "-n",
               "-stats_period", "0.1", "-progress", "pipe:1", "-re",
               "-protocol_whitelist", "file", "-i", str(source),
               "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "h264_videotoolbox",
               "-allow_sw", "0", "-b:v", "1M", "-pix_fmt", "yuv420p",
               "-c:a", "aac", str(target)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "progress")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    output = {"progress": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + 20
    terminated = False
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise TimeoutError("Real FFmpeg process exceeded 20-second probe deadline")
            for key, _ in selector.select(0.1):
                data = key.fileobj.read1(65536)
                if data:
                    output[key.data].extend(data)
                else:
                    selector.unregister(key.fileobj)
            media_times = [int(line.partition(b"=")[2])
                           for line in output["progress"].splitlines()
                           if line.startswith(b"out_time_us=") and line.partition(b"=")[2].isdigit()]
            if cancel and not terminated and any(value > 0 for value in media_times):
                process.terminate()
                terminated = True
        status = process.wait(timeout=2)
        report = {key: value.decode() for key, value in output.items()}
        report.update(cancelRequested=cancel, terminated=terminated, exitCode=status)
        print(json.dumps(report), flush=True)
        assert any(value > 0 for value in media_times), "No encoded media progress"
        if cancel:
            assert terminated and status != 0, "SIGTERM did not cancel encoding"
        else:
            assert status == 0 and "progress=end" in report["progress"], "Encoding failed"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        selector.close()
        process.stdout.close()
        process.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", required=True, type=Path)
    args = parser.parse_args()
    ffmpeg, ffprobe = (args.bin_dir / name for name in ("ffmpeg", "ffprobe"))
    with tempfile.TemporaryDirectory(prefix="wallpaper-bundled-ffmpeg-") as temporary:
        directory = Path(temporary)
        source, target, cancelled = (directory / name for name in
                                     ("源 ' sample.mkv", "输出 ' sample.mp4", "cancelled.mp4"))
        subprocess.run([str(ffmpeg), "-nostdin", "-v", "error", "-n", "-f", "lavfi", "-i",
                        "testsrc2=size=320x180:rate=24", "-f", "lavfi", "-i",
                        "sine=frequency=880:sample_rate=48000", "-t", "4",
                        "-c:v", "mpeg4", "-c:a", "pcm_s16le", str(source)],
                       check=True, timeout=20)
        original = hashlib.sha256(source.read_bytes()).hexdigest()
        transcode(ffmpeg, source, target, False)
        result = subprocess.run([str(ffprobe), "-v", "error", "-protocol_whitelist", "file",
                                 "-show_streams", "-show_format", "-of", "json", str(target)],
                                check=True, capture_output=True, text=True, timeout=10)
        metadata = json.loads(result.stdout)
        assert [stream["codec_name"] for stream in metadata["streams"]] == ["h264", "aac"]
        assert (metadata["streams"][0]["width"], metadata["streams"][0]["height"]) == (320, 180)
        assert float(metadata["format"]["duration"]) >= 3.9
        print(json.dumps(metadata), flush=True)
        transcode(ffmpeg, source, cancelled, True)
        cancelled.unlink(missing_ok=True)
        assert hashlib.sha256(source.read_bytes()).hexdigest() == original
        assert target.is_file() and not cancelled.exists()
        print("PASS: hardware-required H.264/AAC, progress, SIGTERM, source unchanged, probe cleanup")


if __name__ == "__main__":
    main()
