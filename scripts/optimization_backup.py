#!/usr/bin/env python3
"""Verify staged source backups and publish deletion receipts outside them."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import uuid


STAGE_LABELS = {
    'stage3': 'product-configuration',
    'stage4': 'structured-failures',
    'stage5': 'swift6-readiness',
}
RUN_KEYS = frozenset({
    'schema_version', 'run_id', 'source_root', 'work_root', 'receipts_root', 'stages',
})
STAGE_KEYS = frozenset({
    'schema_version', 'run_id', 'stage', 'directory', 'work_root', 'parent_commit',
    'git_status_porcelain_v2', 'baseline', 'paths', 'allowed_diff_paths', 'status',
})
HEX_SHA = re.compile(r'[a-f0-9]{64}\Z')
RUN_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]*-20[0-9]{6}T[0-9]{6}Z\Z')


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _lstat(path: Path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def _regular(path: Path, description: str) -> os.stat_result:
    info = _lstat(path)
    if info is None or not stat.S_ISREG(info.st_mode):
        raise ValueError(f'{description} must be a regular non-symlink file: {path}')
    return info


def _directory(path: Path, description: str) -> os.stat_result:
    info = _lstat(path)
    if info is None or not stat.S_ISDIR(info.st_mode):
        raise ValueError(f'{description} must be a non-symlink directory: {path}')
    return info


def _relative(value: str) -> PurePosixPath:
    if type(value) is not str or not value or '\\' in value:
        raise ValueError(f'Invalid relative path: {value!r}')
    path = PurePosixPath(value)
    if (path.is_absolute() or path.as_posix() != value
            or any(part in ('', '.', '..') for part in path.parts)):
        raise ValueError(f'Invalid relative path: {value!r}')
    return path


def _direct_child(name: str) -> str:
    if type(name) is not str or not name or '/' in name or name in ('.', '..'):
        raise ValueError(f'Backup stage must be a direct child: {name!r}')
    _relative(name)
    return name


def _components_without_symlinks(root: Path, target: Path) -> None:
    if not target.is_relative_to(root):
        raise ValueError(f'Path is outside backup worktree: {target}')
    _directory(root, 'Worktree')
    current = root
    for part in target.relative_to(root).parts:
        current /= part
        info = _lstat(current)
        if info is None:
            return
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f'Symlink component rejected: {current}')
        if current != target and not stat.S_ISDIR(info.st_mode):
            raise ValueError(f'Non-directory path component: {current}')


def _read_json(path: Path) -> dict:
    _regular(path, 'Manifest')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'r', encoding='utf-8') as stream:
        document = json.load(stream)
    if type(document) is not dict:
        raise ValueError(f'Manifest must be an object: {path}')
    return document


def _exclusive_json(path: Path, document: dict) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
        json.dump(document, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def _fsync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_file(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _replace_json(path: Path, document: dict) -> None:
    _regular(path, 'Manifest')
    temporary = path.parent / f'{path.name}.tmp-{uuid.uuid4()}'
    _exclusive_json(temporary, document)
    os.replace(temporary, path)
    _fsync_directory(path.parent)


def _work_root(value: str) -> Path:
    if type(value) is not str:
        raise ValueError('work_root must be a canonical absolute path')
    path = Path(value)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError('work_root must be a canonical absolute path')
    _directory(path, 'Worktree')
    return path


def validate_run_document(document: dict, path: Path) -> dict:
    if set(document) != RUN_KEYS or document['schema_version'] != 1:
        raise ValueError('Invalid run manifest schema')
    run_id = document['run_id']
    if type(run_id) is not str or RUN_NAME.fullmatch(run_id) is None:
        raise ValueError('Invalid backup run ID')
    work = _work_root(document['work_root'])
    expected = work / '.build/optimization-backups' / run_id / 'run-manifest.json'
    if Path(os.path.abspath(path)) != expected:
        raise ValueError('Run manifest is outside the exact run directory')
    _components_without_symlinks(work, expected)
    source = document['source_root']
    if type(source) is not str or not Path(source).is_absolute():
        raise ValueError('Invalid source_root')
    receipt = f'.build/optimization-backup-receipts/{run_id}'
    if document['receipts_root'] != receipt:
        raise ValueError('Invalid receipt root')
    stages = document['stages']
    if type(stages) is not list or not stages:
        raise ValueError('Run manifest needs stage entries')
    seen = set()
    for entry in stages:
        if type(entry) is not dict or set(entry) != {'name', 'directory'}:
            raise ValueError('Invalid run stage entry')
        name = entry['name']
        if name not in STAGE_LABELS or name in seen:
            raise ValueError(f'Invalid or duplicate stage: {name}')
        seen.add(name)
        _direct_child(entry['directory'])
        if entry['directory'] != f'{name}-{STAGE_LABELS[name]}-{run_id.rsplit("-", 1)[-1]}':
            raise ValueError(f'Unexpected stage directory: {entry["directory"]}')
    return document


def load_run_manifest(path: Path) -> dict:
    path = Path(os.path.abspath(path))
    document = _read_json(path)
    return validate_run_document(document, path)


def validate_stage_document(document: dict, path: Path) -> dict:
    if set(document) != STAGE_KEYS or document['schema_version'] != 1:
        raise ValueError('Invalid stage manifest schema')
    work = _work_root(document['work_root'])
    stage = document['stage']
    run = load_run_manifest(work / '.build/optimization-backups' / document['run_id'] / 'run-manifest.json')
    entry = next((item for item in run['stages'] if item['name'] == stage), None)
    if entry is None:
        raise ValueError(f'Stage is not registered in run manifest: {stage}')
    directory = work / '.build/optimization-backups' / document['run_id'] / entry['directory']
    if document['directory'] != str(directory) or Path(os.path.abspath(path)) != directory / 'manifest.json':
        raise ValueError('Stage directory must be the registered direct child')
    _components_without_symlinks(work, directory / 'manifest.json')
    _directory(directory, 'Stage backup')
    if type(document['parent_commit']) is not str or re.fullmatch(r'[a-f0-9]{40}', document['parent_commit']) is None:
        raise ValueError('Invalid stage parent commit')
    if type(document['git_status_porcelain_v2']) is not str:
        raise ValueError('Invalid stage Git status')
    if document['status'] not in ('backed-up', 'ready'):
        raise ValueError('Invalid stage status')
    paths = document['paths']
    allowed = document['allowed_diff_paths']
    if type(paths) is not list or type(allowed) is not list or not allowed:
        raise ValueError('Stage path records are required')
    names = [item.get('path') for item in paths if type(item) is dict]
    if len(names) != len(paths) or names != allowed or names != sorted(set(names)):
        raise ValueError('Stage paths and allow-set must be sorted and identical')
    for item in paths:
        _relative(item['path'])
        if item.get('expected') == 'existing':
            if (set(item) != {'path', 'expected', 'kind', 'mode', 'sha256', 'backup'}
                    or item['kind'] != 'file' or type(item['mode']) is not int
                    or item['mode'] < 0 or item['mode'] > 0o777
                    or type(item['sha256']) is not str or HEX_SHA.fullmatch(item['sha256']) is None
                    or item['backup'] != f'files/{item["path"]}'):
                raise ValueError(f'Invalid existing-path record: {item["path"]}')
        elif item.get('expected') == 'absent':
            if (set(item) != {'path', 'expected', 'parent_device', 'parent_inode'}
                    or type(item['parent_device']) is not int
                    or type(item['parent_inode']) is not int):
                raise ValueError(f'Invalid absent-path record: {item["path"]}')
        else:
            raise ValueError(f'Invalid stage path record: {item["path"]}')
    baselines = document['baseline']
    if type(baselines) is not list or len(baselines) != 2:
        raise ValueError('Two stage baselines are required')
    for entry in baselines:
        if (type(entry) is not dict or set(entry) != {'log', 'sha256', 'result'}
                or type(entry['sha256']) is not str or HEX_SHA.fullmatch(entry['sha256']) is None):
            raise ValueError('Invalid stage baseline record')
        for key in ('log', 'result'):
            _relative(entry[key])
            if not entry[key].startswith(f'.build/verification/{document["run_id"]}/'):
                raise ValueError('Stage baseline is outside the run evidence directory')
    return document


def load_stage_manifest(path: Path) -> dict:
    path = Path(os.path.abspath(path))
    document = _read_json(path)
    return validate_stage_document(document, path)


def init_run(work_root: Path, source_root: Path, run_id: str,
             stages: tuple[str, ...]) -> Path:
    work = Path(work_root).resolve(strict=True)
    source = Path(source_root).resolve(strict=True)
    if RUN_NAME.fullmatch(run_id) is None or not stages or len(stages) != len(set(stages)):
        raise ValueError('Invalid run ID or stages')
    if any(name not in STAGE_LABELS for name in stages):
        raise ValueError('Unknown backup stage')
    run_root = work / '.build/optimization-backups' / run_id
    receipts_root = work / '.build/optimization-backup-receipts' / run_id
    for target in (run_root, receipts_root):
        _components_without_symlinks(work, target)
        if _lstat(target) is not None:
            raise FileExistsError(target)
    run_root.mkdir(parents=True, mode=0o700)
    receipts_root.mkdir(parents=True, mode=0o700)
    stamp = run_id.rsplit('-', 1)[-1]
    document = {
        'schema_version': 1, 'run_id': run_id, 'source_root': str(source),
        'work_root': str(work),
        'receipts_root': f'.build/optimization-backup-receipts/{run_id}',
        'stages': [
            {'name': name, 'directory': f'{name}-{STAGE_LABELS[name]}-{stamp}'}
            for name in stages
        ],
    }
    manifest = run_root / 'run-manifest.json'
    _exclusive_json(manifest, document)
    _fsync_directory(run_root)
    _fsync_directory(run_root.parent)
    _fsync_directory(receipts_root.parent)
    return manifest


def _allow_paths(path: Path) -> list[str]:
    _regular(path, 'Stage allow-set')
    lines = path.read_text(encoding='utf-8').splitlines()
    if not lines or lines != sorted(set(lines)):
        raise ValueError('Stage allow-set must be nonempty, sorted and unique')
    for value in lines:
        _relative(value)
    return lines


def _path_record(work: Path, stage_root: Path, value: str) -> dict:
    relative = _relative(value)
    source = work.joinpath(*relative.parts)
    _components_without_symlinks(work, source)
    info = _lstat(source)
    if info is None:
        parent = _directory(source.parent, 'Absent-path parent')
        return {'path': value, 'expected': 'absent',
                'parent_device': parent.st_dev, 'parent_inode': parent.st_ino}
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f'Stage source must be a regular file: {source}')
    before_hash = _sha256(source)
    destination = stage_root / 'files' / value
    destination.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    _components_without_symlinks(stage_root, destination)
    if _lstat(destination) is not None:
        raise FileExistsError(destination)
    shutil.copy2(source, destination, follow_symlinks=False)
    after = _regular(source, 'Stage source')
    copied = _regular(destination, 'Backup copy')
    if (after.st_dev, after.st_ino, stat.S_IMODE(after.st_mode)) != (
            info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode)):
        raise ValueError(f'Stage source changed while backing up: {value}')
    if _sha256(source) != before_hash or _sha256(destination) != before_hash:
        raise ValueError(f'Backup SHA256 mismatch: {value}')
    if stat.S_IMODE(copied.st_mode) != stat.S_IMODE(info.st_mode):
        raise ValueError(f'Backup mode mismatch: {value}')
    _fsync_file(destination)
    _fsync_directory(destination.parent)
    return {'path': value, 'expected': 'existing', 'kind': 'file',
            'mode': stat.S_IMODE(info.st_mode), 'sha256': before_hash,
            'backup': f'files/{value}'}


def create_stage(run_manifest: Path, stage: str, parent_commit: str,
                 paths_file: Path) -> Path:
    run = load_run_manifest(run_manifest)
    work = Path(run['work_root'])
    entry = next((item for item in run['stages'] if item['name'] == stage), None)
    if entry is None:
        raise ValueError(f'Unregistered stage: {stage}')
    allow_file = Path(os.path.abspath(paths_file))
    evidence_root = work / '.build/verification' / run['run_id']
    if not allow_file.is_relative_to(evidence_root):
        raise ValueError('Allow-set must be inside the run evidence directory')
    _components_without_symlinks(work, allow_file)
    paths = _allow_paths(allow_file)
    stage_root = Path(run_manifest).parent / entry['directory']
    _components_without_symlinks(work, stage_root)
    if _lstat(stage_root) is not None:
        raise FileExistsError(stage_root)
    if git(work, 'rev-parse', 'HEAD') != parent_commit:
        raise ValueError('Stage parent commit differs from current HEAD')
    baselines = []
    for number in (1, 2):
        log = evidence_root / f'{stage}-baseline-{number}.log'
        result = evidence_root / f'{stage}-baseline-{number}.normalized.json'
        for path in (log, result):
            _components_without_symlinks(work, path)
            _regular(path, 'Stage baseline')
        baselines.append({'log': str(log.relative_to(work)), 'sha256': _sha256(log),
                          'result': str(result.relative_to(work))})
    stage_root.mkdir(mode=0o700)
    (stage_root / 'files').mkdir(mode=0o700)
    records = [_path_record(work, stage_root, value) for value in paths]
    document = {
        'schema_version': 1, 'run_id': run['run_id'], 'stage': stage,
        'directory': str(stage_root), 'work_root': str(work),
        'parent_commit': parent_commit,
        'git_status_porcelain_v2': subprocess.check_output(
            ['git', 'status', '--porcelain=v2', '--untracked-files=all'],
            cwd=work, text=True),
        'baseline': baselines, 'paths': records, 'allowed_diff_paths': paths,
        'status': 'backed-up',
    }
    manifest = stage_root / 'manifest.json'
    _exclusive_json(manifest, document)
    _fsync_directory(stage_root)
    return manifest


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(['git', *arguments], cwd=root, text=True).strip()


def verify_backup(manifest: Path) -> dict:
    document = load_stage_manifest(manifest)
    work = Path(document['work_root'])
    stage_root = Path(document['directory'])
    if {path.name for path in stage_root.iterdir()} != {'manifest.json', 'files'}:
        raise ValueError(f'Unlisted content in stage backup: {stage_root}')
    _directory(stage_root / 'files', 'Backup files root')
    expected_files = set()
    for item in document['paths']:
        destination = stage_root / 'files' / item['path']
        _components_without_symlinks(stage_root, destination)
        if item['expected'] == 'absent':
            if _lstat(destination) is not None:
                raise ValueError(f'Absent path unexpectedly has a backup: {item["path"]}')
            continue
        info = _regular(destination, 'Backup')
        if stat.S_IMODE(info.st_mode) != item['mode']:
            raise ValueError(f'Backup mode mismatch: {item["path"]}')
        if _sha256(destination) != item['sha256']:
            raise ValueError(f'Backup SHA256 mismatch: {item["path"]}')
        expected_files.add(destination.relative_to(stage_root / 'files').as_posix())
    expected_directories = {
        parent.as_posix()
        for filename in expected_files
        for parent in PurePosixPath(filename).parents
        if parent != PurePosixPath('.')
    }
    for path in (stage_root / 'files').rglob('*'):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f'Symlink in backup payload: {path}')
        if stat.S_ISDIR(info.st_mode):
            if path.relative_to(stage_root / 'files').as_posix() not in expected_directories:
                raise ValueError(f'Unlisted backup directory: {path}')
            continue
        if stat.S_ISREG(info.st_mode) and path.relative_to(stage_root / 'files').as_posix() not in expected_files:
            raise ValueError(f'Unlisted backup payload: {path}')
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f'Unsupported backup payload: {path}')
    for entry in document['baseline']:
        log = work / entry['log']
        result = work / entry['result']
        _components_without_symlinks(work, log)
        _components_without_symlinks(work, result)
        _regular(log, 'Baseline log')
        _regular(result, 'Baseline result')
        if _sha256(log) != entry['sha256']:
            raise ValueError(f'Baseline SHA256 mismatch: {log}')
    return document


def extend_stage(manifest: Path, value: str) -> None:
    document = verify_backup(manifest)
    if document['status'] != 'backed-up':
        raise ValueError('Only a backed-up stage can be extended')
    _relative(value)
    if value in document['allowed_diff_paths']:
        raise ValueError(f'Path is already backed up: {value}')
    work = Path(document['work_root'])
    stage_root = Path(document['directory'])
    record = _path_record(work, stage_root, value)
    document['paths'] = sorted([*document['paths'], record], key=lambda item: item['path'])
    document['allowed_diff_paths'] = sorted([*document['allowed_diff_paths'], value])
    _replace_json(Path(manifest), document)


def verify_stage(manifest: Path, commit: str) -> dict:
    document = verify_backup(manifest)
    work = Path(document['work_root'])
    resolved_commit = git(work, 'rev-parse', f'{commit}^{{commit}}')
    subprocess.run(['git', 'merge-base', '--is-ancestor', document['parent_commit'],
                    resolved_commit], cwd=work, check=True)
    changed = subprocess.check_output(
        ['git', 'diff', '--name-only', '-z', document['parent_commit'], resolved_commit],
        cwd=work).decode('utf-8').split('\0')
    outside = set(changed) - {''} - set(document['allowed_diff_paths'])
    if outside:
        raise ValueError(f'Committed diff is outside stage allow-set: {sorted(outside)}')
    if document['status'] != 'ready':
        document['status'] = 'ready'
        _replace_json(Path(manifest), document)
    return {'stage': document['stage'], 'commit': resolved_commit,
            'changed_paths': sorted(set(changed) - {''}), 'status': document['status']}


def _verify_prior_receipt(path: Path, run: dict, sibling: dict) -> None:
    document = _read_json(path)
    expected = Path(run['work_root']) / '.build/optimization-backups' / run['run_id'] / sibling['directory']
    keys = {'schema_version', 'run_id', 'stage', 'deleted_path',
            'manifest_sha256', 'deleted_at_utc', 'sibling_manifest_sha256'}
    if (set(document) != keys or document['schema_version'] != 1
            or document['run_id'] != run['run_id'] or document['stage'] != sibling['name']
            or document['deleted_path'] != str(expected)
            or type(document['manifest_sha256']) is not str
            or HEX_SHA.fullmatch(document['manifest_sha256']) is None
            or type(document['deleted_at_utc']) is not str
            or type(document['sibling_manifest_sha256']) is not dict):
        raise ValueError(f'Invalid prior deletion receipt: {path}')


def delete_stage(run_manifest: Path, stage: str, receipt_root: Path) -> Path:
    run = load_run_manifest(run_manifest)
    work = Path(run['work_root'])
    expected_receipts = work / run['receipts_root']
    if Path(os.path.abspath(receipt_root)) != expected_receipts:
        raise ValueError('Receipt root must match the registered external directory')
    _components_without_symlinks(work, expected_receipts)
    _directory(expected_receipts, 'Receipt root')
    entry = next((item for item in run['stages'] if item['name'] == stage), None)
    if entry is None:
        raise ValueError(f'Unregistered stage: {stage}')
    run_root = Path(run_manifest).parent
    stage_root = run_root / entry['directory']
    _components_without_symlinks(work, stage_root)
    _directory(stage_root, 'Stage backup')
    manifest = stage_root / 'manifest.json'
    document = verify_backup(manifest)
    if document['status'] != 'ready':
        raise ValueError('Stage backup is not marked ready')
    receipt = expected_receipts / f'{stage}.json'
    if _lstat(receipt) is not None:
        raise FileExistsError(receipt)
    sibling_hashes = {}
    for sibling in run['stages']:
        if sibling['name'] == stage:
            continue
        other = run_root / sibling['directory'] / 'manifest.json'
        if _lstat(other) is None:
            previous_receipt = expected_receipts / f'{sibling["name"]}.json'
            _verify_prior_receipt(previous_receipt, run, sibling)
            continue
        sibling_document = verify_backup(other)
        if sibling_document['status'] != 'ready':
            raise ValueError(f'Sibling stage is not ready: {sibling["name"]}')
        sibling_hashes[sibling['name']] = _sha256(other)
    record = {
        'schema_version': 1, 'run_id': run['run_id'], 'stage': stage,
        'deleted_path': str(stage_root), 'manifest_sha256': _sha256(manifest),
        'deleted_at_utc': datetime.now(timezone.utc).isoformat(),
        'sibling_manifest_sha256': sibling_hashes,
    }
    temporary = expected_receipts / f'.{stage}.json.tmp-{uuid.uuid4()}'
    _exclusive_json(temporary, record)
    shutil.rmtree(stage_root)
    for sibling_name, expected in sibling_hashes.items():
        sibling = next(item for item in run['stages'] if item['name'] == sibling_name)
        other = run_root / sibling['directory'] / 'manifest.json'
        verify_backup(other)
        if _sha256(other) != expected:
            raise ValueError(f'Sibling backup changed while deleting {stage}: {sibling_name}')
    os.replace(temporary, receipt)
    _fsync_directory(expected_receipts)
    _fsync_directory(run_root)
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest='action', required=True)
    init = subcommands.add_parser('init-run')
    init.add_argument('--run-id', required=True)
    init.add_argument('--source-root', type=Path, required=True)
    init.add_argument('--work-root', type=Path, default=Path(__file__).resolve().parents[1])
    init.add_argument('--stages', nargs='+', required=True)
    create = subcommands.add_parser('create-stage')
    create.add_argument('--run-id', required=True)
    create.add_argument('--stage', required=True)
    create.add_argument('--parent', required=True)
    create.add_argument('--paths-file', type=Path, required=True)
    extend = subcommands.add_parser('extend-stage')
    extend.add_argument('--manifest', type=Path, required=True)
    extend.add_argument('--path', required=True)
    verify = subcommands.add_parser('verify-stage')
    verify.add_argument('--manifest', type=Path, required=True)
    verify.add_argument('--commit', required=True)
    delete = subcommands.add_parser('delete-stage')
    delete.add_argument('--run-manifest', type=Path, required=True)
    delete.add_argument('--stage', required=True)
    delete.add_argument('--receipt-root', type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.action == 'init-run':
        result = init_run(arguments.work_root, arguments.source_root,
                          arguments.run_id, tuple(arguments.stages))
    elif arguments.action == 'create-stage':
        work = Path(__file__).resolve().parents[1]
        run = work / '.build/optimization-backups' / arguments.run_id / 'run-manifest.json'
        result = create_stage(run, arguments.stage, arguments.parent, arguments.paths_file)
    elif arguments.action == 'extend-stage':
        extend_stage(arguments.manifest, arguments.path)
        result = load_stage_manifest(arguments.manifest)['allowed_diff_paths']
    elif arguments.action == 'verify-stage':
        result = verify_stage(arguments.manifest, arguments.commit)
    else:
        result = delete_stage(arguments.run_manifest, arguments.stage, arguments.receipt_root)
    print(json.dumps({'result': str(result)}, sort_keys=True))


if __name__ == '__main__':
    main()
