#!/usr/bin/env python3
"""Compile and run the real local-resource boundary tests; 60-second timeout, no fallback."""
import pathlib
import subprocess
import sys
import time
import uuid

root = pathlib.Path(__file__).resolve().parent.parent
deadline = time.monotonic() + 60


def remaining(command):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise subprocess.TimeoutExpired(command, 60)
    return seconds


output = root / ".build/verification/cef-source-files" / str(uuid.uuid4())
output.mkdir(parents=True)
binary = output / "project-files-test"
command = ["clang++", "-std=c++20", "-mmacosx-version-min=14.0", "-frtti", "-Wall", "-Wextra", "-Werror",
           "-I", str(root / "Sources/WebWallpaperBridge"),
           str(root / "Tests/CEFSourceHarness/project-files.cpp"),
           str(root / "Sources/WebWallpaperBridge/LocalProjectFiles.cpp"), "-o", str(binary)]
print(f"PROJECT_FILES artifacts={output}", flush=True)
try:
    subprocess.run(command, cwd=root, check=True, timeout=remaining(command))
    execution = [str(binary), str(output)]
    subprocess.run(execution, cwd=root, check=True, timeout=remaining(execution))
except subprocess.TimeoutExpired as error:
    print(f"ERROR: project file test exceeded its 60-second overall budget: {error.cmd}", file=sys.stderr)
    sys.exit(124)
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
