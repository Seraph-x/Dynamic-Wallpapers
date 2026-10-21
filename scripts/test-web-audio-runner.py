#!/usr/bin/env python3
"""Runner contract tests; all child process execution is replaced at the test boundary."""
import copy
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

MODULE = runpy.run_path(str(Path(__file__).with_name('test-web-audio.py')))
MARKER = ('WEB_AUDIO PASS webgl=1 fixture-progress=1 native-gain=1 gates=1 pause-close=1 '
          'reload=1 shutdown=1 default-covered-samples=zero continuous=unverified physicalAcoustics=unverified')
PAIR_MARKER = ('WEB_AUDIO_PAIR PASS independent-sources=1 mixing=1 shared-fade=1 close-isolation=1 gates=1 '
               'reload=1 shutdown=1 default-covered-samples=zero continuous=unverified physicalAcoustics=unverified')


def evidence():
    capture = {'processID': 123, 'captureStoppedAndDrained': True, 'errors': [],
               'packets': [{'start': 1, 'end': 1.01, 'energy': 0, 'samples': 960}]}
    return {'native-capture.json': copy.deepcopy(capture), 'default-capture.json': copy.deepcopy(capture),
            'windows.json': [{'name': 'prepared', 'start': 1, 'end': 2, 'expectsSilence': True}],
            'native-analysis.json': [{'name': 'prepared', 'stableRMS': 0, 'stablePackets': 12}],
            'default-analysis.json': [{'name': 'default-prepared', 'stableRMS': 0, 'stablePackets': 12}]}


class RunnerTests(unittest.TestCase):
    def invoke(self, artifacts, status=0, marker=MARKER, error=None, pair=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('.build/dependencies/cef/WebAudioTests.app/Contents/MacOS/WebAudioTests',
                         '.build/dependencies/ffmpeg/install/bin/ffmpeg'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('test-boundary-only')
            output = root / '.build/verification/web-audio/test-run'
            def child(*args, **kwargs):
                (output / 'test.log').write_text(marker)
                for name, value in artifacts.items():
                    (output / name).write_text(value if isinstance(value, str) else json.dumps(value))
                if error:
                    raise error
                return status
            globals_ = MODULE['main'].__globals__
            with patch.dict(globals_, {'__file__': str(root / 'scripts/test-web-audio.py')}), \
                 patch('sys.argv', ['test-web-audio.py', *(['--pair'] if pair else [])]), patch('uuid.uuid4', return_value='test-run'), \
                 patch('subprocess.run'), patch('runpy.run_path', return_value={'run_tests': child}):
                try:
                    result = MODULE['main']()
                except Exception:
                    self.assertEqual(json.loads((output / 'result.json').read_text())['test_exit'], 1)
                    raise
            self.assertEqual(json.loads((output / 'result.json').read_text())['test_exit'], result)
            return result

    def test_missing_each_evidence_file_rejected(self):
        for filename in evidence():
            with self.subTest(filename=filename):
                data = evidence(); del data[filename]
                with self.assertRaises((ValueError, OSError)):
                    self.invoke(data)

    def test_invalid_json_rejected(self):
        data = evidence(); data['native-capture.json'] = '{'
        with self.assertRaises(ValueError): self.invoke(data)

    def test_empty_or_failed_capture_rejected(self):
        for field, value in [('packets', []), ('errors', ['capture failed']), ('captureStoppedAndDrained', False)]:
            with self.subTest(field=field):
                data = evidence(); data['default-capture.json'][field] = value
                with self.assertRaises(ValueError): self.invoke(data)
        for filename in ['windows.json', 'native-analysis.json', 'default-analysis.json']:
            with self.subTest(filename=filename):
                data = evidence(); data[filename] = []
                with self.assertRaises(ValueError): self.invoke(data)

    def test_malformed_packet_and_unmatched_report_rejected(self):
        data = evidence(); data['native-capture.json']['packets'][0]['energy'] = float('nan')
        with self.assertRaises(ValueError): self.invoke(data)
        data = evidence(); data['native-analysis.json'][0]['name'] = 'unobserved'
        with self.assertRaises(ValueError): self.invoke(data)

    def test_complete_evidence_accepted(self):
        self.assertEqual(self.invoke(evidence()), 0)

    def test_pair_requires_its_durable_analysis(self):
        with self.assertRaises((ValueError, OSError)):
            self.invoke(evidence(), marker=PAIR_MARKER, pair=True)
        for value in [{}, {'mixEnergyRatio': 1, 'fadeMiddleEnergyRatio': float('nan'), 'rampStart': 1}]:
            data = evidence(); data['pair-analysis.json'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.invoke(data, marker=PAIR_MARKER, pair=True)
        data = evidence()
        data['pair-analysis.json'] = {'mixEnergyRatio': 1, 'fadeMiddleEnergyRatio': 0.25, 'rampStart': 1}
        self.assertEqual(self.invoke(data, marker=PAIR_MARKER, pair=True), 0)

    def test_nonzero_and_timeout_preserved(self):
        for status in [7, 124]: self.assertEqual(self.invoke({}, status=status), status)

    def test_exception_and_missing_marker_record_failure(self):
        with self.assertRaises(RuntimeError): self.invoke({}, error=RuntimeError('supervisor failed'))
        with self.assertRaises(ValueError): self.invoke(evidence(), marker='WEB_AUDIO PASS')


if __name__ == '__main__':
    unittest.main()
