"""Static Mach-O closure checks for the actual local application bundle."""
from dataclasses import dataclass
import hashlib
from pathlib import Path
import posixpath
import re
import struct
import subprocess

MACHO_MAGICS = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
LOAD_COMMANDS = {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB',
                 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'}


def run(command):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    return subprocess.check_output(list(map(str, command)), text=True, stderr=subprocess.STDOUT)


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


@dataclass(frozen=True)
class LoadCommands:
    dependencies: tuple[str, ...]
    rpaths: tuple[str, ...]
    minimum_macos: str
    sdk_version: str | None


def parse_load_commands(text):
    dependencies, rpaths, minimum, sdk = [], [], None, None
    for block in re.split(r'Load command \d+\n', text)[1:]:
        match = re.search(r'^\s*cmd (LC_\w+)\s*$', block, re.MULTILINE)
        if not match:
            raise ValueError('Malformed Mach-O load command')
        command = match[1]
        if command in LOAD_COMMANDS or command == 'LC_RPATH':
            field = 'path' if command == 'LC_RPATH' else 'name'
            value = re.search(r'^\s*' + field + r' (.+) \(offset \d+\)\s*$', block, re.MULTILINE)
            if not value:
                raise ValueError(f'Missing {field} in {command}')
            (rpaths if command == 'LC_RPATH' else dependencies).append(value[1])
        if command == 'LC_BUILD_VERSION':
            platform = re.search(r'^\s*platform (\S+)\s*$', block, re.MULTILINE)
            if not platform or platform[1] not in ('1', 'MACOS'):
                raise ValueError('Mach-O platform is not macOS')
            value = re.search(r'^\s*minos (\d+(?:\.\d+){1,2})\s*$', block, re.MULTILINE)
            minimum = value[1] if value else None
        if command == 'LC_VERSION_MIN_MACOSX':
            value = re.search(r'^\s*version (\d+(?:\.\d+){1,2})\s*$', block, re.MULTILINE)
            minimum = value[1] if value else None
        if command in {'LC_BUILD_VERSION', 'LC_VERSION_MIN_MACOSX'}:
            value = re.search(r'^\s*sdk (\d+(?:\.\d+){1,2})\s*$', block, re.MULTILINE)
            sdk = value[1] if value else None
    if minimum is None:
        raise ValueError('Missing macOS deployment target')
    return LoadCommands(tuple(dependencies), tuple(rpaths), minimum, sdk)


def validate_target(architectures, minimum, *, expected_architecture, maximum_macos):
    if tuple(architectures) != (expected_architecture,):
        raise ValueError(
            f'Expected {expected_architecture}-only Mach-O, got {architectures}')
    version = tuple((list(map(int, minimum.split('.'))) + [0, 0])[:3])
    maximum = tuple((list(map(int, maximum_macos.split('.'))) + [0, 0])[:3])
    if version > maximum:
        raise ValueError(
            f'Mach-O requires macOS {minimum}, above target {maximum_macos}')


def is_system_path(value):
    return value == posixpath.normpath(value) and value.startswith(('/usr/lib/', '/System/Library/'))


def inside(path, bundle):
    resolved = path.resolve()
    if not resolved.is_relative_to(bundle.resolve()):
        raise ValueError(f'Bundle path escapes application: {path}')
    return resolved


def expand_path(value, *, image, executable, bundle):
    for prefix, base in (('@loader_path', image.parent), ('@executable_path', executable.parent)):
        if value == prefix or value.startswith(prefix + '/'):
            return inside(base / value[len(prefix):].lstrip('/'), bundle)
    raise ValueError(f'Unsupported non-system load path: {value}')


def resolve_reference(value, *, image, executable, bundle, rpaths):
    if is_system_path(value):
        return None  # OS shared-cache entries need not be loose files on disk.
    if value.startswith('@rpath/'):
        candidates = set()
        for rpath in rpaths:
            if is_system_path(rpath):
                continue
            base = expand_path(rpath, image=image, executable=executable, bundle=bundle)
            candidate = inside(base / value.removeprefix('@rpath/'), bundle)
            if candidate.is_file():
                candidates.add(candidate)
        if len(candidates) != 1:
            raise ValueError(f'Unresolved or ambiguous bundle dependency {image}: {value}: {candidates}')
        return candidates.pop()
    candidate = expand_path(value, image=image, executable=executable, bundle=bundle)
    if not candidate.is_file():
        raise ValueError(f'Missing dependency: {candidate}')
    return candidate


def rpath_rewrite_commands(path, rpaths, *, required=()):
    commands = []
    for value in dict.fromkeys(rpaths):
        if value.startswith('/') and not is_system_path(value):
            commands.append(['install_name_tool', '-delete_rpath', value, str(path)])
    for value in required:
        if value not in rpaths:
            commands.append(['install_name_tool', '-add_rpath', value, str(path)])
    return commands


def macho_files(bundle):
    files = []
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            target = inside(path, bundle)
            if not target.exists():
                raise ValueError(f'Dangling bundle symlink: {path}')
        elif path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGICS:
                    files.append(path)
    return files


def inspect_image(path):
    architecture = tuple(run(['lipo', '-archs', path]).split())
    # CEF names such as "Helper (Renderer)" are filenames, not archive members.
    commands = parse_load_commands(run(['otool', '-m', '-l', path]))
    return architecture, commands


def rewrite_bundle_rpaths(bundle, *, product_target, main_executable):
    main = bundle / 'Contents/MacOS' / main_executable
    for image in macho_files(bundle):
        architecture, commands = inspect_image(image)
        validate_target(
            architecture, commands.minimum_macos,
            expected_architecture=product_target.architecture,
            maximum_macos=product_target.minimum_macos)
        required = ('@executable_path/../Frameworks/MPV',) if image == main else ()
        if image.parent == bundle / 'Contents/Frameworks/MPV':
            required = ('@loader_path',)
        for command in rpath_rewrite_commands(image, commands.rpaths, required=required):
            run(command)


def sign_bundle(bundle):
    for image in macho_files(bundle):
        run(['codesign', '--force', '--sign', '-', image])
    containers = [path for path in bundle.rglob('*') if not path.is_symlink()
                  and path.is_dir() and path.suffix in ('.framework', '.app', '.saver')]
    for container in sorted(containers, key=lambda path: len(path.parts), reverse=True) + [bundle]:
        run(['codesign', '--force', '--sign', '-', container])
        run(['codesign', '--verify', '--deep', '--strict', container])


def nearest_executable(image, bundle):
    import plistlib
    with image.open('rb') as stream:
        header = stream.read(16)
        fat_formats = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
                       b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
        if header[:4] in fat_formats:
            endian, wide = fat_formats[header[:4]]
            stream.seek(16)  # First fat_arch offset; target validation requires one arm64 slice.
            offset = struct.unpack(endian + ('Q' if wide else 'I'), stream.read(8 if wide else 4))[0]
            stream.seek(offset)
            header = stream.read(16)
        endianness = {b'\xce\xfa\xed\xfe': '<', b'\xcf\xfa\xed\xfe': '<',
                      b'\xfe\xed\xfa\xce': '>', b'\xfe\xed\xfa\xcf': '>'}
        if len(header) != 16 or header[:4] not in endianness:
            raise ValueError(f'Invalid Mach-O header: {image}')
        if struct.unpack(endianness[header[:4]] + 'I', header[12:16])[0] == 2:  # MH_EXECUTE
            return inside(image, bundle)
    for parent in image.parents:
        if parent.suffix in ('.app', '.saver'):
            info = plistlib.loads((parent / 'Contents/Info.plist').read_bytes())
            return inside(parent / 'Contents/MacOS' / info['CFBundleExecutable'], bundle)
    raise ValueError(f'No owning app for {image}')


def verify_macho_closure(bundle, *, product_target):
    files = macho_files(bundle)
    if not files:
        raise ValueError('No Mach-O executables in application')
    images = {}
    for path in files:
        architecture, commands = inspect_image(path)
        validate_target(
            architecture, commands.minimum_macos,
            expected_architecture=product_target.architecture,
            maximum_macos=product_target.minimum_macos)
        images[path.resolve()] = (architecture, commands)
    records = []
    for path, (architecture, commands) in images.items():
        executable = nearest_executable(path, bundle)
        if executable not in images:
            raise ValueError(f'Missing owning executable: {executable}')
        for rpath in commands.rpaths:
            if not is_system_path(rpath):
                expand_path(rpath, image=path, executable=executable, bundle=bundle)
        # Dylibs receive the executable's run-path stack in addition to their own.
        inherited = []
        for rpath in images[executable][1].rpaths:
            if not is_system_path(rpath):
                inherited.append(expand_path(rpath, image=executable, executable=executable, bundle=bundle))
        rpaths = tuple(commands.rpaths) + tuple('@loader_path/' + posixpath.relpath(p, path.parent) for p in inherited)
        dependencies = []
        for reference in commands.dependencies:
            resolved = resolve_reference(reference, image=path, executable=executable, bundle=bundle, rpaths=rpaths)
            if resolved is not None and resolved not in images:
                raise ValueError(f'Dependency is not a verified Mach-O: {resolved}')
            dependencies.append({'reference': reference, 'resolved': str(resolved.relative_to(bundle.resolve())) if resolved else 'system'})
        run(['codesign', '--verify', '--strict', path])
        records.append({'path': str(path.relative_to(bundle.resolve())), 'sha256': sha256(path),
                        'architecture': architecture, 'minimum_macos': commands.minimum_macos,
                        'sdk_version': commands.sdk_version,
                        'rpaths': commands.rpaths, 'dependencies': dependencies})
    run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', bundle])
    return records
