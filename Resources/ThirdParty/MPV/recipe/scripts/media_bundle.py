"""Assemble only new local candidates; never replace an installed application."""
import ctypes
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import tarfile
import tempfile

from media_bundle_macho import (inside, rewrite_bundle_rpaths, run, sha256,
                                sign_bundle, verify_macho_closure)
from media_bundle_materials import verify_distribution_materials
from media_dependencies import load_lock, verify_artifact, mpv_prepared_root
from ffmpeg_build_record import current_build_environment, verify_record
from product_configuration import load as load_product_configuration
from localization_bundle import (prepare_localizations, verify_application_localizations,
                                 bundle_resource_directory, RESOURCE_BUNDLE)
from help_bundle import verify_help_bundle

FRAMEWORK = 'Chromium Embedded Framework.framework'
CONFIG = load_product_configuration()
HELPERS = tuple((helper.suffix, helper.role, helper.bundle_identifier)
                for helper in CONFIG.cef_helpers)


def validate_output(root, output):
    root, output = Path(os.path.abspath(root)), Path(os.path.abspath(output))
    dist = root / 'dist'
    if output.suffix != '.app' or not output.is_relative_to(dist):
        raise ValueError(f'Output must be a new .app under {dist}: {output}')
    for path in [output, *output.parents]:
        if path == root:
            break
        if path.is_symlink():
            raise ValueError(f'Symlinked output parent is not accepted: {path}')
        if path.exists() and not path.is_dir():
            raise ValueError(f'Output parent is not a directory: {path}')
    if output.exists():
        raise FileExistsError(f'Candidate already exists; choose a new output: {output}')
    if output.with_suffix('.receipt.json').exists():
        raise FileExistsError(f'Candidate receipt already exists: {output}')
    return output


def publish_exclusively(staged, destination):
    # Darwin RENAME_EXCL rejects even an empty directory created after preflight.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(staged), os.fsencode(destination), 0x00000004):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def copy_checked(source, destination, expected):
    if source.is_symlink() or not source.is_file() or sha256(source) != expected:
        raise ValueError(f'Input missing or SHA256 mismatch: {source}')
    shutil.copy2(source, destination)
    if sha256(destination) != expected:
        raise ValueError(f'Copied bytes differ: {destination}')


def screen_saver_payload(screen_saver, configuration=CONFIG):
    screen_saver = Path(screen_saver)
    if screen_saver.suffix != '.saver' or screen_saver.is_symlink() or not screen_saver.is_dir():
        raise ValueError(f'Invalid screen saver bundle: {screen_saver}')
    if any(path.is_symlink() for path in screen_saver.rglob('*')):
        raise ValueError(f'Screen saver bundle contains a symlink: {screen_saver}')
    info_path = screen_saver / 'Contents/Info.plist'
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise ValueError(f'Invalid screen saver Info.plist: {error}') from error
    expected_metadata = {'CFBundlePackageType': 'BNDL', 'NSHighResolutionCapable': True,
                         **configuration.screen_saver_metadata()}
    if any(info.get(key) != value for key, value in expected_metadata.items()):
        raise ValueError('Screen saver metadata does not match the application version and product identity')
    if info.get('CFBundleLocalizations') != list(configuration.localizations):
        raise ValueError('Screen saver metadata does not declare every supported localization')
    executable = screen_saver / 'Contents/MacOS' / configuration.screen_saver.executable
    if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f'Screen saver executable missing/not executable: {executable}')
    for language in configuration.localizations:
        strings = screen_saver / f'Contents/Resources/{language}.lproj/Localizable.strings'
        if strings.is_symlink() or not strings.is_file():
            raise ValueError(f'Screen saver localization is missing: {language}')
    return info, executable


def verify_screensaver_bundle(screen_saver, configuration=CONFIG):
    # Lazy import avoids the builder's dependency on publish_exclusively becoming a module cycle.
    from screensaver_bundle import verify_bundle
    return verify_bundle(screen_saver, configuration=configuration)


def screensaver_provenance(screen_saver, verification, configuration=CONFIG):
    info, executable = screen_saver_payload(screen_saver, configuration)
    return {
        'path': str(Path('Contents/PlugIns') / configuration.screen_saver.bundle_name),
        'bundle_identifier': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'executable_sha256': sha256(executable),
        'info_plist_sha256': sha256(Path(screen_saver) / 'Contents/Info.plist'),
        **verification,
    }


def embed_screensaver(screen_saver, app, configuration=CONFIG):
    screen_saver = Path(screen_saver)
    _, executable = screen_saver_payload(screen_saver, configuration)
    source_executable_sha = sha256(executable)
    source_info_sha = sha256(screen_saver / 'Contents/Info.plist')
    verification = verify_screensaver_bundle(screen_saver, configuration)
    destination = Path(app) / 'Contents/PlugIns' / configuration.screen_saver.bundle_name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(screen_saver, destination)
    _, copied_executable = screen_saver_payload(destination, configuration)
    if (sha256(copied_executable), sha256(destination / 'Contents/Info.plist')) != (source_executable_sha, source_info_sha):
        raise ValueError('Embedded screen saver differs from the verified input')
    copied_verification = verify_screensaver_bundle(destination, configuration)
    if copied_verification != verification:
        raise ValueError('Embedded screen saver verification differs from the verified input')
    return screensaver_provenance(destination, copied_verification, configuration)


def load_pinned_inputs(root):
    lock = load_lock(root / 'scripts/media-dependencies.json', root)
    for name, information in lock['modules'].items():
        for artifact in information['artifacts']:
            verify_artifact(root / '.build/dependencies', artifact)
        print(f'PINNED INPUTS verified: {name}', flush=True)
    return lock


def extract_cef_framework(archive, frameworks, version):
    prefix = f'cef_binary_{version}_macosarm64_minimal/Release/'
    extracted = 0
    with tarfile.open(archive, 'r:bz2') as source:
        for member in source:
            if not member.name.startswith(prefix + FRAMEWORK):
                continue
            relative = member.name[len(prefix):]
            parts = PurePosixPath(relative).parts
            if parts[0] != FRAMEWORK or any(part in ('.', '..') for part in parts):
                raise ValueError(f'Invalid CEF archive path: {member.name}')
            target = inside(frameworks / relative, frameworks)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as incoming, target.open('xb') as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
                target.chmod(member.mode & 0o777)
            elif member.issym():
                if PurePosixPath(member.linkname).is_absolute():
                    raise ValueError(f'Absolute CEF symlink: {member.name}')
                inside(target.parent / member.linkname, frameworks / FRAMEWORK)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
            else:
                raise ValueError(f'Unsupported CEF archive member: {member.name}')
            extracted += 1
    if extracted == 0 or not (frameworks / FRAMEWORK / 'Chromium Embedded Framework').is_file():
        raise ValueError('Pinned archive did not contain the expected CEF framework')


def build_helpers(root, stage, framework_directory, version, configuration=CONFIG):
    cef = root / f'.build/dependencies/cef/cef_binary_{version}_macosarm64_minimal'
    wrapper = root / '.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a'
    binary = stage / 'WebWallpaperHelper'
    run(['clang++', '-std=c++20',
         f'-mmacosx-version-min={configuration.target.minimum_macos}',
         '-arch', configuration.target.architecture,
         '-fobjc-arc', '-frtti', '-Wall', '-Wextra', '-Werror', '-isystem', cef,
         root / 'Sources/WebWallpaperHelper/main.mm', wrapper, '-framework', 'AppKit', '-o', binary])
    for helper in configuration.cef_helpers:
        name = f'{configuration.application.executable} Helper{helper.suffix}'
        contents = framework_directory / f'{name}.app/Contents'
        executable = contents / 'MacOS' / name
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        info = {'CFBundleExecutable': name, 'CFBundleName': name,
                'CFBundleIdentifier': helper.bundle_identifier,
                'CFBundlePackageType': 'APPL', 'LSUIElement': True,
                'LSMinimumSystemVersion': configuration.target.minimum_macos,
                'NSHighResolutionCapable': True,
                'CFBundleShortVersionString': configuration.version,
                'CFBundleVersion': configuration.build}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    return {'helper_source_sha256': sha256(root / 'Sources/WebWallpaperHelper/main.mm'),
            'wrapper_sha256': sha256(wrapper)}


def verify_third_party_product_label(directory, configuration):
    readme = Path(directory) / 'README.md'
    heading = '\n'.join(readme.read_text().splitlines()[:4])
    label = (f'{configuration.application.swiftpm_product} '
             f'{configuration.version}/build {configuration.build}')
    if re.search(rf'(?<!\w){re.escape(label)}(?!\w)', heading) is None:
        raise ValueError(f'ThirdParty/README.md version/build must match {label}')


def prepare_resources(root, app, stage, icon, configuration=CONFIG):
    resources = app / 'Contents/Resources'
    verify_distribution_materials(root / 'Resources/ThirdParty')
    verify_third_party_product_label(root / 'Resources/ThirdParty', configuration)
    icon = root / 'Resources/AppIcon.icns' if icon is None else icon
    if not icon.is_file() or icon.is_symlink():
        raise ValueError(f'Invalid supplied icon: {icon}')
    shutil.copy2(icon, resources / 'AppIcon.icns')
    shutil.copytree(root / 'Resources/ThirdParty', resources / 'ThirdParty', symlinks=True)
    status = verify_distribution_materials(resources / 'ThirdParty')
    verify_third_party_product_label(resources / 'ThirdParty', configuration)
    return status


def product_application_metadata(configuration):
    return {
        **configuration.application_metadata(),
        'DWApplicationBundleIdentifier': configuration.application.bundle_identifier,
        'DWScreenSaverBundleIdentifier': configuration.screen_saver.bundle_identifier,
        'DWScreenSaverBundleName': configuration.screen_saver.bundle_name,
        'DWCEFHelpers': [
            {'role': helper.role, 'suffix': helper.suffix,
             'bundleIdentifier': helper.bundle_identifier}
            for helper in configuration.cef_helpers
        ],
    }


def application_metadata(root, configuration):
    template = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    configured = product_application_metadata(configuration)
    dynamic_keys = set(configured)
    if dynamic_keys.intersection(template):
        raise ValueError('Application Info.plist template contains product metadata')
    return {
        **template,
        **configured,
    }


def copy_dependencies(root, app, stage, lock, configuration=CONFIG):
    sdk, toolchain = current_build_environment()
    tool_hashes = verify_record(root, lock, sdk_version=sdk, toolchain_version=toolchain)
    frameworks = app / 'Contents/Frameworks'; frameworks.mkdir()
    libraries = frameworks / 'MPV'; libraries.mkdir()
    from mpv_source_build import verify_built
    mpv_record = verify_built(root)
    mpv_root = mpv_prepared_root(root, lock)
    for name, record in sorted(mpv_record['libraries'].items()):
        copy_checked(mpv_root / 'runtime-lib' / name, libraries / name, record['sha256'])
    cef = lock['modules']['cef']
    extract_cef_framework(root / '.build/dependencies' / cef['artifacts'][0]['path'], frameworks, cef['version'])
    helper = build_helpers(root, stage, frameworks, cef['version'], configuration)
    media_tools = app / 'Contents/Resources/MediaTools'; media_tools.mkdir()
    tool_inputs = []
    for name, digest in sorted(tool_hashes.items()):
        relative = str(Path('ffmpeg/install/bin') / name)
        source = root / '.build/dependencies' / relative
        copy_checked(source, media_tools / name, digest)
        tool_inputs.append({'path': relative, 'sha256': digest})
    return {'helper': helper, 'media_tools': tool_inputs,
            'mpv_source_build': mpv_record}


def required_payload(app, library_names, configuration=CONFIG):
    executables = [f'Contents/MacOS/{configuration.application.executable}',
                   'Contents/Resources/MediaTools/ffmpeg',
                   'Contents/Resources/MediaTools/ffprobe',
                   f'Contents/Frameworks/{FRAMEWORK}/Chromium Embedded Framework']
    executables += [
        f'Contents/Frameworks/{configuration.application.executable} Helper{helper.suffix}.app/'
        f'Contents/MacOS/{configuration.application.executable} Helper{helper.suffix}'
        for helper in configuration.cef_helpers
    ]
    paths = executables + ['Contents/Resources/AppIcon.icns',
                           'Contents/Resources/ThirdParty/distribution-status.json']
    # These are loaded dynamically or read as data, so LC_LOAD_DYLIB alone is insufficient.
    paths += [f'Contents/Frameworks/{FRAMEWORK}/{relative}' for relative in (
        'Libraries/libcef_sandbox.dylib', 'Libraries/libvk_swiftshader.dylib', 'Libraries/libvulkan.dylib',
        'Libraries/vk_swiftshader_icd.json', 'Resources/icudtl.dat', 'Resources/resources.pak',
        'Resources/chrome_100_percent.pak', 'Resources/chrome_200_percent.pak',
        'Resources/v8_context_snapshot.arm64.bin', 'Resources/gpu_shader_cache.bin')]
    paths += [f'Contents/Frameworks/MPV/{name}' for name in library_names]
    for relative in paths:
        path = inside(app / relative, app)
        if not path.is_file():
            raise ValueError(f'Missing packaged payload: {relative}')
        if relative in executables and not os.access(path, os.X_OK):
            raise ValueError(f'Packaged executable lacks execute permission: {relative}')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected_product_metadata = product_application_metadata(configuration)
    for key, value in expected_product_metadata.items():
        if info.get(key) == value:
            continue
        if key in {'CFBundleDevelopmentRegion', 'CFBundleLocalizations'}:
            raise ValueError('Application localization metadata does not match product configuration')
        raise ValueError(f'{key} does not match product configuration')
    if (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (
            configuration.version, configuration.build):
        raise ValueError('Candidate version/build does not match product configuration')
    if info.get('CFBundleExecutable') != configuration.application.executable:
        raise ValueError('Application Info.plist does not name the packaged executable')
    for key in ('CFBundleName', 'CFBundleDisplayName'):
        if info.get(key) != configuration.application.display_name:
            raise ValueError(f'{key} must match the configured display name')
    verify_application_localizations(app, info, configuration)
    verify_help_bundle(bundle_resource_directory(app / 'Contents/Resources' / RESOURCE_BUNDLE) / 'Help')
    verify_helper_metadata(app, configuration)
    screen_saver_payload(
        app / 'Contents/PlugIns' / configuration.screen_saver.bundle_name,
        configuration)
    return info


def verify_helper_metadata(app, configuration=CONFIG):
    for helper in configuration.cef_helpers:
        name = f'{configuration.application.executable} Helper{helper.suffix}'
        path = inside(app / f'Contents/Frameworks/{name}.app/Contents/Info.plist', app)
        info = plistlib.loads(path.read_bytes())
        expected = {'CFBundleExecutable': name,
                    'CFBundleIdentifier': helper.bundle_identifier,
                    'CFBundleShortVersionString': configuration.version,
                    'CFBundleVersion': configuration.build}
        if any(info.get(key) != value for key, value in expected.items()):
            raise ValueError(f'Helper metadata does not match packaged payload: {name}')


def verify_candidate(app, library_names, *, configuration):
    info = required_payload(app, library_names, configuration)
    run(['plutil', '-lint', app / 'Contents/Info.plist'])
    verify_third_party_product_label(app / 'Contents/Resources/ThirdParty', configuration)
    screen_saver_path = app / 'Contents/PlugIns' / configuration.screen_saver.bundle_name
    screen_saver = screensaver_provenance(screen_saver_path,
                                         verify_screensaver_bundle(
                                             screen_saver_path, configuration),
                                         configuration)
    recorded = json.loads((app / 'Contents/Resources/BuildProvenance.json').read_text())
    if recorded.get('screen_saver') != screen_saver:
        raise ValueError('Embedded screen saver provenance differs from the final bundle')
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'signature': run(['codesign', '--display', '--verbose=4', app]).strip(),
            'notarization': 'not performed or verified',
            'images': verify_macho_closure(app, product_target=configuration.target),
            'screen_saver': screen_saver,
            'help_languages': info['CFBundleLocalizations'],
            'distribution_materials': verify_distribution_materials(app / 'Contents/Resources/ThirdParty'),
            'functional_acceptance': 'not-run-by-packager'}


def package(root, *, binary, screensaver, output, icon=None):
    root = root.resolve(); output = validate_output(root, output)
    configuration = load_product_configuration(root / 'scripts/product-configuration.json')
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f'Release executable missing/not executable: {binary}')
    verify_help_bundle(bundle_resource_directory(binary.parent / RESOURCE_BUNDLE) / 'Help')
    lock = load_pinned_inputs(root)
    from media_build_materials import verify_material_build_records
    verify_material_build_records(root, lock)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.packaging-', dir=output.parent) as directory:
        stage = Path(directory); app = stage / configuration.application.bundle_name
        for name in ('MacOS', 'Resources'): (app / 'Contents' / name).mkdir(parents=True)
        input_sha = sha256(binary)
        copy_checked(
            binary, app / 'Contents/MacOS' / configuration.application.executable, input_sha)
        (app / 'Contents/Info.plist').write_bytes(
            plistlib.dumps(application_metadata(root, configuration)))
        materials = prepare_resources(root, app, stage, icon, configuration)
        inputs = copy_dependencies(root, app, stage, lock, configuration)
        inputs['localization_resources'] = prepare_localizations(binary, app, configuration)
        inputs['screen_saver'] = embed_screensaver(screensaver, app, configuration)
        inputs.update({'release_binary_sha256': input_sha,
                       'dependency_lock_sha256': sha256(root / 'scripts/media-dependencies.json'),
                       'materials_complete': materials.get('complete') is True})
        (app / 'Contents/Resources/BuildProvenance.json').write_text(json.dumps(inputs, indent=2) + '\n')
        rewrite_bundle_rpaths(
            app, product_target=configuration.target,
            main_executable=configuration.application.executable)
        sign_bundle(app)
        from media_dependencies import expected_mpv_library_names
        names = expected_mpv_library_names(lock)
        receipt = verify_candidate(app, names, configuration=configuration)
        receipt.update({'bundle': str(output), 'inputs': inputs,
                        'bundle_file_bytes': sum(p.stat().st_size for p in app.rglob('*') if p.is_file() and not p.is_symlink())})
        validate_output(root, output)
        publish_exclusively(app, output)
        # Failure writing this separate receipt is surfaced; the verified app remains.
        with output.with_suffix('.receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2); stream.write('\n')
    print(f'LOCAL CANDIDATE: {output}', flush=True)
    print(f'Distribution materials complete: {materials.get("complete") is True}; product acceptance is separate.', flush=True)
    return receipt
