#!/usr/bin/env python3
"""Short real-process probe; explicit binary paths, isolated files, no product fallback."""
import argparse
import json
import pathlib
import selectors
import subprocess
import tempfile
import time


def encode(ffmpeg, source, target, cancel):
    command = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-n",
               "-stats_period", "0.1", "-progress", "pipe:1", "-re",
               "-protocol_whitelist", "file", "-i", str(source),
               "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264",
               "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", str(target)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "progress")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    buffers = {"progress": bytearray(), "stderr": bytearray()}
    cancelled = False
    deadline = time.monotonic() + 15
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise TimeoutError("FFmpeg progress/cancellation probe exceeded 15 seconds")
            for key, _ in selector.select(0.1):
                data = key.fileobj.read1(65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                buffers[key.data].extend(data)
            # Wait for actual encoded media time, not just a process-start notification.
            times = [int(line.split(b"=", 1)[1]) for line in buffers["progress"].splitlines()
                     if line.startswith(b"out_time_us=") and line.split(b"=", 1)[1].isdigit()]
            if cancel and not cancelled and any(value > 0 for value in times):
                process.terminate()
                cancelled = True
        status = process.wait(timeout=2)
        progress = buffers["progress"].decode()
        diagnostic = buffers["stderr"].decode()
        print(json.dumps({"cancelRequested": cancel, "terminated": cancelled,
                          "exitCode": status, "progress": progress, "stderr": diagnostic}))
        assert any(value > 0 for value in times), "No real media progress received"
        if cancel:
            assert cancelled and status != 0, "Cancellation did not terminate encoding"
        else:
            assert status == 0 and "progress=end" in progress, "Encoding failed"
        return status
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        selector.close()
        process.stdout.close()
        process.stderr.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="dynamicwallpaper-ffmpeg-") as directory:
        source = pathlib.Path(directory) / "source ' 中文.mkv"
        target = pathlib.Path(directory) / "output ' 中文.mp4"
        cancelled = pathlib.Path(directory) / "cancelled.mp4"
        subprocess.run([args.ffmpeg, "-nostdin", "-v", "error", "-n", "-f", "lavfi", "-i",
                        "testsrc2=size=320x180:rate=24", "-f", "lavfi", "-i",
                        "sine=frequency=880:sample_rate=48000", "-t", "2", "-c:v", "libx264",
                        "-c:a", "aac", str(source)], check=True, timeout=15)
        encode(args.ffmpeg, source, target, False)
        result = subprocess.run([args.ffprobe, "-v", "error", "-protocol_whitelist", "file",
                                 "-show_streams", "-show_format", "-of", "json", str(target)],
                                check=True, capture_output=True, text=True, timeout=10)
        metadata = json.loads(result.stdout)
        assert [s["codec_name"] for s in metadata["streams"]] == ["h264", "aac"]
        assert metadata["streams"][0]["width"] == 320
        assert metadata["streams"][0]["height"] == 180
        print(json.dumps({"outputCodecs": [s["codec_name"] for s in metadata["streams"]],
                          "duration": metadata["format"]["duration"]}))
        encode(args.ffmpeg, source, cancelled, True)
        cancelled.unlink(missing_ok=True)
        assert source.is_file() and target.is_file() and not cancelled.exists()
        print("PASS: real progress, H.264/AAC output, SIGTERM exit and probe-owned cleanup")


if __name__ == "__main__":
    main()
