#!/usr/bin/env python3
"""Real process/lock/crash tests. The 60-second suite budget includes the harness build."""
import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest

from test import run_tests

ROOT = Path(__file__).resolve().parents[1]


class Peer:
    def __init__(self, command):
        # Inherit the suite's owned process group so the outer timeout also cleans up blocked peers.
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b''

    def event(self):
        deadline = time.monotonic() + 5
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise AssertionError(f'Harness event timed out: pid={self.process.pid}, output={self.buffer!r}')
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError(f'Harness closed output: {self.process.stderr.read().decode()}')
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\n', 1)
        result = json.loads(line)
        print(json.dumps({'pid': self.process.pid, **result}), flush=True)
        return result

    def send(self, line):
        self.process.stdin.write((line + '\n').encode())
        self.process.stdin.flush()

    def finish(self, expected=0):
        out, err = self.process.communicate(timeout=5)
        if self.process.returncode != expected:
            raise AssertionError(f'Harness exit {self.process.returncode}, expected {expected}: {out!r} {err!r}')
        return out, err

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate(timeout=5)


class ScreenSaverStorageProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        command = [sys.executable, str(ROOT / 'scripts/swift_sdk.py'), 'build', '--disable-sandbox']
        subprocess.run([*command, '--product', 'ScreenSaverLeaseHarness'], cwd=ROOT, check=True)
        binary_directory = subprocess.check_output([*command, '--show-bin-path'], cwd=ROOT, text=True).strip()
        cls.binary = Path(binary_directory) / 'ScreenSaverLeaseHarness'
        if not cls.binary.is_file():
            raise AssertionError(f'Missing built harness: {cls.binary}')

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='screensaver storage ', dir=ROOT / '.build')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'Export'
        self.command('init')

    def command(self, mode, *, succeeds=True):
        result = subprocess.run([str(self.binary), str(self.root), mode], capture_output=True, text=True)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            for event in events:
                print(json.dumps(event), flush=True)
            return events[-1]
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def peer(self, mode):
        peer = Peer([str(self.binary), str(self.root), mode])
        self.addCleanup(peer.close)
        return peer

    def assert_exclusive_busy(self, descriptor):
        with self.assertRaises(BlockingIOError):
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_cross_process_read_only_leases_and_kernel_release_after_kill(self):
        first = self.command('publish')['generation']
        lease = self.root / 'generations' / first / '.lease'
        lease.chmod(0o444)
        one, two = self.peer('hold'), self.peer('hold')
        self.assertEqual(one.event()['generation'], first)
        self.assertEqual(two.event()['generation'], first)
        self.command('publish')
        with lease.open('rb') as handle:
            self.assert_exclusive_busy(handle)
            self.assertEqual(self.command('gc')['retained'], [first])
            one.send('close')
            self.assertEqual(one.event()['event'], 'closed')
            one.finish()
            self.assert_exclusive_busy(handle)
            two.process.kill()
            two.finish(expected=-9)
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.command('gc')['removed'], [first])

    def test_same_process_reader_close_does_not_release_its_sibling(self):
        first = self.command('publish')['generation']
        pair = self.peer('hold-two')
        self.assertEqual(pair.event()['generation'], first)
        self.command('publish')
        pair.send('close-one')
        self.assertEqual(pair.event()['event'], 'oneClosed')
        self.assertEqual(self.command('gc')['retained'], [first])
        pair.send('close-two')
        self.assertEqual(pair.event()['event'], 'closed')
        pair.finish()
        self.assertEqual(self.command('gc')['removed'], [first])

    def test_active_staging_is_not_recovered_until_writer_crashes(self):
        writer = self.peer('stage')
        stage = writer.event()['generation']
        failed = self.command('recover', succeeds=False)
        self.assertIn('屏保文件锁正忙', failed.stderr)
        self.assertEqual(self.command('gc')['removed'], [])
        self.assertTrue((self.root / 'staging' / stage).is_dir())
        writer.process.kill()
        writer.finish(expected=-9)
        self.assertEqual(self.command('recover')['removed'], [stage])
        self.assertEqual(list((self.root / 'staging').iterdir()), [])
        self.command('publish')

    def test_gc_cannot_enter_between_registration_and_pointer_commit(self):
        old = self.command('publish')['generation']
        old_pointer = (self.root / 'current.json').read_bytes()
        writer = self.peer('pause-register')
        registered = writer.event()['generation']
        self.assertEqual((self.root / 'current.json').read_bytes(), old_pointer)
        with (self.root / '.catalog.lock').open('rb') as lock:
            self.assert_exclusive_busy(lock)
        collector = self.peer('gc')
        self.assertEqual(collector.event()['event'], 'gcStarted')
        self.assertFalse(select.select([collector.process.stdout], [], [], 0.15)[0], 'GC crossed the catalog lock')
        self.assertTrue((self.root / 'generations' / registered).is_dir())
        writer.send('commit')
        self.assertEqual(writer.event()['generation'], registered)
        writer.finish()
        collected = collector.event()
        self.assertEqual(collected['removed'], [old])
        collector.finish()
        self.assertEqual(self.command('read')['generation'], registered)
        self.assertTrue((self.root / 'generations' / registered / 'manifest.json').is_file())

    def test_kill_after_registration_keeps_exact_old_pointer_and_collectable_orphan(self):
        old = self.command('publish')['generation']
        old_pointer = (self.root / 'current.json').read_bytes()
        writer = self.peer('pause-register')
        orphan = writer.event()['generation']
        self.assertNotEqual(old, orphan)
        self.assertTrue((self.root / 'generations' / orphan / 'manifest.json').is_file())
        writer.process.kill()
        writer.finish(expected=-9)
        self.assertEqual((self.root / 'current.json').read_bytes(), old_pointer)
        self.assertEqual(self.command('read')['generation'], old)
        self.assertEqual(self.command('gc')['removed'], [orphan])
        self.assertEqual(self.command('recover')['removed'], [])
        self.command('publish')

    def test_gc_crash_after_last_lease_unlink_leaves_only_a_recoverable_empty_directory(self):
        old = self.command('publish')['generation']
        current = self.command('publish')['generation']
        before = (self.root / 'current.json').read_bytes()
        collector = self.peer('pause-last-unlink')
        self.assertEqual(collector.event()['event'], 'gcStarted')
        self.assertEqual(collector.event()['generation'], old)
        self.assertEqual(list((self.root / 'generations' / old).iterdir()), [])
        collector.process.kill()
        collector.finish(expected=-9)
        self.assertEqual((self.root / 'current.json').read_bytes(), before)
        self.assertEqual(self.command('gc')['removed'], [old])
        self.assertEqual(self.command('read')['generation'], current)

    def test_disabled_pointer_blocks_new_readers_but_not_existing_reader(self):
        old = self.command('publish')['generation']
        reader = self.peer('hold')
        self.assertEqual(reader.event()['generation'], old)
        self.assertIsNone(self.command('disable')['generation'])
        self.assertIsNone(self.command('read')['generation'])
        self.assertEqual(self.command('gc')['retained'], [old])
        reader.send('close')
        self.assertEqual(reader.event()['event'], 'closed')
        reader.finish()
        self.assertEqual(self.command('gc')['removed'], [old])


if __name__ == '__main__':
    if '--worker' not in sys.argv:
        raise SystemExit(run_tests([sys.executable, str(Path(__file__).resolve()), '--worker', *sys.argv[1:]],
                                  label='ScreenSaver storage tests'))
    unittest.main(argv=[sys.argv[0], *[value for value in sys.argv[1:] if value != '--worker']])
