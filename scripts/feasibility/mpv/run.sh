#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
dep=.build/dependencies/mpv
python3 scripts/feasibility/mpv/fetch.py
mkdir -p "$dep/runtime-lib" "$dep/fixtures"
# Preserve the hashed upstream bytes; sign only the disposable runtime copies.
for library in "$dep"/lib/*.dylib; do
  runtime="$dep/runtime-lib/$(basename "$library")"
  cp -f "$library" "$runtime"
  codesign --force --sign - "$runtime"
  codesign --verify --strict "$runtime"
done
if [[ ! -f "$dep/fixtures/h264-aac.mkv" || ! -f "$dep/fixtures/vp9-opus.webm" || ! -f "$dep/fixtures/mpeg4-mp3.avi" ]]; then
  bash scripts/feasibility/mpv/fixtures.sh
fi
clang -fobjc-arc -mmacosx-version-min=14.0 -I "$dep/include" \
  scripts/feasibility/mpv/probe.m "$dep/lib/libmpv.2.dylib" \
  -framework AppKit -Wl,-rpath,@executable_path/runtime-lib -o "$dep/probe"
{
  sw_vers
  for media in h264-aac.mkv vp9-opus.webm mpeg4-mp3.avi; do
    printf 'fixture=%s\n' "$media"
    "$dep/probe" "$dep/fixtures/$media" "$dep/first-$media.png"
  done
} 2>&1 | tee "$dep/probe-results.log"
