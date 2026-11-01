"""Optional checks against the installed official ONT client, without a server."""
import importlib.util
import struct
import unittest
import uuid

from test_bridge import bridge
import test_cli


AVAILABLE = (importlib.util.find_spec('numpy') is not None
             and importlib.util.find_spec('pybasecall_client_lib') is not None)


@unittest.skipUnless(AVAILABLE, 'optional ONT client unavailable; install requirements.txt with a supported Python')
class OfficialClientTest(unittest.TestCase):
    def test_official_packaging_preserves_adc_and_calibration(self):
        request = dict(id='current', offset=-12.5, scale=0.14, sample_rate=5000, start_sample=1234)
        signal = struct.pack('<4h', -32768, -3, 0, 32767)
        read = bridge.package_signal(request, signal)
        self.assertEqual(read['raw_data'].tolist(), [-32768, -3, 0, 32767])
        self.assertEqual(read['daq_offset'], -12.5)
        self.assertEqual(read['daq_scaling'], 0.14)
        self.assertEqual(read['sampling_rate'], 5000)
        self.assertEqual(read['start_time'], 1234)

    def test_unavailable_official_server_fails_within_timeout(self):
        result = test_cli.CliTest().run_check(
            dorado_address='ipc:///tmp/adaptive-absent-'+str(uuid.uuid4()),
            bridge_timeout_ms=1000, bridge_startup_timeout_ms=1000)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('adaptive:', result.stderr)
        self.assertNotIn('OK:', result.stdout)


if __name__ == '__main__':
    unittest.main()
