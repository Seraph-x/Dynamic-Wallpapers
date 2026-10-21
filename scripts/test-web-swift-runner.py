#!/usr/bin/env python3
"""Failure-record regression tests for the runner; no CEF process is started."""
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).with_name('test-web-swift.py')
BASE_RECORD = (b'WEB_SWIFT PASS frame=1 fit=1 pauseClosed=1 retainedFrame=1 '
               b'resumeReloaded=1 shutdown=1 audio=muted-only\n')
MIRROR_RECORD = (b'WEB_SWIFT_MIRROR PASS fullscreen=1 displayedChanges=1 sustained=1 '
                 b'uniquePage=1 audio=screen-only cleanup=1\n')
LIFECYCLE_MODE = b'WEB_SWIFT MODE lifecycle\n'
MIRROR_MODE = b'WEB_SWIFT MODE mirror-experiments\n'


class WebSwiftRunnerTests(unittest.TestCase):
    def run_case(self, log_bytes, child_exit=0, *, mirror_experiments=False,
                 mirror_fixture=True, check_command=None):
        with tempfile.TemporaryDirectory(prefix='dw-web-runner-') as directory:
            root = pathlib.Path(directory)
            executable = root / '.build/dependencies/cef/WebSwiftTests.app/Contents/MacOS/WebSwiftTests'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'runner-test-placeholder-never-executed')
            fixture = root / 'Tests/WebRuntimeHarness/fixture'
            fixture.mkdir(parents=True)
            (fixture / 'index.html').write_text('<canvas></canvas>')
            if mirror_fixture:
                mirror_source = root / 'Tests/WebRuntimeHarness/mirror-fixture'
                mirror_source.mkdir(parents=True)
                (mirror_source / 'index.html').write_text('<canvas id="dynamic"></canvas>')
            spec = importlib.util.spec_from_file_location('web_swift_runner', SCRIPT)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            module.__file__ = str(root / 'scripts/test-web-swift.py')

            def supervise(command, **options):
                self.assertEqual(options['timeout_seconds'], 60)
                if check_command is not None:
                    check_command(command)
                if log_bytes is not None:
                    pathlib.Path(command[-1]).write_bytes(log_bytes)
                return child_exit

            raised = None
            returned = None
            arguments = [str(SCRIPT), *(['--mirror-experiments'] if mirror_experiments else [])]
            with patch('sys.argv', arguments), patch.object(module.runpy, 'run_path',
                         return_value={'run_tests': supervise}):
                try:
                    returned = module.main()
                except (OSError, UnicodeError, ValueError) as error:
                    raised = error
                except SystemExit as error:
                    self.fail(f'Runner rejected supported arguments {arguments}: {error}')
            records = list((root / '.build/verification/web-swift').glob('*/result.json'))
            self.assertEqual(len(records), 1)
            return json.loads(records[0].read_text()), returned, raised

    def test_missing_log_remains_failed(self):
        result, _, error = self.run_case(None)
        self.assertIsInstance(error, FileNotFoundError)
        self.assertEqual(result['test_exit'], 1)

    def test_invalid_log_encoding_remains_failed(self):
        result, _, error = self.run_case(b'\xff')
        self.assertIsInstance(error, UnicodeError)
        self.assertEqual(result['test_exit'], 1)

    def test_partial_success_record_is_rejected(self):
        result, _, error = self.run_case(b'WEB_SWIFT PASS frame=1\n')
        self.assertIsInstance(error, ValueError)
        self.assertEqual(result['test_exit'], 1)

    def test_child_failure_keeps_original_exit(self):
        result, returned, error = self.run_case(None, 124)
        self.assertIsNone(error)
        self.assertEqual(returned, 124)
        self.assertEqual(result['test_exit'], 124)

    def test_default_lifecycle_does_not_require_a_mirror_fixture_or_result(self):
        result, returned, error = self.run_case(LIFECYCLE_MODE + BASE_RECORD, mirror_fixture=False)
        self.assertIsNone(error)
        self.assertEqual(returned, 0)
        self.assertEqual(result['test_exit'], 0)
        self.assertEqual(result['mode'], 'lifecycle')
        self.assertEqual(result['scope'], 'swift-cef-muted-frame-pause-reload-shutdown')

    def test_explicit_mirror_mode_requires_its_complete_result(self):
        result, _, error = self.run_case(MIRROR_MODE + BASE_RECORD, mirror_experiments=True)
        self.assertIsInstance(error, ValueError)
        self.assertEqual(result['test_exit'], 1)

    def test_mirror_success_does_not_replace_lifecycle_contract(self):
        result, _, error = self.run_case(MIRROR_MODE + MIRROR_RECORD, mirror_experiments=True)
        self.assertIsInstance(error, ValueError)
        self.assertEqual(result['test_exit'], 1)

    def test_incomplete_mirror_record_is_rejected(self):
        result, _, error = self.run_case(MIRROR_MODE + BASE_RECORD + b'WEB_SWIFT_MIRROR PASS fullscreen=1\n',
                                       mirror_experiments=True)
        self.assertIsInstance(error, ValueError)
        self.assertEqual(result['test_exit'], 1)

    def test_success_records_cannot_override_child_failure(self):
        result, returned, error = self.run_case(MIRROR_MODE + BASE_RECORD + MIRROR_RECORD, 9,
                                              mirror_experiments=True)
        self.assertIsNone(error)
        self.assertEqual(returned, 9)
        self.assertEqual(result['test_exit'], 9)

    def test_complete_record_and_child_success_required(self):
        result, returned, error = self.run_case(MIRROR_MODE + BASE_RECORD + MIRROR_RECORD,
                                              mirror_experiments=True)
        self.assertIsNone(error)
        self.assertEqual(returned, 0)
        self.assertEqual(result['test_exit'], 0)
        self.assertEqual(result['mode'], 'mirror-experiments')

    def test_default_lifecycle_rejects_unrequested_mirror_execution(self):
        result, _, error = self.run_case(LIFECYCLE_MODE + BASE_RECORD + MIRROR_RECORD)
        self.assertIsInstance(error, ValueError)
        self.assertEqual(result['test_exit'], 1)

    def test_result_mode_must_match_the_requested_mode(self):
        result, _, error = self.run_case(MIRROR_MODE + BASE_RECORD)
        self.assertIsInstance(error, ValueError)
        self.assertEqual(result['test_exit'], 1)

    def test_default_command_does_not_forward_or_copy_the_dynamic_fixture(self):
        def check_command(command):
            self.assertEqual(len(command), 7)
            self.assertEqual(command[2], 'exec "$1" "$2" > "$3" 2>&1')
            self.assertNotIn('--mirror-experiments', command)
            self.assertFalse((pathlib.Path(command[5]).parent / 'mirror-project').exists())

        result, returned, error = self.run_case(LIFECYCLE_MODE + BASE_RECORD, check_command=check_command)
        self.assertIsNone(error)
        self.assertEqual(returned, 0)
        self.assertEqual(result['test_exit'], 0)

    def test_static_and_dynamic_fixtures_are_isolated_and_forwarded(self):
        def check_command(command):
            self.assertEqual(len(command), 9)
            self.assertEqual(command[2], 'exec "$1" "$2" "$3" "$4" > "$5" 2>&1')
            self.assertEqual(command[6], '--mirror-experiments')
            static, dynamic = pathlib.Path(command[5]), pathlib.Path(command[7])
            self.assertNotEqual(static, dynamic)
            self.assertEqual((static / 'index.html').read_text(), '<canvas></canvas>')
            self.assertEqual((dynamic / 'index.html').read_text(), '<canvas id="dynamic"></canvas>')

        result, returned, error = self.run_case(MIRROR_MODE + BASE_RECORD + MIRROR_RECORD,
                                              mirror_experiments=True, check_command=check_command)
        self.assertIsNone(error)
        self.assertEqual(returned, 0)
        self.assertEqual(result['test_exit'], 0)


if __name__ == '__main__':
    unittest.main()
