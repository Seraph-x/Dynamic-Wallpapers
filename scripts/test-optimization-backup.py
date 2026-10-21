#!/usr/bin/env python3
"""Backup manifests, path safety, copy verification and deletion receipts."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import optimization_backup as backup


ROOT = Path(__file__).resolve().parents[1]
RUN_ID = 'remaining-structure-20260921T153955Z'


def git(root, *arguments):
    return subprocess.check_output(['git', *arguments], cwd=root, text=True).strip()


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name) / 'work'
        self.work.mkdir()
        self.work = self.work.resolve(strict=True)
        git(self.work, 'init', '-q')
        git(self.work, 'config', 'user.name', 'Backup Test')
        git(self.work, 'config', 'user.email', 'backup@test.invalid')
        (self.work / 'tracked.txt').write_text('original\n')
        git(self.work, 'add', 'tracked.txt')
        git(self.work, 'commit', '-qm', 'baseline')
        self.parent = git(self.work, 'rev-parse', 'HEAD')
        self.run = backup.init_run(
            self.work, self.work, 'test-run-20260921T153955Z',
            ('stage3', 'stage4', 'stage5'))
        self.run_root = self.run.parent
        self.verification = self.work / '.build/verification/test-run-20260921T153955Z'
        self.verification.mkdir(parents=True)
        for number in (1, 2):
            (self.verification / f'stage3-baseline-{number}.log').write_text('baseline\n')
            (self.verification / f'stage3-baseline-{number}.normalized.json').write_text('{}\n')
        self.allow_set = self.verification / 'stage3-allow-set.txt'
        self.allow_set.write_text('new.txt\ntracked.txt\n')

    def stage(self):
        return backup.create_stage(self.run, 'stage3', self.parent, self.allow_set)

    def ready_stages(self):
        manifest = self.stage()
        siblings = []
        for stage in ('stage4', 'stage5'):
            for number in (1, 2):
                (self.verification / f'{stage}-baseline-{number}.log').write_text('baseline\n')
                (self.verification / f'{stage}-baseline-{number}.normalized.json').write_text('{}\n')
            allow = self.verification / f'{stage}-allow-set.txt'
            allow.write_text('tracked.txt\n')
            siblings.append(backup.create_stage(self.run, stage, self.parent, allow))
        git(self.work, 'commit', '--allow-empty', '-qm', 'stage complete')
        commit = git(self.work, 'rev-parse', 'HEAD')
        for stage_manifest in [manifest, *siblings]:
            backup.verify_stage(stage_manifest, commit)
        return manifest, siblings

    def test_existing_bootstrap_manifests_parse_without_migration(self):
        run = ROOT / '.build/optimization-backups' / RUN_ID / 'run-manifest.json'
        stage = run.parent / 'stage3-product-configuration-20260921T153955Z/manifest.json'
        self.assertEqual(backup.load_run_manifest(run)['schema_version'], 1)
        parsed = backup.load_stage_manifest(stage)
        self.assertEqual(parsed['stage'], 'stage3')
        self.assertEqual(parsed['work_root'], str(ROOT))
        self.assertGreater(len(parsed['paths']), 90)
        backup.verify_backup(stage)

    def test_new_run_rejects_existing_or_symlinked_root(self):
        with self.assertRaises(FileExistsError):
            backup.init_run(self.work, self.work, 'test-run-20260921T153955Z', ('stage3',))
        linked = self.work / '.build/optimization-backups/linked'
        linked.symlink_to(self.run_root, target_is_directory=True)
        with self.assertRaises(ValueError):
            backup.load_run_manifest(linked / 'run-manifest.json')

    def test_stage_records_absence_and_verifies_hash_and_mode(self):
        manifest = self.stage()
        parsed = backup.load_stage_manifest(manifest)
        self.assertEqual([item['path'] for item in parsed['paths']], ['new.txt', 'tracked.txt'])
        self.assertEqual(parsed['paths'][0]['expected'], 'absent')
        self.assertEqual(parsed['paths'][1]['expected'], 'existing')
        copied = manifest.parent / 'files/tracked.txt'
        self.assertEqual(copied.read_text(), 'original\n')
        backup.verify_backup(manifest)
        copied.write_text('tampered\n')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            backup.verify_backup(manifest)

    def test_mode_mismatch_and_dangling_symlink_are_rejected(self):
        manifest = self.stage()
        copied = manifest.parent / 'files/tracked.txt'
        copied.chmod(0o600 if copied.stat().st_mode & 0o777 != 0o600 else 0o644)
        with self.assertRaisesRegex(ValueError, 'mode'):
            backup.verify_backup(manifest)
        copied.chmod(0o644)
        copied.unlink()
        copied.symlink_to('missing')
        with self.assertRaisesRegex(ValueError, '[Ss]ymlink|regular'):
            backup.verify_backup(manifest)

    def test_unlisted_stage_content_blocks_verification_and_deletion(self):
        manifest = self.stage()
        (manifest.parent / 'unexpected-note.txt').write_text('keep me\n')
        with self.assertRaisesRegex(ValueError, 'Unlisted'):
            backup.verify_backup(manifest)

    def test_extension_is_atomic_and_does_not_mutate_sibling(self):
        manifest = self.stage()
        sibling = self.run_root / 'stage4-structured-failures-20260921T153955Z'
        sibling.mkdir()
        (sibling / 'marker').write_text('unchanged\n')
        before = hashlib.sha256((sibling / 'marker').read_bytes()).hexdigest()
        (self.work / 'later.txt').write_text('later\n')
        backup.extend_stage(manifest, 'later.txt')
        parsed = backup.load_stage_manifest(manifest)
        self.assertEqual(parsed['allowed_diff_paths'], ['later.txt', 'new.txt', 'tracked.txt'])
        self.assertEqual((manifest.parent / 'files/later.txt').read_text(), 'later\n')
        self.assertEqual(hashlib.sha256((sibling / 'marker').read_bytes()).hexdigest(), before)
        self.assertFalse(any(manifest.parent.glob('manifest.json.tmp-*')))

    def test_path_traversal_symlink_parent_and_non_direct_child_fail(self):
        manifest = self.stage()
        for path in ('../outside', '/tmp/outside', 'folder/../../outside'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                backup.extend_stage(manifest, path)
        (self.work / 'linked').symlink_to(self.work, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            backup.extend_stage(manifest, 'linked/other.txt')
        document = json.loads(manifest.read_text())
        document['directory'] = str(manifest.parent.parent / 'nested' / manifest.parent.name)
        with self.assertRaises(ValueError):
            backup.validate_stage_document(document, manifest)

    def test_verify_stage_rejects_unlisted_diff_and_keeps_backup(self):
        manifest = self.stage()
        (self.work / 'tracked.txt').write_text('changed\n')
        (self.work / 'unexpected.txt').write_text('unexpected\n')
        git(self.work, 'add', 'tracked.txt', 'unexpected.txt')
        git(self.work, 'commit', '-qm', 'changes')
        with self.assertRaisesRegex(ValueError, 'allow'):
            backup.verify_stage(manifest, git(self.work, 'rev-parse', 'HEAD'))
        self.assertTrue(manifest.parent.is_dir())

    def test_delete_refuses_mismatch_and_writes_receipt_outside_stage(self):
        manifest, _ = self.ready_stages()
        receipt_root = self.work / '.build/optimization-backup-receipts/test-run-20260921T153955Z'
        with self.assertRaises(ValueError):
            backup.delete_stage(self.run, 'stage3', manifest.parent / 'receipt')
        self.assertTrue(manifest.parent.is_dir())
        copied = manifest.parent / 'files/tracked.txt'
        copied.write_text('tampered\n')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            backup.delete_stage(self.run, 'stage3', receipt_root)
        copied.write_text('original\n')
        manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()
        receipt = backup.delete_stage(self.run, 'stage3', receipt_root)
        self.assertFalse(manifest.parent.exists())
        self.assertTrue(receipt.is_file())
        document = json.loads(receipt.read_text())
        self.assertEqual(document['stage'], 'stage3')
        self.assertEqual(document['deleted_path'], str(manifest.parent))
        self.assertEqual(document['manifest_sha256'], manifest_hash)
        self.assertEqual(receipt.parent, receipt_root)

    def test_delete_rejects_mutated_sibling_without_removing_requested_stage(self):
        manifest, siblings = self.ready_stages()
        (siblings[0].parent / 'files/tracked.txt').write_text('changed\n')
        receipt_root = self.work / '.build/optimization-backup-receipts/test-run-20260921T153955Z'
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            backup.delete_stage(self.run, 'stage3', receipt_root)
        self.assertTrue(manifest.parent.is_dir())
        self.assertFalse((receipt_root / 'stage3.json').exists())


if __name__ == '__main__':
    unittest.main()
