#!/usr/bin/env python3
"""Exercise product frame storage and Foundation provider ownership under sanitizers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
runtime = root / '.build/media-source-complete/mpv'
with tempfile.TemporaryDirectory(prefix='mpv-frame-pool-') as directory:
    output = Path(directory) / 'frame-pool'
    subprocess.run(['clang++', '-std=c++14', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-mmacosx-version-min=14.0',
        '-I', str(runtime / 'include'), '-I', str(root / 'Sources/MPVBridge/include'),
        str(root / 'Tests/MPVBridgeHarness/frame-pool.mm'), str(runtime / 'runtime-lib/libmpv.2.dylib'),
        '-framework', 'AppKit', '-Wl,-rpath,' + str(runtime / 'runtime-lib'), '-o', str(output)],
        check=True, timeout=60)
    subprocess.run([str(output)], check=True, timeout=60)
