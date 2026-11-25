import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("bundle_inputs", Path(__file__).resolve().parents[1] / "scripts/bundle_inputs.py")
inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inputs)


class ReleaseDetection(unittest.TestCase):
    def test_chart_changes(self):
        def signature(revision="a", docs="guide", template="enabled", extra=None):
            files = {"Chart.yaml": f"version: 1.2.3-sha{revision * 12}\n", "README.md": docs,
                     "ci/fixture.yaml": docs, "templates/pod.yaml": template, **(extra or {})}
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "chart.tgz"
                with tarfile.open(path, "w:gz") as tar:
                    for name, value in files.items():
                        entry = tarfile.TarInfo("matrix-stack/" + name)
                        entry.size = len(value)
                        tar.addfile(entry, io.BytesIO(value.encode()))
                return inputs.chart_digest(path, snapshot=True)
        baseline = signature()
        self.assertEqual(baseline, signature(revision="b", docs="edited"))
        self.assertNotEqual(baseline, signature(template="disabled"))
        self.assertNotEqual(baseline, signature(extra={"configs/new": "setting"}))

    def test_repacked_images_and_legacy_manifests(self):
        versions = dict(k3s="v1", helm="v3", cert_manager="v1")
        image = dict(role="image-ess", arch="amd64", ref="a:1", sha256="archive-a", source_digest="image-a")
        identity = inputs.identity(versions, [image])
        self.assertEqual(identity, inputs.identity(versions, [dict(image, sha256="archive-b")]))
        self.assertNotEqual(identity, inputs.identity(versions, [dict(image, source_digest="image-b")]))
        self.assertNotEqual(identity, inputs.identity(versions, [image, dict(image, arch="arm64")]))
