"""Verify the retained third-party notices against their explicit manifest."""
import json
from pathlib import Path, PurePosixPath
import re

from media_bundle_macho import inside, sha256


def verify_distribution_materials(directory):
    directory = Path(directory)
    status = json.loads((directory / 'distribution-status.json').read_text())
    if (status.get('schema_version') != 1 or type(status.get('complete')) is not bool
            or not isinstance(status.get('files'), list) or not status['files']):
        raise ValueError('Invalid distribution material manifest; notice files are required')
    components = status.get('components')
    if not isinstance(components, dict) or set(components) != {'cef', 'mpv', 'ffmpeg', 'webwallgl', 'mediabunny', 'wescene'}:
        raise ValueError('Distribution material manifest must describe CEF, mpv, FFmpeg, WebWallGL, Mediabunny and WeScene')
    declared = set()
    for entry in status['files']:
        relative = entry.get('path', '')
        path = PurePosixPath(relative)
        if (not relative or path.is_absolute() or any(part in ('.', '..') for part in path.parts)
                or relative in declared or relative == 'distribution-status.json'):
            raise ValueError(f'Invalid or duplicate material path: {relative}')
        if not re.fullmatch(r'[a-f0-9]{64}', entry.get('sha256', '')):
            raise ValueError(f'Invalid material SHA256: {relative}')
        original = directory / relative
        material = inside(original, directory)
        if original.is_symlink() or not material.is_file() or sha256(material) != entry['sha256']:
            raise ValueError(f'Distribution material missing or SHA256 mismatch: {relative}')
        declared.add(relative)
    retained = {str(path.relative_to(directory)) for path in directory.rglob('*')
                if path.is_file() or path.is_symlink()} - {'distribution-status.json'}
    if retained != declared:
        raise ValueError(f'Material manifest does not cover retained files: {retained ^ declared}')
    for name, component in components.items():
        if (not component.get('version') or not component.get('license')
                or type(component.get('complete')) is not bool
                or not component.get('license_files')
                or not set(component['license_files']).issubset(declared)):
            raise ValueError(f'Incomplete distribution material record: {name}')
    if status['complete'] != all(component['complete'] for component in components.values()):
        raise ValueError('Distribution material completeness disagrees with component records')
    return status
