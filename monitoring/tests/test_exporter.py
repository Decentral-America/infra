"""Unit tests for monitoring/exporter.py. Run: python3 -m unittest discover -s monitoring/tests -p 'test_*.py'"""
import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "exporter", pathlib.Path(__file__).resolve().parent.parent / "exporter.py")
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)


class MetricsTest(unittest.TestCase):
    def setUp(self):
        # No network: every probe is stubbed.
        exporter.fetch = lambda url: None
        exporter.fetch_with_status = lambda url: (None, None)
        exporter.probe_status = lambda url: 200
        exporter.NODES = []
        exporter.TLS_HOSTS = ["ok.example", "broken.example"]
        exporter.tls_not_after = lambda host: 1800000000.0 if host == "ok.example" else None

    def test_tls_expiry_exported_per_host(self):
        out = exporter.metrics()
        self.assertIn('dcc_tls_cert_expiry_timestamp_seconds{host="ok.example"} 1800000000', out)
        self.assertIn('dcc_tls_cert_probe_ok{host="ok.example"} 1', out)
        self.assertIn('dcc_tls_cert_probe_ok{host="broken.example"} 0', out)
        self.assertNotIn('dcc_tls_cert_expiry_timestamp_seconds{host="broken.example"}', out)

    def test_faucet_is_not_probed(self):
        self.assertNotIn("faucet", [name for name, _ in exporter.SERVICES])
        self.assertNotIn('service="faucet"', exporter.metrics())


if __name__ == "__main__":
    unittest.main()
