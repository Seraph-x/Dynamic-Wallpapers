#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mode=${1:-native}
capture_scope=${2:-application}
case "$capture_scope" in application|system|exclude-others) ;; *) echo 'capture scope must be application|system|exclude-others' >&2; exit 2;; esac
capture_args=()
if [[ "$capture_scope" == system ]]; then capture_args+=(--system-audio); fi
if [[ "$capture_scope" == exclude-others ]]; then capture_args+=(--exclude-other-apps); fi
case "$mode" in native|direct) ;; *) echo 'usage: run-capture.sh native|direct' >&2; exit 2;; esac
run_root=$(mktemp -d "$PWD/.build/dependencies/cef/capture-$mode-XXXXXXXX")
mkdir "$run_root/context"
echo "RUN_ROOT=$run_root"
export CEF_CAPTURE_READY_PATH="$run_root/capture-ready"
if [[ "$mode" == direct ]]; then
  export CEF_PROBE_DIRECT_CONTROL=1
else
  unset CEF_PROBE_DIRECT_CONTROL
fi
.build/dependencies/cef/CEFProbe.app/Contents/MacOS/CEFProbe \
  "file://$PWD/scripts/feasibility/cef/fixture.html" "$run_root/context" >"$run_root/probe.log" 2>&1 &
probe_pid=$!
# Capture polls for the marker; the browser waits for the first audio sample.
capture_status=0
.build/dependencies/cef/capture "${capture_args[@]}" >"$run_root/capture.log" 2>&1 || capture_status=$?
probe_status=0
wait "$probe_pid" || probe_status=$?
printf '{"probe_exit":%d,"capture_exit":%d}\n' "$probe_status" "$capture_status" >"$run_root/result.json"
echo "probe_exit=$probe_status capture_exit=$capture_status"
[[ "$probe_status" == 0 && "$capture_status" == 0 ]]
