#!/usr/bin/env python3
"""Remove nonvisual ICNS/PNG metadata while preserving encoded image payloads."""

import argparse
from pathlib import Path
import struct
import sys
import zlib


PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
IMAGE_CHUNKS = frozenset({b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS',
                          b'sRGB', b'gAMA', b'cHRM', b'pHYs'})
REMOVED_METADATA = frozenset({b'eXIf', b'tEXt', b'zTXt', b'iTXt'})
LEGACY_ICNS_IMAGES = frozenset({b'ic04', b'ic05'})


def sanitize_png(data):
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError('Invalid PNG signature in ICNS image')
    result = bytearray(PNG_SIGNATURE)
    offset = len(PNG_SIGNATURE)
    seen = set()
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError('Truncated PNG chunk in ICNS image')
        length = struct.unpack_from('>I', data, offset)[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError('Truncated PNG payload in ICNS image')
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack_from('>I', data, end - 4)[0]
        if zlib.crc32(kind + payload) != expected_crc:
            raise ValueError('Invalid PNG CRC in ICNS image')
        if kind not in IMAGE_CHUNKS | REMOVED_METADATA:
            raise ValueError(f'Unreviewed PNG chunk in ICNS image: {kind!r}')
        if kind in IMAGE_CHUNKS:
            result.extend(data[offset:end])
        seen.add(kind)
        offset = end
        if kind == b'IEND':
            break
    if offset != len(data) or not {b'IHDR', b'IDAT', b'IEND'} <= seen:
        raise ValueError('Incomplete PNG image in ICNS container')
    return bytes(result)


def sanitize_icns(data):
    if len(data) < 8 or data[:4] != b'icns' or struct.unpack_from('>I', data, 4)[0] != len(data):
        raise ValueError('Invalid ICNS container size or signature')
    result = bytearray()
    offset = 8
    images = 0
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError('Truncated ICNS chunk')
        kind = data[offset:offset + 4]
        length = struct.unpack_from('>I', data, offset + 4)[0]
        end = offset + length
        if length < 8 or end > len(data):
            raise ValueError('Invalid ICNS chunk size')
        payload = data[offset + 8:end]
        if kind == b'info':
            offset = end
            continue
        if payload.startswith(PNG_SIGNATURE):
            payload = sanitize_png(payload)
        elif kind not in LEGACY_ICNS_IMAGES:
            raise ValueError(f'Unreviewed ICNS image chunk: {kind!r}')
        result.extend(kind + struct.pack('>I', len(payload) + 8) + payload)
        images += 1
        offset = end
    if offset != len(data) or not images:
        raise ValueError('ICNS container has no valid image')
    return b'icns' + struct.pack('>I', len(result) + 8) + result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path, help='new file; existing files are not replaced')
    options = parser.parse_args()
    clean = sanitize_icns(options.source.read_bytes())
    with options.output.open('xb') as stream:
        stream.write(clean)
    print(f'Sanitized ICNS metadata; retained {len(clean)} bytes of image container')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print(f'ICON SANITIZATION FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
