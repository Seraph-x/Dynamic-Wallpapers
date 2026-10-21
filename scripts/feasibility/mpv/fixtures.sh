#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
dep=.build/dependencies/mpv
mkdir -p "$dep/fixtures"
ffmpeg_bin="${FFMPEG:-ffmpeg}"
"$ffmpeg_bin" -version > "$dep/fixture-generator-version.txt"
generate() {
  local name="$1" video="$2" audio="$3"
  [[ -f "$dep/fixtures/$name" ]] && return 0
  "$ffmpeg_bin" -nostdin -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=320x180:rate=24' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
    -t 2 -c:v "$video" -pix_fmt yuv420p -c:a "$audio" "$dep/fixtures/$name"
}
generate h264-aac.mkv libx264 aac
generate vp9-opus.webm libvpx-vp9 libopus
generate mpeg4-mp3.avi mpeg4 libmp3lame
