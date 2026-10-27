"""Export measured media build evidence without retaining build-machine paths."""
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile

from ffmpeg_build_record import current_build_environment, record_path, verify_record
from media_dependencies import load_lock
from mpv_source_inputs import sha256, source_file


def normalized_ffmpeg_configuration(text):
    original = [option for line in text.splitlines() if line.strip().startswith('--')
                for option in shlex.split(line.strip())]
    prefixes = [option.split('=', 1)[1] for option in original if option.startswith('--prefix=')]
    sdk_paths = [option.split('=', 1)[1] for option in original if option.startswith('--sysroot=')]
    if len(prefixes) != 1 or not original:
        raise ValueError('FFmpeg did not expose its actual configure options')
    prefix = prefixes[0]
    options = []
    for original_option in original:
        option = original_option.replace(prefix, '<BUILD_PREFIX>')
        for sdk in sdk_paths:
            option = option.replace(sdk, '<MACOS_SDK>')
        if any(path in option for path in ('/Users/', '/private/tmp/', '/opt/homebrew/')):
            raise ValueError(f'Unexpected host path in FFmpeg configuration option: {option}')
        options.append(option)
    return options, prefix


def verify_ffmpeg_license(options, license_text, flags):
    required = {'--disable-autodetect', '--disable-network', '--disable-shared', '--enable-static'}
    forbidden = {'--enable-gpl', '--enable-nonfree', '--enable-version3', '--enable-network'}
    if not required.issubset(options) or forbidden.intersection(options):
        raise ValueError('FFmpeg actual configuration differs from the intended LGPL offline tool')
    normalized = re.sub(r'\s+', ' ', license_text)
    if ('GNU Lesser General Public License' not in normalized
            or re.search(r'version\s+2\.1\b', normalized) is None
            or flags != {'GPL': 0, 'NONFREE': 0, 'VERSION3': 0, 'NETWORK': 0}):
        raise ValueError('FFmpeg measured binary license/configuration is not LGPL-2.1-or-later')


def ffmpeg_public_record(root, lock, *, ffmpeg_root=None):
    root = Path(root)
    ffmpeg_root = Path(ffmpeg_root) if ffmpeg_root is not None else root
    sdk, toolchain = current_build_environment()
    tools = verify_record(ffmpeg_root, lock, sdk_version=sdk, toolchain_version=toolchain)
    record = json.loads(record_path(ffmpeg_root).read_text())
    if sha256(root / 'scripts/feasibility/ffmpeg/build.sh') != record['build_script_sha256']:
        raise ValueError('Public FFmpeg recipe differs from the actual verified build recipe')
    source = source_file(root, 'Resources/ThirdParty/FFmpeg/ffmpeg-n9.0.1-source.tar.gz')
    if sha256(source) != record['source_sha256']:
        raise ValueError('Public FFmpeg corresponding source differs from the actual build')
    tool = ffmpeg_root / '.build/dependencies/ffmpeg/install/bin/ffmpeg'
    license_text = subprocess.check_output([str(tool), '-hide_banner', '-L'],
                                           stderr=subprocess.STDOUT, text=True)
    configuration = subprocess.check_output([str(tool), '-hide_banner', '-buildconf'],
                                            stderr=subprocess.STDOUT, text=True)
    options, prefix = normalized_ffmpeg_configuration(configuration)
    config = Path(prefix).parent / 'build/config.h'
    if not config.resolve().is_relative_to((ffmpeg_root / '.build/dependencies/ffmpeg').resolve()):
        raise ValueError('FFmpeg build configuration is outside its verified build cache')
    config_text = config.read_text()
    flags = {}
    for feature in ('GPL', 'NONFREE', 'VERSION3', 'NETWORK'):
        match = re.search(r'^#define CONFIG_' + feature + r' ([01])$', config_text, re.MULTILINE)
        if match is None:
            raise ValueError(f'Actual FFmpeg configuration lacks CONFIG_{feature}')
        flags[feature] = int(match[1])
    verify_ffmpeg_license(options, license_text, flags)
    import hashlib
    return {'schema_version': 1, 'version': '9.0.1 (n9.0.1)',
            'source_sha256': record['source_sha256'],
            'build_script_sha256': record['build_script_sha256'],
            'sdk_version': sdk, 'toolchain_version': toolchain, 'tools': tools,
            'build_inputs': record['build_inputs'], 'build_tools': record['build_tools'],
            'license': 'LGPL-2.1-or-later', 'measured_config_flags': flags,
            'configure_options': options,
            'config_h_sha256': sha256(config),
            'license_output_sha256': hashlib.sha256(license_text.encode()).hexdigest(),
            'configuration_output_sha256': hashlib.sha256(configuration.encode()).hexdigest(),
            'normalization': 'Only occurrences of actual build-prefix and SDK path values use named tokens; '
                             'raw output hashes and all other actual options are retained.'}


def refresh_material_manifest(root):
    directory = Path(root) / 'Resources/ThirdParty'
    path = directory / 'distribution-status.json'
    status = json.loads(path.read_text())
    status['complete'] = all(component['complete'] for component in status['components'].values())
    status['files'] = [{'path': str(item.relative_to(directory)), 'sha256': sha256(item),
                        'size': item.stat().st_size}
                       for item in sorted(directory.rglob('*'))
                       if item.is_file() and item != path]
    path.write_text(json.dumps(status, indent=2) + '\n')
    return status


def export_ffmpeg_record(root, *, ffmpeg_root=None):
    root = Path(root)
    lock = load_lock(root / 'scripts/media-dependencies.json', root)
    report = ffmpeg_public_record(root, lock, ffmpeg_root=ffmpeg_root)
    directory = root / 'Resources/ThirdParty'
    (directory / 'FFmpeg/BUILD-RECORD.json').write_text(json.dumps(report, indent=2) + '\n')
    for relative in report['build_inputs']:
        if relative.startswith('scripts/'):
            destination = directory / 'FFmpeg/recipe' / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_file(root, relative), destination)
    shutil.copyfile(root / 'scripts/feasibility/ffmpeg/build.sh', directory / 'FFmpeg/build.sh')
    path = directory / 'distribution-status.json'
    status = json.loads(path.read_text())
    status['components']['ffmpeg'].update(
        complete=True, scope='Actual verified tool hashes, compiler/SDK, measured LGPL license '
        'and configuration flags retained with complete unchanged corresponding source and recipe')
    status['unresolved'] = [item for item in status.get('unresolved', [])
                            if not item.startswith(('Current FFmpeg9', 'Locally rebuilt FFmpeg'))]
    path.write_text(json.dumps(status, indent=2) + '\n')
    refresh_material_manifest(root)
    return report


def export_mpv_record(root):
    from mpv_source_build import INPUT_FILES, verify_built
    root = Path(root)
    report = verify_built(root)
    from mpv_source_inputs import load_source_lock
    verify_original_notice_copies(root, load_source_lock(root))
    directory = root / 'Resources/ThirdParty/MPV'
    (directory / 'BUILD-RECORD.json').write_text(json.dumps(report, indent=2) + '\n')
    for relative in INPUT_FILES:
        destination = directory / 'recipe' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / relative, destination)
    status_path = root / 'Resources/ThirdParty/distribution-status.json'
    status = json.loads(status_path.read_text())
    source_lock = json.loads((root / 'scripts/mpv-source-lock.json').read_text())
    native_path = directory / 'acceptance/acceptance.json'
    native_current = False
    if native_path.exists():
        native = json.loads(native_path.read_text())
        if native.get('build_record_sha256') == sha256(root / '.build/media-source-complete/mpv/build-record.json'):
            from media_acceptance_materials import verify_native_acceptance
            verify_native_acceptance(root, native_path, directory / 'acceptance/fixtures')
            native_current = True
        else:
            print('RETAINED native acceptance is for different mpv products; completeness remains false.', flush=True)
    status['components']['mpv']['complete'] = native_current
    status['components']['mpv']['license_files'] = [
        f'MPV/notices/{component["name"]}/{notice}'
        for component in source_lock['components'] for notice in component['license_files']]
    status['components']['mpv']['scope'] = (
        'Actual source build and closed arm64/macOS14 dylib graph verified; '
        'complete corresponding source, patches, notices and recipe retained; '
        'actual six-fixture native acceptance retained' if native_current else
        'Actual source build and closed arm64/macOS14 dylib graph verified; native acceptance pending')
    status['unresolved'] = [] if native_current else [
        'Native controlled-mpv software rendering, CoreAudio, VideoToolbox-copy and codec/container parity acceptance pending.']
    status_path.write_text(json.dumps(status, indent=2) + '\n')
    refresh_material_manifest(root)
    return report


def verify_material_build_records(root, lock):
    from mpv_source_build import INPUT_FILES, verify_built
    root = Path(root)
    verify_original_notice_copies(root, lock['modules']['mpv']['_source_lock'])
    directory = root / 'Resources/ThirdParty'
    mpv_record = verify_built(root)
    if json.loads((directory / 'MPV/BUILD-RECORD.json').read_text()) != mpv_record:
        raise ValueError('Distributed MPV build record differs from actual prepared products')
    for relative in INPUT_FILES:
        if sha256(source_file(directory / 'MPV/recipe', relative)) != mpv_record['inputs'][relative]:
            raise ValueError(f'Distributed MPV recipe differs from actual build: {relative}')
    status = json.loads(source_file(directory, 'distribution-status.json').read_text())
    if status['components']['mpv']['complete'] is True:
        from media_acceptance_materials import verify_native_acceptance
        verify_native_acceptance(root, directory / 'MPV/acceptance/acceptance.json',
                                 directory / 'MPV/acceptance/fixtures')
    ffmpeg_record = ffmpeg_public_record(root, lock)
    if json.loads((directory / 'FFmpeg/BUILD-RECORD.json').read_text()) != ffmpeg_record:
        raise ValueError('Distributed FFmpeg build record differs from actual prepared tools')
    verify_ffmpeg_recipe_copies(directory, ffmpeg_record)
    verify_ffmpeg_native_acceptance(root, ffmpeg_record['tools'])


def verify_ffmpeg_recipe_copies(directory, ffmpeg_record):
    directory = Path(directory)
    for relative, expected in ffmpeg_record['build_inputs'].items():
        if relative.startswith('scripts/'):
            if sha256(source_file(directory / 'FFmpeg/recipe', relative)) != expected:
                raise ValueError(f'Distributed FFmpeg codec recipe differs from actual build: {relative}')
    if sha256(directory / 'FFmpeg/build.sh') != ffmpeg_record['build_script_sha256']:
        raise ValueError('Distributed FFmpeg build script differs from actual build')


def verify_ffmpeg_native_acceptance(root, tools):
    root = Path(root)
    path = source_file(root, 'Resources/ThirdParty/FFmpeg/acceptance/software-transcode.json')
    report = json.loads(path.read_text())
    expected = {'av1-opus.mkv', 'av1-opus.webm', 'h264-aac.mkv', 'vp9-opus.webm',
                'mpeg4-mp3.avi', 'zmbv-mp3.avi'}
    if (report.get('schema_version') != 1 or type(report.get('cases')) is not list
            or len(report['cases']) != len(expected)
            or {case['fixture'] for case in report['cases']} != expected
            or any(report.get(name + '_sha256') != tools[name] for name in ('ffmpeg', 'ffprobe'))
            or report.get('runner_source_sha256') != sha256(root / 'scripts/test-ffmpeg-av1-tools.py')):
        raise ValueError('FFmpeg native acceptance is incomplete or differs from actual tools/runner')
    for case in report['cases']:
        fixture = source_file(root, 'Resources/ThirdParty/MPV/acceptance/fixtures/' + case['fixture'])
        if sha256(fixture) != case.get('fixture_sha256'):
            raise ValueError('FFmpeg actual acceptance fixture SHA256 differs')
        for result in (case['decoded'], case['converted']):
            if (type(result.get('frame_count')) is not int or result['frame_count'] < 2
                    or type(result.get('pcm_bytes')) is not int or result['pcm_bytes'] <= 0
                    or any(not isinstance(result.get(key), str)
                           or not re.fullmatch('[0-9a-f]{64}', result[key])
                           for key in ('first_rgba_sha256', 'last_rgba_sha256', 'pcm_sha256'))
                    or result['first_rgba_sha256'] == result['last_rgba_sha256']):
                raise ValueError('FFmpeg native acceptance lacks actual changing video/audio evidence')
        if (case['decoded']['frame_count'] != case['converted']['frame_count']
                or (case['fixture'].startswith('av1')
                    and case['decoded'].get('software_av1_decoder_observed') is not True)):
            raise ValueError('FFmpeg native acceptance lacks lossless frame count/software AV1 evidence')
    return report


def verify_original_notice_copies(root, lock):
    root = Path(root)
    for component in lock['components']:
        with tarfile.open(root / component['artifact']['path']) as archive:
            members = {member.name.split('/', 1)[-1]: member
                       for member in archive.getmembers() if member.isfile()}
            for relative in component['license_files']:
                expected = archive.extractfile(members[relative]).read()
                notice = source_file(root, f'Resources/ThirdParty/MPV/notices/{component["name"]}/{relative}')
                if notice.read_bytes() != expected:
                    raise ValueError(f'Original notice differs from source archive: {component["name"]}/{relative}')
