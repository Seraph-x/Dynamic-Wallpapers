"""Build the pinned libmpv dependency closure without Homebrew runtime inputs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import mpv_build_record
from mpv_source_inputs import (extract_source, load_source_lock, sha256,
                               unique_pairs, verify_sources)
from swift_sdk import selected_sdk, sdk_version


BUILD_ROOT = Path('.build/media-source-complete')
OUTPUT_RELATIVE = BUILD_ROOT / 'mpv'
INPUT_FILES = ('scripts/mpv-source-lock.json', 'scripts/mpv-source-recipes.json',
               'scripts/build-mpv-source.py', 'scripts/mpv_source_build.py',
               'scripts/mpv_source_inputs.py', 'scripts/mpv_build_record.py',
               'scripts/media_dependencies.py', 'scripts/media_bundle_macho.py',
               'scripts/swift_sdk.py', 'scripts/media_bundle.py')


def load_recipes(root):
    document = json.loads((Path(root) / 'scripts/mpv-source-recipes.json').read_text(),
                          object_pairs_hook=unique_pairs)
    if document.get('schema_version') != 1:
        raise ValueError('Unsupported controlled mpv recipe schema')
    for name, recipe in document.items():
        if not isinstance(recipe, dict) or 'meson_options' not in recipe:
            continue
        recipe['commands'] = [
            ['{python}', '{meson}', 'setup', '{build}', '{source}',
             '--prefix={prefix}', '--libdir=lib', '--buildtype=release',
             '--default-library=shared', '--wrap-mode=nodownload',
             '-Dauto_features=disabled', *recipe['meson_options']],
            ['{python}', '{meson}', 'compile', '-C', '{build}', '-j', '{jobs}'],
            ['{python}', '{meson}', 'install', '-C', '{build}'],
        ]
    return document


def tool_environment(sdk, lock):
    commands = {'clang': ['/usr/bin/clang', '--version'],
                'cmake': ['cmake', '--version'], 'pkg-config': ['pkg-config', '--version'],
                'make': ['/usr/bin/make', '--version']}
    result = {name: subprocess.check_output(command, text=True).splitlines()[0]
              for name, command in commands.items()}
    result.update(sdk=sdk_version(sdk), python=sys.version.splitlines()[0])
    result['source_build_tools'] = {component['name']: component['version']
                                    for component in lock['components']
                                    if component['role'] in ('build-tool', 'generator')}
    return result


def build_environment(prefix, sdk, ninja, *, inherited=None):
    environment = dict(os.environ if inherited is None else inherited)
    for key in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                'LIBRARY_PATH', 'PKG_CONFIG_PATH', 'PKG_CONFIG_SYSROOT_DIR',
                'CMAKE_PREFIX_PATH', 'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH',
                'SDKROOT', 'CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS'):
        environment.pop(key, None)
    flags = f'-arch arm64 -isysroot {sdk} -mmacosx-version-min=14.0'
    environment.update(CC='/usr/bin/clang', CXX='/usr/bin/clang++',
                       CFLAGS=flags, CXXFLAGS=flags,
                       LDFLAGS=flags + ' -Wl,-headerpad_max_install_names',
                       MACOSX_DEPLOYMENT_TARGET='14.0',
                       PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'),
                       NINJA=str(ninja), LC_ALL='C')
    return environment


def input_fingerprints(root):
    return {name: sha256(Path(root) / name) for name in INPUT_FILES}


def assert_inputs_unchanged(root, inputs):
    for name, expected in inputs.items():
        if sha256(Path(root) / name) != expected:
            raise ValueError(f'Controlled source/recipe changed during build: {name}')


def verify_built(root):
    root = Path(root)
    lock = load_source_lock(root)
    verify_sources(root, lock)
    return mpv_build_record.verify_record(
        root / OUTPUT_RELATIVE, lock, inputs=input_fingerprints(root),
        environment=tool_environment(selected_sdk(), lock))


def execute_recipe(name, recipe, variables, environment, logs):
    build = Path(variables['build'])
    build.mkdir(parents=True, exist_ok=True)
    for relative, content in recipe.get('source_generated', {}).items():
        path = Path(variables['source']) / relative
        path.write_text(content.format_map(variables))
    for index, template in enumerate(recipe['commands']):
        command = [argument.format_map(variables) for argument in template]
        log_path = logs / f'{name}-{index}.log'
        print(f'BUILD {name} step={index} log={log_path}', flush=True)
        with log_path.open('w') as log:
            log.write(json.dumps(command) + '\n'); log.flush()
            subprocess.run(command, cwd=build, env=environment, check=True,
                           stdout=log, stderr=subprocess.STDOUT)
    for relative, target in recipe.get('copies', {}).items():
        destination = Path(variables['prefix']) / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(variables['source']) / relative, destination)
    for relative, content in recipe.get('generated', {}).items():
        destination = Path(variables['prefix']) / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content.format_map(variables))


def reconstruct_sources(root, lock, stage):
    sources = stage / 'source'
    for component in lock['components']:
        extract_source(Path(root) / component['artifact']['path'], sources / component['name'])
    # The parent archive deliberately omits gitlinks. Restore exact pinned inputs.
    for name, target in (('jinja', 'jinja'), ('markupsafe', 'markupsafe'),
                         ('fast_float', 'fast_float'), ('vulkan_headers', 'Vulkan-Headers')):
        destination = sources / 'libplacebo/3rdparty' / target
        shutil.copytree(sources / name, destination, dirs_exist_ok=True)
    return sources


def stage_products(prefix, product, lock):
    runtime = product / 'runtime-lib'
    runtime.mkdir(parents=True)
    shutil.copytree(prefix / 'include/mpv', product / 'include/mpv')
    for name in lock['libraries']:
        source = prefix / 'lib' / name
        if not source.resolve().is_relative_to(prefix) or not source.is_file():
            raise ValueError(f'Built library missing or escaping prefix: {name}')
        shutil.copyfile(source, runtime / name)
    for name in lock['libraries']:
        image = runtime / name
        text = subprocess.check_output(['otool', '-L', str(image)], text=True)
        references = [line.strip().split(' (', 1)[0] for line in text.splitlines()[1:]]
        command = ['install_name_tool', '-id', '@rpath/' + name]
        for reference in references:
            if reference.startswith(str(prefix / 'lib') + '/'):
                target = Path(reference).name
                if target not in lock['libraries']:
                    raise ValueError(f'Unexpected built dependency: {name}: {reference}')
                command += ['-change', reference, '@rpath/' + target]
        subprocess.run([*command, str(image)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(image)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def build(root):
    root = Path(root).resolve()
    output = root / OUTPUT_RELATIVE
    if output.exists() or output.is_symlink():
        verify_built(root)  # Existing products require a matching record; never rebuild silently.
        print(f'VERIFIED controlled mpv: {output}', flush=True)
        return output
    lock = load_source_lock(root)
    verify_sources(root, lock)
    recipes = load_recipes(root)
    sdk = selected_sdk()
    environment_identity = tool_environment(sdk, lock)
    inputs = input_fingerprints(root)
    base = root / BUILD_ROOT
    base.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='build-', dir=base))
    (stage / 'input-fingerprints.json').write_text(json.dumps(inputs, indent=2) + '\n')
    sources = reconstruct_sources(root, lock, stage)
    prefix = stage / 'prefix'; prefix.mkdir()
    logs = stage / 'logs'; logs.mkdir()
    ninja = stage / 'build/ninja/ninja'
    environment = build_environment(prefix, sdk, ninja)
    environment['GIT_CEILING_DIRECTORIES'] = str(stage)
    environment['PYTHONPATH'] = os.pathsep.join(str(sources / name / 'src')
                                                for name in ('jinja', 'markupsafe'))
    variables = {'prefix': str(prefix), 'sdk': str(sdk), 'python': sys.executable,
                 'meson': str(sources / 'meson/meson.py'), 'cmake': shutil.which('cmake'),
                 'jobs': str(os.cpu_count() or 1)}
    for name in ['ninja', *recipes['order']]:
        variables.update(source=str(sources / name), build=str(stage / 'build' / name))
        execute_recipe(name, recipes[name], variables, environment, logs)
        if name == 'ninja':
            for tool, command in {'ninja': [str(ninja), '--version'],
                                  'meson': [sys.executable, variables['meson'], '--version']}.items():
                actual = subprocess.check_output(command, env=environment, text=True).strip()
                if actual != environment_identity['source_build_tools'][tool]:
                    raise ValueError(f'Pinned build tool version differs: {tool}: {actual}')
    product = stage / 'products'
    stage_products(prefix, product, lock)
    assert_inputs_unchanged(root, inputs)
    verify_sources(root, lock)
    if tool_environment(sdk, lock) != environment_identity:
        raise ValueError('Controlled build toolchain changed during build')
    mpv_build_record.write_record(product, lock, inputs=inputs,
                                  environment=environment_identity)
    from media_bundle import publish_exclusively
    publish_exclusively(product, output)
    verify_built(root)
    print(f'BUILT controlled mpv: {output}; logs={logs}', flush=True)
    return output
