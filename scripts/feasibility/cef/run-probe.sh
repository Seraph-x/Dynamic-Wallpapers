#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
context_root=$(mktemp -d "$PWD/.build/dependencies/cef/context-XXXXXXXX")
fixture_url="file://$PWD/scripts/feasibility/cef/fixture.html"
.build/dependencies/cef/CEFProbe.app/Contents/MacOS/CEFProbe \
  "$fixture_url" "$context_root" 2>&1 | tee "$context_root/probe.log"
