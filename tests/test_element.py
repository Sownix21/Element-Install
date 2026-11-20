"""Offline checks for install choices and retrying interrupted operations."""
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader("element", str(Path(__file__).resolve().parents[1] / "element"))
element = importlib.util.module_from_spec(importlib.util.spec_from_loader("element", loader))
loader.exec_module(element)


class Operations(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        paths = patch.multiple(element, CONFIG=root / "config.json", PAUSED=root / "replicas.json")
        paths.start()
        self.addCleanup(paths.stop)

    def test_interrupted_stop_preserves_original_counts_for_start(self):
        counts = {"deployment/web": 2, "statefulset/postgres": 1}
        with patch.object(element, "workloads", return_value=counts) as get_workloads:
            with patch.object(element, "run", side_effect=[None, OSError("lost connection")]):
                with self.assertRaises(OSError):
                    element.scale(False)
            self.assertEqual(element.read(element.PAUSED), counts)
            with patch.object(element, "run", return_value=""):
                element.scale(False)
            get_workloads.assert_called_once()
        with patch.object(element, "run") as run:
            element.scale(True)
            for name, count in counts.items():
                run.assert_any_call(*element.ESS, "scale", name, "--replicas", str(count))
        self.assertFalse(element.PAUSED.exists())

    def test_failed_upgrade_keeps_previous_version(self):
        element.save(element.CONFIG, {"version": "1.2.3", "deployed": True})
        previous = json.dumps([{"chart": "matrix-stack-1.2.3", "status": "deployed"}])
        with patch.object(element, "release", return_value="1.2.4"), \
             patch.object(element, "run", return_value=previous), \
             patch("builtins.input", return_value="y"), \
             patch.object(element, "deploy", side_effect=OSError("upgrade failed")):
            with self.assertRaises(OSError):
                element.action("update")
        self.assertEqual(element.read(element.CONFIG)["version"], "1.2.3")

    def test_wizard_rejects_duplicate_hosts_and_uses_upstream_keys(self):
        answers = ["example.org", "example.org", "", "", "", "web.example.org", "",
                   "admin@example.org", "y"]
        with patch("builtins.input", side_effect=answers), patch.object(element, "dns", return_value=True), \
             patch.object(element, "release", side_effect=["1.2.3", "v1.2.0"]):
            cfg = element.configure()
        values = element.values(cfg)
        self.assertEqual(values["serverName"], "example.org")
        self.assertEqual(values["certManager"], {"clusterIssuer": "letsencrypt-prod"})
        hosts = {k: v["ingress"]["host"] for k, v in values.items() if k in element.SERVICES}
        self.assertEqual(hosts, {"synapse": "matrix.example.org", "matrixRTC": "mrtc.example.org",
                                 "matrixAuthenticationService": "account.example.org",
                                 "elementAdmin": "admin.example.org", "elementWeb": "web.example.org"})


if __name__ == "__main__":
    unittest.main()
