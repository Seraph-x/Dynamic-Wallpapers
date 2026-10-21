#!/usr/bin/env python3
"""Metadata stripping keeps icon image payload bytes unchanged."""

import importlib.util
from pathlib import Path
import struct
import unittest
import zlib


SCRIPT = Path(__file__).with_name('sanitize-app-icon.py')


def load_module():
    spec = importlib.util.spec_from_file_location('sanitize_app_icon', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def png_chunk(kind, content):
    return struct.pack('>I', len(content)) + kind + content + struct.pack(
        '>I', zlib.crc32(kind + content))


def icon_chunk(kind, content):
    return kind + struct.pack('>I', len(content) + 8) + content


class SanitizeAppIconTests(unittest.TestCase):
    def test_removes_metadata_without_changing_pixel_payload(self):
        module = load_module()
        pixels = b'compressed pixel data with accidental email-like text'
        png = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', b'header')
               + png_chunk(b'eXIf', b'artist-private-metadata')
               + png_chunk(b'IDAT', pixels) + png_chunk(b'IEND', b''))
        icon = b'icns' + struct.pack('>I', 8 + len(icon_chunk(b'ic10', png))
                                    + len(icon_chunk(b'info', b'author metadata')))
        icon += icon_chunk(b'ic10', png) + icon_chunk(b'info', b'author metadata')
        clean = module.sanitize_icns(icon)
        self.assertEqual(struct.unpack_from('>I', clean, 4)[0], len(clean))
        self.assertNotIn(b'eXIf', clean)
        self.assertNotIn(b'author metadata', clean)
        self.assertIn(png_chunk(b'IDAT', pixels), clean)

    def test_invalid_container_or_png_crc_is_rejected(self):
        module = load_module()
        with self.assertRaisesRegex(ValueError, 'ICNS'):
            module.sanitize_icns(b'icns\x00\x00\x00\x80short')
        broken = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IDAT', b'pixels')[:-1] + b'X'
        icon = b'icns' + struct.pack('>I', 8 + len(icon_chunk(b'ic10', broken)))
        with self.assertRaisesRegex(ValueError, 'PNG'):
            module.sanitize_icns(icon + icon_chunk(b'ic10', broken))


if __name__ == '__main__':
    unittest.main()
