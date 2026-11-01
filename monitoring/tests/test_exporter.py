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
        exporter.fetch_with_status = lambda url, data=None: (None, None)
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

    def test_committee_weight_share(self):
        # 2026-10-31 live shape: main 60.2M, three members ~7.3M.
        committee = [
            {"address": "31RPEK", "transactionId": "a", "balance": 6024666955480000},
            {"address": "31PmKN", "transactionId": "b", "balance": 734942267679893},
            {"address": "31XTtK", "transactionId": "c", "balance": 718126159840000},
            {"address": "31dLhq", "transactionId": "d", "balance": 728551865100000},
        ]
        out = "\n".join(exporter.committee_weight_lines('node="main-node"', committee))
        self.assertIn('dcc_committee_member_weight_share{node="main-node",address="31RPEK"} 0.734153', out)
        self.assertIn('dcc_committee_max_weight_share{node="main-node"} 0.734153', out)
        self.assertIn('address="31dLhq"} 0.088780', out)

    def test_committee_weight_share_degenerate(self):
        self.assertEqual(exporter.committee_weight_lines('node="n"', []), [])
        self.assertEqual(exporter.committee_weight_lines('node="n"', [{"address": "x", "balance": 0}]), [])

    def test_committee_weight_from_current_period(self):
        exporter.NODES = [("main-node", "https://n.example")]
        exporter.fetch = lambda url: {"height": 250} if url.endswith("/blocks/height") else (
            {"updatedTimestamp": 0, "generationPeriodLength": 100} if url.endswith("/node/status") else None)
        def fws(url, data=None):
            if url.endswith("/generators/at/201"):
                return 200, [{"address": "A", "balance": 3}, {"address": "B", "balance": 1}]
            return 404, []
        exporter.fetch_with_status = fws
        out = exporter.metrics()
        self.assertIn('dcc_committee_member_weight_share{node="main-node",address="A"} 0.750000', out)
        self.assertIn('dcc_committee_max_weight_share{node="main-node"} 0.750000', out)


if __name__ == "__main__":
    unittest.main()
