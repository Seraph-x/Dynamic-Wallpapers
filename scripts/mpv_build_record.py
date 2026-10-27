"""Bind a controlled libmpv closure to checked source, recipes and toolchain."""
import json
from pathlib import Path
import re

from media_bundle_macho import inspect_image, is_system_path, validate_target
from mpv_source_inputs import sha256, source_file, unique_pairs


def verify_codesign(path):
    import subprocess
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def inspect_products(output, lock, *, environment, inspect=inspect_image,
                     verify_signature=verify_codesign):
    output = Path(output)
    runtime = output / 'runtime-lib'
    if runtime.is_symlink() or not runtime.is_dir():
        raise ValueError('Controlled mpv runtime directory is missing or symlinked')
    names = set(lock['libraries'])
    if {path.name for path in runtime.iterdir()} != names:
        raise ValueError('Controlled mpv runtime library set differs from source lock')
    libraries = {}
    for name in sorted(names):
        image = source_file(output, f'runtime-lib/{name}')
        architectures, commands = inspect(image)
        validate_target(architectures, commands.minimum_macos,
                        expected_architecture=lock['architecture'],
                        maximum_macos=lock['minimum_macos'])
        if commands.sdk_version != environment['sdk']:
            raise ValueError(f'Controlled mpv SDK mismatch: {name}')
        for reference in commands.dependencies:
            if is_system_path(reference):
                continue
            if not reference.startswith('@rpath/') or reference[7:] not in names:
                raise ValueError(f'Controlled mpv dependency is not closed: {name}: {reference}')
        verify_signature(image)
        libraries[name] = {'sha256': sha256(image), 'architecture': list(architectures),
                           'minimum_macos': commands.minimum_macos, 'sdk': commands.sdk_version,
                           'dependencies': list(commands.dependencies)}
    headers = {name: sha256(source_file(output, f'include/mpv/{name}'))
               for name in ('client.h', 'render.h')}
    return libraries, headers


def write_record(output, lock, *, inputs, environment, inspect=inspect_image,
                 verify_signature=verify_codesign):
    libraries, headers = inspect_products(output, lock, environment=environment,
                                          inspect=inspect, verify_signature=verify_signature)
    document = {'schema_version': 1, 'inputs': inputs, 'environment': environment,
                'libraries': libraries, 'headers': headers}
    destination = Path(output) / 'build-record.json'
    with destination.open('x') as stream:
        json.dump(document, stream, sort_keys=True, indent=2)
        stream.write('\n')
    return document


def verify_record(output, lock, *, inputs, environment, inspect=inspect_image,
                  verify_signature=verify_codesign):
    path = source_file(output, 'build-record.json')
    document = json.loads(path.read_text(), object_pairs_hook=unique_pairs)
    if (type(document) is not dict or type(document.get('schema_version')) is not int
            or document.get('schema_version') != 1
            or set(document) != {'schema_version', 'inputs', 'environment', 'libraries', 'headers'}):
        raise ValueError('Invalid controlled mpv build record schema')
    if document['inputs'] != inputs:
        raise ValueError('Controlled mpv build record source/recipe inputs changed')
    if document['environment'] != environment:
        raise ValueError('Controlled mpv build record toolchain environment changed')
    libraries, headers = inspect_products(output, lock, environment=environment,
                                          inspect=inspect, verify_signature=verify_signature)
    if document['libraries'] != libraries or document['headers'] != headers:
        raise ValueError('Controlled mpv build record product SHA256 or Mach-O metadata changed')
    return document
