#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p .build/dependencies/cef
flags=(-std=c++20 -Wall -Wextra -Werror -pthread)
if [[ -n "${AUDIO_RING_SANITIZER:-}" ]]; then
  flags+=("-fsanitize=${AUDIO_RING_SANITIZER}")
fi
c++ "${flags[@]}" \
  scripts/feasibility/cef/timed-audio-ring-tests.cpp -o .build/dependencies/cef/timed-audio-ring-tests
python3 - <<'PY'
import subprocess
try:
    result = subprocess.run(['.build/dependencies/cef/timed-audio-ring-tests'], timeout=60)
except subprocess.TimeoutExpired:
    raise SystemExit('ERROR: timed audio ring tests exceeded 60 seconds')
raise SystemExit(result.returncode)
PY
