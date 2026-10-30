"""Uses the actual ONT package_read serializer, without a Dorado GPU server."""
import importlib.util
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import unittest
import numpy as np

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
        self.signal = np.array([-32768, -3, 0, 32767], dtype='<i2').tobytes()

    def test_official_packaging_correlation_and_split_molecules(self):
        client = Client([[[result('stale', 'BAD')]],
                         [[result('current', 'ACG'), result('current', 'TTA')]]])
        sequences = bridge.basecall(client, self.request, self.signal, 1)
        self.assertEqual(sequences, ['ACG', 'TTA'])
        self.assertEqual(len(client.passed), 1)
        read = client.passed[0]
        self.assertEqual(read['raw_data'].tolist(), [-32768, -3, 0, 32767])
        self.assertEqual(read['daq_offset'], -12.5)
        self.assertEqual(read['daq_scaling'], 0.14)
        self.assertEqual(read['sampling_rate'], 5000)
        self.assertEqual(read['start_time'], 1234)

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
                             ('start_sample', -1), ('start_sample', 2**64), ('id', '')]:
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
        self.assertEqual(values[1], dict(id='current', sequences=['']))

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
