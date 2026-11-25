import importlib.util
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("platforms", Path(__file__).resolve().parents[1] / "scripts/platforms.py")
platforms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platforms)


class PlatformSelection(unittest.TestCase):
    def test_requires_matching_binary_archive_checksum_and_helm(self):
        assets = {"k3s", "k3s-arm64", "k3s-armhf"}
        for arch in ("amd64", "arm64", "arm", "s390x"):
            assets.update([f"k3s-airgap-images-{arch}.tar.gz", f"sha256sum-{arch}.txt"])
        helm = {f"helm-v3-linux-{a}.tar.gz.asc" for a in ("amd64", "arm", "s390x")}
        self.assertEqual(platforms.binaries(assets, helm, "v3"), {"amd64": "k3s", "arm": "k3s-armhf"})

    def test_platform_variants(self):
        key = platforms.platform_key
        self.assertEqual(key(dict(os="linux", architecture="arm", variant="v7")), "arm")
        self.assertEqual(key(dict(os="linux", architecture="arm64", variant="v8")), "arm64")
        self.assertIsNone(key(dict(os="linux", architecture="arm", variant="v6")))
        self.assertIsNone(key(dict(os="windows", architecture="amd64")))
