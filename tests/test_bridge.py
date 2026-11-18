"""Portable bridge protocol/decision tests; no native ONT client is required."""
import importlib.util
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bridge', ROOT / 'scripts/dorado_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class Client:
    def __init__(self, replies):
        self.replies = iter(replies)
        self.passed = []

    def pass_reads(self, reads):
        self.passed.extend(reads)
        return True

    def get_completed_reads(self):
        return next(self.replies, [])


def result(read_id, sequence):
    return dict(metadata=dict(read_id=read_id), datasets=dict(sequence=sequence))


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.request = dict(id='current', offset=-12.5, scale=0.14, sample_rate=5000, start_sample=1234)
        self.signal = struct.pack('<4h', -32768, -3, 0, 32767)
        # Only the external serializer is replaced. Correlation, queue handling,
        # timeouts, and the subprocess wire protocol use production code.
        self.packager = patch.object(bridge, 'package_signal', return_value={'read_id': 'current'})
        self.package_signal = self.packager.start()
        self.addCleanup(self.packager.stop)

    def test_correlation_and_split_molecules(self):
        client = Client([[[result('stale', 'BAD')]],
                         [[result('current', 'ACG'), result('current', 'TTA')]]])
        sequences = bridge.basecall(client, self.request, self.signal, 1)
        self.assertEqual(sequences, ['ACG', 'TTA'])
        self.package_signal.assert_called_once_with(self.request, self.signal)
        self.assertEqual(client.passed, [{'read_id': 'current'}])

    def test_timeout_does_not_resubmit(self):
        client = Client([])
        with self.assertRaises(TimeoutError):
            bridge.basecall(client, self.request, self.signal, 0.01)
        self.assertEqual(len(client.passed), 1)

    def test_queue_full_fails_immediately_without_resubmitting(self):
        client = Client([])
        client.pass_reads = lambda reads: False
        with self.assertRaisesRegex(RuntimeError, "queue is full"):
            bridge.basecall(client, self.request, self.signal, 1)

    def test_bytes_sequences_are_decoded_and_invalid_results_rejected(self):
        self.assertEqual(bridge.sequence_text(b'acgtn'), 'ACGTN')
        for value in (None, 42, "b'ACGT'", 'ACGT;bad', b'\xff'):
            with self.assertRaises((ValueError, UnicodeError)):
                bridge.sequence_text(value)

    def test_invalid_calibration_and_signal_headers_are_rejected(self):
        request = dict(self.request, bytes=len(self.signal))
        bridge.validate_request(request)
        for field, value in [('scale', 0), ('scale', -1), ('sample_rate', math.inf),
                             ('offset', math.nan), ('bytes', True), ('bytes', 3),
                             ('start_sample', -1), ('start_sample', 2**64), ('id', ''),
                             ('segments_only', 'true'), ('segments_only', 1),
                             ('signal_format', 'float32'), ('signal_format', 'adc_int16_be')]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                bridge.validate_request(dict(request, **{field: value}))

    def test_fixture_wire_protocol_and_empty_basecall(self):
        command = [sys.executable, str(ROOT / 'scripts/dorado_bridge.py'), '--address', 'test',
                   '--model', 'test', '--test-sequence', '']
        header = json.dumps(dict(self.request, bytes=len(self.signal))).encode() + b'\n'
        response = subprocess.run(command, input=header+self.signal, capture_output=True, check=True).stdout
        values = []
        while response:
            size, = struct.unpack('<I', response[:4])
            values.append(json.loads(response[4:4+size]))
            response = response[4+size:]
        self.assertEqual(values[0]['protocol'], 1)
        self.assertEqual(values[0]['backend'], 'fixture')
        self.assertIn('python', values[0])
        self.assertEqual(values[1]['id'], 'current')
        self.assertEqual(values[1]['sequences'], [''])
        self.assertEqual(values[1]['segments'], [dict(sequence='', quality=None, read_id='current')])

    def test_segments_only_avoids_duplicating_sequences_on_the_wire(self):
        command = [sys.executable, str(ROOT / 'scripts/dorado_bridge.py'), '--address', 'test',
                   '--model', 'test', '--test-sequence', 'ACGT']
        request = dict(self.request, bytes=len(self.signal), segments_only=True)
        response = subprocess.run(command, input=json.dumps(request).encode()+b'\n'+self.signal,
                                  capture_output=True, check=True).stdout
        handshake_size, = struct.unpack('<I', response[:4])
        response = response[4+handshake_size:]
        size, = struct.unpack('<I', response[:4])
        value = json.loads(response[4:4+size])
        self.assertEqual(value['segments'], [dict(sequence='ACGT', quality=None, read_id='current')])
        self.assertNotIn('sequences', value)

    def test_segments_keep_quality_and_parent_correlation(self):
        first = result('current', b'acg')
        first['datasets']['qstring'] = b'III'
        second = result('child', 'TTA')
        second['metadata']['parent_read_id'] = 'current'
        second['datasets']['qstring'] = 'JJJ'
        segments = bridge.basecall_segments(Client([[[first, second]]]), self.request, self.signal, 1)
        self.assertEqual(segments, [dict(sequence='ACG', quality='III', read_id='current'),
                                    dict(sequence='TTA', quality='JJJ', read_id='child')])
        for quality in ('II', 'II\n', 42):
            first['datasets']['qstring'] = quality
            with self.assertRaisesRegex(ValueError, 'quality'):
                bridge.segment_data(first)

    def test_official_parent_and_child_ids_and_native_timing_are_preserved(self):
        first = result('current', 'ACG')
        first['metadata'].update(strand_id='child-1', start_time=1234, duration=500,
                                 trimmed_samples=20, trimmed_duration=450)
        second = result('current', 'TTA')
        second['metadata']['strand_id'] = 'child-2'
        segments = bridge.basecall_segments(Client([[[first, second]]]), self.request, self.signal, 1)
        self.assertEqual([segment['read_id'] for segment in segments], ['child-1', 'child-2'])
        self.assertEqual(segments[0]['native_timing'], dict(start_time=1234, duration=500,
                                                         trimmed_samples=20, trimmed_duration=450))
        self.assertNotIn('native_timing', segments[1])
        self.assertTrue(all('signal_span' not in segment for segment in segments))
        for field in ('start_time', 'duration', 'trimmed_samples', 'trimmed_duration'):
            for value in (-1, True, 1.5, 2**64):
                with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'timing'):
                    broken = result('current', 'ACG')
                    broken['metadata'][field] = value
                    bridge.segment_data(broken)

    def test_explicit_full_read_limit_keeps_the_default_prefix_limit(self):
        size = 500002
        request = dict(self.request, bytes=size)
        with self.assertRaisesRegex(ValueError, 'signal size'):
            bridge.validate_request(request)
        bridge.validate_request(request, max_signal_bytes=size)
        command = [sys.executable, str(ROOT / 'scripts/dorado_bridge.py'), '--address', 'test',
                   '--model', 'test', '--test-sequence', 'ACGT', '--max-signal-bytes', str(size)]
        response = subprocess.run(command, input=json.dumps(request).encode()+b'\n'+bytes(size),
                                  capture_output=True, check=True).stdout
        header_size, = struct.unpack('<I', response[:4])
        self.assertEqual(json.loads(response[4:4+header_size])['max_signal_bytes'], size)
        self.assertIn(b'"sequences": ["ACGT"]', response)

    def test_response_limits_apply_to_sequence_and_quality_together(self):
        with self.assertRaisesRegex(ValueError, 'response too large'):
            bridge.emit(dict(sequence='A' * 1000, quality='I' * 1000), max_bytes=1024)
        command = [sys.executable, str(ROOT / 'scripts/dorado_bridge.py'), '--address', 'test',
                   '--model', 'test', '--test-sequence', '', '--max-response-bytes', '1023']
        response = subprocess.run(command, capture_output=True)
        self.assertNotEqual(response.returncode, 0)
        self.assertIn(b'max-response-bytes', response.stderr)

    def test_truncated_and_oversized_requests_fail(self):
        command = [sys.executable, str(ROOT / 'scripts/dorado_bridge.py'), '--address', 'test',
                   '--model', 'test', '--test-sequence', 'ACGT']
        for signal_size in (10, 500002):
            response = subprocess.run(command, input=json.dumps(dict(self.request, bytes=signal_size)).encode()+b'\n',
                                      capture_output=True)
            self.assertNotEqual(response.returncode, 0)
            self.assertNotIn(b'"sequences"', response.stdout)


if __name__ == '__main__':
    unittest.main()
