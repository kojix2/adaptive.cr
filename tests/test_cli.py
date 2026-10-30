"""Connection smoke checks; no real basecalling or MinKNOW is required."""
import json
from pathlib import Path
import subprocess
import struct
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class CliTest(unittest.TestCase):
    def run_check(self, arguments=None, **settings):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(reference=str(ROOT/'examples/reference.fa'), policy='all', **settings)
            path = Path(directory)/'config.json'
            path.write_text(json.dumps(config))
            return subprocess.run([str(ROOT/'bin/adaptive'), '-c', str(path), *(arguments or ['--check-backend'])],
                                  cwd=ROOT, capture_output=True, text=True, timeout=5)

    def test_explicit_fixture_connects_without_minknow(self):
        result = self.run_check(allow_test_bridge=True, fixture_sequence='ACGT')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('fixture', result.stdout)

    def test_unavailable_official_server_fails_within_timeout(self):
        result = self.run_check(dorado_address='ipc:///tmp/adaptive-absent-'+str(uuid.uuid4()),
                                bridge_timeout_ms=1000, bridge_startup_timeout_ms=1000)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('adaptive:', result.stderr)
        self.assertNotIn('OK:', result.stdout)

    def test_diagnostic_signal_uses_full_binary_adapter_path(self):
        with tempfile.TemporaryDirectory() as directory:
            signal = Path(directory)/'signal.i16'
            metadata = Path(directory)/'signal.json'
            signal.write_bytes(struct.pack('<200h', *range(-100, 100)))
            metadata.write_text(json.dumps(dict(offset=-12.5, scale=0.14, sample_rate=5000, start_sample=123)))
            result = self.run_check(arguments=[f'--check-signal={signal}', f'--signal-metadata={metadata}'],
                                    allow_test_bridge=True, fixture_sequence='ACGT')
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual(value['check'], 'basecall')
            self.assertEqual(value['samples'], 200)
            self.assertEqual(value['sequences'], ['ACGT'])
            self.assertEqual(value['backend']['backend'], 'fixture')
            metadata.write_text(json.dumps(dict(offset=0, scale=0, sample_rate=5000, start_sample=0)))
            result = self.run_check(arguments=[f'--check-signal={signal}', f'--signal-metadata={metadata}'],
                                    allow_test_bridge=True, fixture_sequence='ACGT')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('calibration', result.stderr)

    def test_conflicting_modes_and_missing_metadata_fail(self):
        for arguments in (['--validate', '--check-backend'], ['--check-signal=missing'],
                          ['--signal-metadata=missing']):
            with self.subTest(arguments=arguments):
                result = self.run_check(arguments=arguments)
                self.assertNotEqual(result.returncode, 0)

    def test_missing_target_is_detected_before_live_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'config.json'
            path.write_text(json.dumps(dict(reference=str(ROOT/'examples/reference.fa'),
                                            targets=['misspelled-virus'])))
            result = subprocess.run([str(ROOT/'bin/adaptive'), '-c', str(path), '--validate'],
                                    cwd=ROOT, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('targets missing', result.stderr)

    def test_abnormal_startup_still_writes_end_event(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory)/'events.jsonl'
            path = Path(directory)/'config.json'
            path.write_text(json.dumps(dict(reference=str(ROOT/'examples/reference.fa'), policy='all',
                                            python='/nonexistent-adaptive-python', log=str(log), workers=2)))
            result = subprocess.run([str(ROOT/'bin/adaptive'), '-c', str(path)],
                                    cwd=ROOT, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            rows = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(rows[-1]['event'], 'end')
            self.assertEqual(rows[-1]['outcome'], 'error')
            self.assertTrue(any(row['event'] == 'error' for row in rows))


if __name__ == '__main__':
    unittest.main()
