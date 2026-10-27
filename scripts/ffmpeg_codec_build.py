"""Build static FFmpeg codec prerequisites from the existing mirrored sources."""
import json
import os
from pathlib import Path
import subprocess
import sys

from media_dependencies import checked_bytes
from mpv_source_inputs import extract_source, load_source_lock, sha256, source_file


COMPONENTS = ('ninja', 'meson', 'dav1d', 'xz')
INPUT_FILES = ('scripts/feasibility/ffmpeg/build.sh', 'scripts/ffmpeg_codec_build.py',
               'scripts/ffmpeg_build_record.py', 'scripts/mpv-source-lock.json',
               'scripts/mpv_source_inputs.py', 'scripts/media_dependencies.py',
               'scripts/media_bundle_macho.py', 'scripts/swift_sdk.py')


def components(root):
    lock = load_source_lock(root)
    selected = {item['name']: item for item in lock['components'] if item['name'] in COMPONENTS}
    if set(selected) != set(COMPONENTS):
        raise ValueError('FFmpeg codec source components are incomplete')
    for item in selected.values():
        checked_bytes(source_file(root, item['artifact']['path']), item['artifact'])
    return selected


def fingerprints(root):
    sources = components(root)
    files = [*INPUT_FILES, *(item['artifact']['path'] for item in sources.values())]
    return {name: sha256(source_file(root, name)) for name in files}


def build_environment():
    commands = {'cmake': ['cmake', '--version'], 'pkg-config': ['pkg-config', '--version'],
                'make': ['/usr/bin/make', '--version']}
    versions = {name: subprocess.check_output(command, text=True).splitlines()[0]
                for name, command in commands.items()}
    versions['python'] = sys.version.splitlines()[0]
    return versions


def environment(prefix, sdk):
    result = dict(os.environ)
    for key in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                'LIBRARY_PATH', 'PKG_CONFIG_PATH', 'PKG_CONFIG_SYSROOT_DIR',
                'CMAKE_PREFIX_PATH', 'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH',
                'SDKROOT', 'CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'PYTHONPATH'):
        result.pop(key, None)
    flags = f'-arch arm64 -isysroot {sdk} -mmacosx-version-min=14.0'
    result.update(CC='/usr/bin/clang', CXX='/usr/bin/clang++', CFLAGS=flags,
                  CXXFLAGS=flags, LDFLAGS=flags, MACOSX_DEPLOYMENT_TARGET='14.0',
                  PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'), LC_ALL='C')
    return result


def cmake_setup(source, build, sdk, *options):
    return ['cmake', '-S', str(source), '-B', str(build), '-G', 'Unix Makefiles',
            '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=OFF',
            '-DCMAKE_C_COMPILER=/usr/bin/clang', '-DCMAKE_CXX_COMPILER=/usr/bin/clang++',
            f'-DCMAKE_OSX_SYSROOT={sdk}', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
            '-DCMAKE_OSX_ARCHITECTURES=arm64', *options]


def build(root, stage, sdk):
    root, stage = Path(root).resolve(), Path(stage).resolve()
    cache = root / '.build/dependencies/ffmpeg'
    if stage.parent != cache or not stage.name.startswith('.build-') or not stage.is_dir():
        raise ValueError('Codec stage must be the actual isolated FFmpeg build directory')
    inputs, tools = fingerprints(root), build_environment()
    selected = components(root)
    sources, builds, prefix = stage / 'codec-sources', stage / 'codec-build', stage / 'install'
    builds.mkdir(); prefix.mkdir()
    env = environment(prefix, sdk)
    env['GIT_CEILING_DIRECTORIES'] = str(stage)
    for name in COMPONENTS:
        extract_source(source_file(root, selected[name]['artifact']['path']), sources / name)
    def run(command):
        print('CODEC BUILD:', ' '.join(map(str, command)), flush=True)
        subprocess.run(command, check=True, env=env)
    run(cmake_setup(sources / 'ninja', builds / 'ninja', sdk))
    run(['cmake', '--build', str(builds / 'ninja'), '--parallel', '8'])
    ninja = builds / 'ninja/ninja'
    meson = [sys.executable, str(sources / 'meson/meson.py')]
    for name, command in [('ninja', [str(ninja), '--version']), ('meson', [*meson, '--version'])]:
        if subprocess.check_output(command, env=env, text=True).strip() != selected[name]['version']:
            raise ValueError(f'Pinned FFmpeg build tool version differs: {name}')
    env['NINJA'] = str(ninja)
    run([*meson, 'setup', str(builds / 'dav1d'), str(sources / 'dav1d'),
         f'--prefix={prefix}', '--libdir=lib', '--buildtype=release',
         '--default-library=static', '--wrap-mode=nodownload', '-Dauto_features=disabled',
         '-Denable_tools=false', '-Denable_tests=false', '-Denable_examples=false',
         '-Denable_docs=false', '-Denable_asm=true'])
    run([*meson, 'compile', '-C', str(builds / 'dav1d'), '-j', '8'])
    run([*meson, 'install', '-C', str(builds / 'dav1d')])
    run(cmake_setup(sources / 'xz', builds / 'xz', sdk,
                    '-DBUILD_SHARED_LIBS=OFF', f'-DCMAKE_INSTALL_PREFIX={prefix}',
                    '-DCMAKE_INSTALL_LIBDIR=lib', '-DXZ_NLS=OFF', '-DXZ_TOOL_XZ=OFF',
                    '-DXZ_TOOL_XZDEC=OFF', '-DXZ_TOOL_LZMADEC=OFF', '-DXZ_TOOL_LZMAINFO=OFF',
                    '-DXZ_TOOL_SCRIPTS=OFF', '-DXZ_DOC=OFF', '-DXZ_DOXYGEN=OFF'))
    run(['cmake', '--build', str(builds / 'xz'), '--parallel', '8'])
    run(['cmake', '--install', str(builds / 'xz')])
    if inputs != fingerprints(root) or tools != build_environment():
        raise ValueError('FFmpeg codec build inputs or tools changed during the build')
    (stage / 'codec-inputs.json').write_text(json.dumps({'inputs': inputs, 'tools': tools}, indent=2) + '\n')


if __name__ == '__main__':
    build(Path(__file__).resolve().parent.parent, Path(sys.argv[1]), Path(sys.argv[2]))
