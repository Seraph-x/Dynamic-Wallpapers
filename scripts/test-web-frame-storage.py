#!/usr/bin/env python3
"""Validate actual damage-copy storage under address/undefined-behavior sanitizers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='web-frame-storage-') as directory:
    output = Path(directory) / 'frame-storage'
    subprocess.run(['clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
        '-I', str(root / 'Sources/WebWallpaperBridge'),
        str(root / 'Tests/WebRuntimeHarness/frame-storage.cpp'), '-o', str(output)], check=True, timeout=60)
    subprocess.run([str(output)], check=True, timeout=60)
