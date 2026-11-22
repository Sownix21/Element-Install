"""Offline checks for install choices and retrying interrupted operations."""
import importlib.machinery
import importlib.util
import json
import tarfile
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
        bundle = {"tag": "bundle-2", "versions": {"ess_tag": "1.2.4", "ess": "1.2.4"}}
        with patch.object(element, "manifest", return_value=bundle), \
             patch.object(element, "run", side_effect=[previous, "{}"]), \
             patch.object(element, "check_disk"), \
             patch("builtins.input", return_value="y"), \
             patch.object(element, "deploy", side_effect=OSError("upgrade failed")):
            with self.assertRaises(OSError):
                element.action("update")
        self.assertEqual(element.read(element.CONFIG)["version"], "1.2.3")

    def test_wizard_rejects_duplicate_hosts_and_uses_upstream_keys(self):
        answers = ["example.org", "example.org", "", "", "", "web.example.org", "",
                   "admin@example.org", "y"]
        with patch("builtins.input", side_effect=answers), patch.object(element, "dns", return_value=True), \
             patch.object(element, "manifest", return_value={"tag": "bundle", "versions": {"ess_tag": "1.2.3"}}):
            cfg = element.configure()
        values = element.values(cfg)
        self.assertEqual(values["serverName"], "example.org")
        self.assertEqual(values["certManager"], {"clusterIssuer": "letsencrypt-prod"})
        hosts = {k: v["ingress"]["host"] for k, v in values.items() if k in element.SERVICES}
        self.assertEqual(hosts, {"synapse": "matrix.example.org", "matrixRTC": "mrtc.example.org",
                                 "matrixAuthenticationService": "account.example.org",
                                 "elementAdmin": "admin.example.org", "elementWeb": "web.example.org"})

    def test_upload_limit_keeps_call_and_registration_settings(self):
        element.save(element.CONFIG, {"deployed": True})
        active = {"synapse": {"ingress": {"host": "matrix.example.org"}},
                  "matrixRTC": {"hostAliases": [{"ip": "10.43.1.1"}]},
                  "matrixAuthenticationService": {"additional": {"custom": {"config": "test: true"}}}}
        original = json.loads(json.dumps(active))
        with patch.object(element, "pinned_bundle", return_value={"tag": "pinned"}), \
             patch.object(element, "helm_values", return_value=active), \
             patch("builtins.input", return_value="256"), patch.object(element, "deploy") as deploy:
            element.action("upload-limit")
        original["synapse"]["media"] = {"maxUploadSize": "256M"}
        self.assertEqual(deploy.call_args.args[2], original)

    def test_stopped_stack_requires_confirmation_to_uninstall(self):
        element.save(element.CONFIG, {"server": "example.org"})
        element.save(element.PAUSED, {})
        with patch("builtins.input", return_value="yes"), patch.object(element, "run") as run:
            element.action("uninstall")
        run.assert_not_called()
        self.assertTrue(element.CONFIG.exists())

    def test_registration_keeps_existing_smtp_and_other_overrides(self):
        element.save(element.CONFIG, {"deployed": True})
        active = {"matrixAuthenticationService": {"additional": {"original": {"configSecret": "mail"}}}}
        with patch.object(element, "pinned_bundle"), patch.object(element, "helm_values", return_value=active), \
             patch("builtins.input", side_effect=["enable", "y"]), patch.object(element, "deploy"):
            element.action("registration")
        extra = active["matrixAuthenticationService"]["additional"]
        self.assertEqual(extra["original"]["configSecret"], "mail")
        account = json.loads(extra["zz-element-install-registration"]["config"])["account"]
        self.assertTrue(account["password_registration_enabled"])
        self.assertTrue(account["password_registration_email_required"])

    def test_backup_archive_contains_cold_volumes_and_restores_counts(self):
        root = element.CONFIG.parent
        element.save(element.CONFIG, {"server": "example.org", "deployed": True})
        volumes = ["ess-postgres-data", "ess-synapse-media"]
        for name in volumes:
            (root / name).mkdir()
            (root / name / "sample").write_bytes(name.encode())
        def kubectl(*args, **kwargs):
            if "pvc" in args and "get" in args and "pv" not in args:
                return json.dumps({"items": [{"metadata": {"name": n}, "spec": {"volumeName": n}} for n in volumes]})
            if "pv" in args:
                return json.dumps({"spec": {"local": {"path": str(root / args[args.index("pv") + 1])}}})
            return '{"items":[]}'
        def scale(start):
            if start:
                element.PAUSED.unlink()
            else:
                element.save(element.PAUSED, {"deployment/web": 2})
        with patch.multiple(element, BACKUPS=root / "backups", LOCAL_STORAGE=root), \
             patch.object(element, "run", side_effect=kubectl), patch.object(element, "helm_values", return_value={}), \
             patch.object(element, "scale", side_effect=scale) as scaled, patch("builtins.input", return_value="y"):
            element.action("backup")
        self.assertEqual([c.args[0] for c in scaled.call_args_list], [False, True])
        with tarfile.open(next((root / "backups").glob("*.tgz"))) as archive:
            for n in volumes:
                self.assertEqual(archive.extractfile("volumes/" + n + "/sample").read(), n.encode())
            self.assertEqual(json.load(archive.extractfile("replicas.json")), {"deployment/web": 2})


if __name__ == "__main__":
    unittest.main()
