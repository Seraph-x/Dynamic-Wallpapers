"""Fetch IINA's versioned arm64 library set and audit every Mach-O dependency."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DEST = ROOT / '.build/dependencies/mpv'
BASE = 'https://iina.io/dylibs/1.4.0/arm64'
CURL = os.environ.get('MPV_FETCH_CURL', 'curl')
LOCK = json.loads(Path(__file__).with_name('libraries.json').read_text())
HASHES = {entry['file']: entry['sha256'] for entry in LOCK}
HEADERS = {
    'client.h': 'c34c436b54201ba84655dcbb6226f937b53d04fa0abcceaa08886565a569bd88',
    'render.h': 'f00a31d46896c691922196c932c94140d206cb4c16cfa4bb6bdf3a9d0d3d4a29',
}

def fetch_checked(path, url, digest):
    if not path.exists():
        partial = path.with_suffix('.download')
        subprocess.run([CURL, '--http1.1', '-fLsS', '--max-time', '180', url, '-o', str(partial)], check=True)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != digest:
            raise ValueError(f'Download SHA256 mismatch: {path.name}')
        partial.rename(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError(f'Cache SHA256 mismatch: {path.name}')
    return path

def download(name):
    return fetch_checked(DEST / 'lib' / name, f'{BASE}/{name}', HASHES[name])

def main():
    (DEST / 'lib').mkdir(parents=True, exist_ok=True)
    (DEST / 'include/mpv').mkdir(parents=True, exist_ok=True)
    for name, digest in HEADERS.items():
        fetch_checked(DEST / 'include/mpv' / name,
                      f'https://raw.githubusercontent.com/mpv-player/mpv/v0.38.0/libmpv/{name}', digest)
    names = list(HASHES)
    if any(not re.fullmatch(r'[A-Za-z0-9_.+-]+\.dylib', n) for n in names):
        raise ValueError('Invalid upstream library name')
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        paths = list(pool.map(download, names))
    report = []
    for path in paths:
        build = subprocess.check_output(['vtool', '-show-build', str(path)], text=True)
        arch = subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip()
        deps = subprocess.check_output(['otool', '-L', str(path)], text=True)
        minimum = re.search(r'minos\s+(\S+)', build)
        if not minimum:
            legacy = subprocess.check_output(['otool', '-l', str(path)], text=True)
            minimum = re.search(r'LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+(\S+)', legacy)
        if not minimum or tuple((list(map(int, minimum[1].split('.'))) + [0, 0])[:3]) > (14, 0, 0):
            raise ValueError(f'Unsupported minimum OS: {path.name}: {build}')
        if 'arm64' not in arch:
            raise ValueError(f'Unsupported architecture: {path.name}: {arch}')
        references = [line.strip().split(' (')[0] for line in deps.splitlines()[1:]]
        for ref in references:
            if ref.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if not ref.startswith('@rpath/') or ref.removeprefix('@rpath/') not in names:
                raise ValueError(f'Unresolved dependency: {path.name} -> {ref}')
        report.append(dict(file=path.name, url=f'{BASE}/{path.name}', sha256=hashlib.sha256(path.read_bytes()).hexdigest(), architecture=arch, minimum_macos=minimum[1], dependencies=references))
    (DEST / 'audit.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Audited {len(report)} libraries; arm64, minimum macOS <=14, complete @rpath closure')

if __name__ == '__main__':
    main()
