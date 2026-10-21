#!/usr/bin/env python3
"""Run real libmpv error-drain regression; no synthetic render flags or test-side draining."""
from pathlib import Path
import argparse
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bridge-source", type=Path, help="Explicit product-source copy for mutation verification")
arguments = parser.parse_args()
source_flags = [] if arguments.bridge_source is None else [
    '-DDW_MPV_BRIDGE_IMPLEMENTATION="' + str(arguments.bridge_source.resolve()) + '"'
]
dependency = root / ".build/dependencies/mpv"
output = root / ".build/verification/mpv-pending-frame-harness"
output.parent.mkdir(parents=True, exist_ok=True)
try:
    subprocess.run([
        "clang++", "-std=c++17", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
        "-mmacosx-version-min=14.0", "-I", str(dependency / "include"),
        "-I", str(root / "Sources/MPVBridge/include"),
        *source_flags, str(root / "Tests/MPVBridgeHarness/pending-frame.mm"),
        str(dependency / "runtime-lib/libmpv.2.dylib"), "-framework", "AppKit",
        "-Wl,-rpath," + str(dependency / "runtime-lib"), "-o", str(output)
    ], check=True, timeout=60)
    result = subprocess.run([str(output), str(dependency / "fixtures/h264-aac.mkv")], timeout=60)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print("ERROR: pending-frame regression exceeded 60 seconds", file=sys.stderr)
    sys.exit(124)
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
