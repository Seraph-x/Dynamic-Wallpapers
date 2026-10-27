"""Create a new local ZIP release and verify its extracted application bytes."""
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import zipfile

from media_bundle import publish_exclusively, verify_candidate
from media_bundle_macho import inside, run, sha256
from product_configuration import load as load_product_configuration
from media_dependencies import expected_mpv_library_names, load_lock


def validate_release_output(root, output):
    root, output = Path(os.path.abspath(root)), Path(os.path.abspath(output))
    dist = root / 'dist'
    if output == dist or not output.is_relative_to(dist):
        raise ValueError(f'Release output must be a new directory below {dist}: {output}')
    for path in [output, *output.parents]:
        if path == root:
            break
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise ValueError(f'Invalid release output parent: {path}')
    if output.exists():
        raise FileExistsError(f'Local release already exists: {output}')
    return output


def active_library_names(root):
    root = Path(root)
    return expected_mpv_library_names(load_lock(root / 'scripts/media-dependencies.json', root))


def tree_manifest(directory):
    directory = Path(directory)
    records = []
    for path in sorted(directory.rglob('*')):
        record = {'path': str(path.relative_to(directory))}
        if path.is_symlink():
            target = inside(path, directory)
            if not target.exists():
                raise ValueError(f'Dangling archive symlink: {path}')
            record.update(kind='symlink', target=os.readlink(path))
        elif path.is_file():
            record.update(kind='file', size=path.stat().st_size, sha256=sha256(path),
                          mode=stat.S_IMODE(path.stat().st_mode))
        elif path.is_dir():
            record.update(kind='directory', mode=stat.S_IMODE(path.stat().st_mode))
        else:
            raise ValueError(f'Unsupported archive entry: {path}')
        records.append(record)
    return records


def archive_application(app, archive, extraction):
    if archive.exists() or archive.is_symlink():
        raise FileExistsError(f'Archive already exists: {archive}')
    if extraction.exists() or extraction.is_symlink():
        raise FileExistsError(f'Extraction directory already exists: {extraction}')
    expected = tree_manifest(app)
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive])
    with zipfile.ZipFile(archive) as source:
        damaged = source.testzip()
        if damaged is not None:
            raise ValueError(f'Corrupt ZIP member: {damaged}')
    run(['ditto', '-x', '-k', archive, extraction])
    restored = extraction / app.name
    if tree_manifest(restored) != expected:
        raise ValueError('Extracted application differs in files, modes, symlinks or directories')
    return restored, expected


def create_local_release(root, *, app, output, notes):
    root = root.resolve(); app = app.resolve()
    configuration = load_product_configuration(root / 'scripts/product-configuration.json')
    output = validate_release_output(root, output)
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError(f'Missing application candidate: {app}')
    release_notes = notes.read_text()
    if not release_notes.strip():
        raise ValueError('Release notes are empty')
    names = active_library_names(root)
    original = tree_manifest(app)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.release-', dir=output.parent) as directory:
        stage = Path(directory); release = stage / 'release'; release.mkdir()
        copied = stage / 'candidate' / app.name
        shutil.copytree(app, copied, symlinks=True)
        if tree_manifest(copied) != original:
            raise ValueError('Candidate changed while copying for the local release')
        archive = release / configuration.archive_name()
        restored, manifest = archive_application(copied, archive, stage / 'extracted')
        verification = verify_candidate(
            restored, names, configuration=configuration)
        verification.update(source_candidate=str(app), archive=archive.name,
                            archive_sha256=sha256(archive), archive_roundtrip='identical',
                            functional_acceptance='See supplied release notes; not run by archive creation')
        (release / 'RELEASE_NOTES.md').write_text(release_notes)
        (release / 'bundle-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        (release / 'bundle-verification.json').write_text(json.dumps(verification, indent=2) + '\n')
        checksum_files = sorted(release.iterdir())
        (release / 'SHA256SUMS').write_text(''.join(f'{sha256(path)}  {path.name}\n' for path in checksum_files))
        validate_release_output(root, output)
        publish_exclusively(release, output)
    print(f'LOCAL RELEASE: {output}', flush=True)
    print(f'ZIP roundtrip and static signatures verified; distribution materials complete: '
          f'{verification["distribution_materials"]["complete"]}', flush=True)
    return verification
