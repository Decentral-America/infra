"""Unit tests for the in-cluster monitors and their off-box deadman.
Run: python3 -m unittest discover -s monitoring/tests -p 'test_*.py'"""
import importlib.util
import pathlib
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


live = load("infra_liveness", "clusters/testnet/apps/monitors/scripts/infra-liveness.py")
dead = load("check_monitor_cronjobs", "scripts/check-monitor-cronjobs.py")
rep = load("actions_minutes_report", "scripts/actions_minutes_report.py")


def cond(status, reason=""):
    return {"conditions": [{"type": "Ready", "status": status, "reason": reason}]}


class LivenessChecks(unittest.TestCase):
    def test_height_advancing(self):
        seq = iter([10, 12])
        self.assertEqual(live.check_height(lambda: next(seq), lambda s: None, 150), [])

    def test_height_stalled(self):
        seq = iter([10, 10])
        self.assertEqual(len(live.check_height(lambda: next(seq), lambda s: None, 150)), 1)

    def test_nodes(self):
        ok = {"metadata": {"name": "a"}, "status": cond("True")}
        nr = {"metadata": {"name": "b"}, "status": cond("False", "KubeletNotReady")}
        self.assertEqual(live.check_nodes([ok]), [])
        self.assertEqual(len(live.check_nodes([ok, nr])), 1)
        self.assertEqual(len(live.check_nodes([])), 1)

    def test_flux_suspended_only_warns(self):
        ks_ok = {"metadata": {"name": "apps"}, "spec": {}, "status": cond("True")}
        ks_susp = {"metadata": {"name": "monitoring"}, "spec": {"suspend": True}, "status": cond("False")}
        ks_bad = {"metadata": {"name": "bad"}, "spec": {}, "status": cond("False", "BuildFailed")}
        pod = {"metadata": {"name": "p"}, "status": {"containerStatuses": [{"ready": True, "restartCount": 0}]}}
        pod_bad = {"metadata": {"name": "q"}, "status": {"containerStatuses": [{"ready": False, "restartCount": 3}]}}
        self.assertEqual(live.check_flux([ks_ok, ks_susp], [pod]), [])
        self.assertEqual(len(live.check_flux([ks_ok, ks_bad], [pod, pod_bad])), 2)

    def test_alert_dedup_and_create(self):
        posted = []
        get = lambda url: (200, [{"title": "[ALERT] InfraLiveness: x", "number": 5}])
        self.assertEqual(live.raise_alert(["f"], lambda u, b: posted.append(b), get, "o/r", "run"), ("exists", 5))
        self.assertEqual(posted, [])
        get_empty = lambda url: (200, [{"title": "[ALERT] Other", "number": 1}])
        post = lambda u, b: (201, {"number": 9}) if posted.append(b) is None else None
        self.assertEqual(live.raise_alert(["f"], post, get_empty, "o/r", "run"), ("created", 9))
        self.assertEqual(posted[0]["title"], live.TITLE)
        self.assertIn("**Severity:** high", posted[0]["body"])


class Deadman(unittest.TestCase):
    NOW = datetime(2026, 10, 22, 12, 0, 0, tzinfo=timezone.utc)

    def cj(self, name, sched_min, ok_min, created_min=10_000):
        f = lambda m: (self.NOW - timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
        st = {}
        if sched_min is not None:
            st["lastScheduleTime"] = f(sched_min)
        if ok_min is not None:
            st["lastSuccessfulTime"] = f(ok_min)
        return {"metadata": {"name": name, "creationTimestamp": f(created_min)}, "spec": {}, "status": st}

    def items(self, **over):
        d = {"canary-transaction": (5, 5), "infra-liveness": (10, 10), "matcher-canary": (30, 30)}
        d.update(over)
        return {"items": [self.cj(n, *v) for n, v in d.items()]}

    def test_healthy(self):
        self.assertEqual(dead.evaluate(self.items(), [], self.NOW), [])

    def test_missing_cronjob(self):
        items = self.items()
        items["items"].pop()
        self.assertEqual(len(dead.evaluate(items, [], self.NOW)), 1)

    def test_not_scheduled(self):
        bad = dead.evaluate(self.items(**{"canary-transaction": (90, 90)}), [], self.NOW)
        self.assertTrue(any("last scheduled" in b for b in bad))

    def test_silent_failure_is_flagged_but_alerted_failure_is_not(self):
        items = self.items(**{"canary-transaction": (5, 200)})
        self.assertEqual(len(dead.evaluate(items, [], self.NOW)), 1)
        self.assertEqual(dead.evaluate(items, ["[ALERT] CanaryTransactionFailed: x"], self.NOW), [])

    def test_young_cronjob_is_not_flagged(self):
        items = self.items(**{"matcher-canary": (None, None, 20)})
        self.assertEqual(dead.evaluate(items, [], self.NOW), [])


class MinutesReport(unittest.TestCase):
    NOW = datetime(2026, 10, 11, 0, 0, 0, tzinfo=timezone.utc)  # 10 days elapsed of 31

    @staticmethod
    def row(repo, day, q, sku="Actions Linux", net=0.0, unit="Minutes", product="actions"):
        return {"product": product, "sku": sku, "unitType": unit, "quantity": q, "grossAmount": q * 0.006,
                "netAmount": net, "repositoryName": repo, "date": f"2026-10-{day:02d}T00:00:00Z"}

    def test_aggregates_weights_and_projects(self):
        usage = {"usageItems": [self.row("a", 1, 100), self.row("a", 2, 10, "Actions macOS 3-core"),
                                self.row("b", 1, 50, "Actions Windows"),
                                self.row("a", 1, 999, unit="GigabyteHours"), self.row("a", 1, 999, product="packages")]}
        a = rep.analyse(usage, self.NOW)
        self.assertAlmostEqual(a["repos"]["a"]["pool"], 200)   # 100 + 10 x 10
        self.assertAlmostEqual(a["repos"]["b"]["pool"], 100)   # 50 x 2
        self.assertAlmostEqual(a["proj"]["pool"], 300 * 31 / 10)
        self.assertEqual(a["bursts"], [])

    def test_burst_and_thresholds(self):
        usage = {"usageItems": [self.row("a", 3, 700, net=20.0)]}
        a = rep.analyse(usage, self.NOW)
        self.assertEqual(len(a["bursts"]), 1)
        self.assertEqual(len(a["reasons"]), 3)  # burst, projected pool, projected net
        self.assertIn("burst", rep.render(a, self.NOW))

    def test_no_projection_in_first_two_days(self):
        a = rep.analyse({"usageItems": [self.row("a", 1, 10)]}, datetime(2026, 10, 2, 0, tzinfo=timezone.utc))
        self.assertIsNone(a["proj"])
        self.assertEqual(a["reasons"], [])


if __name__ == "__main__":
    unittest.main()
