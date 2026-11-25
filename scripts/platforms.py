"""Resolve complete Linux platforms and pin image copies to inspected manifests."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def binaries(k3s, helm, helm_tag):
    result = {}
    for asset in sorted(k3s):
        match = re.fullmatch(r"k3s-airgap-images-([a-z0-9]+)\.tar\.gz", asset)
        if not match:
            continue
        arch = match[1]
        binary = {"amd64": "k3s", "arm": "k3s-armhf"}.get(arch, "k3s-" + arch)
        if binary in k3s and f"sha256sum-{arch}.txt" in k3s and f"helm-{helm_tag}-linux-{arch}.tar.gz.asc" in helm:
            result[arch] = binary
    return result


def platform_key(platform):
    if platform.get("os") != "linux":
        return None
    arch = platform.get("architecture")
    variant = platform.get("variant", "")
    if arch == "arm" and variant != "v7":
        return None
    if arch == "arm64" and variant not in ("", "v8"):
        return None
    if arch == "amd64" and variant not in ("", "v1"):
        return None
    return arch


def image_platforms(ref):
    def inspect(flag, target):
        return subprocess.check_output(["skopeo", "inspect", "--retry-times", "4", flag, "docker://" + target])
    raw = inspect("--raw", ref)
    doc = json.loads(raw)
    if "manifests" in doc:
        entries = [(platform_key(m.get("platform", {})), m["digest"]) for m in doc["manifests"]]
        return {arch: digest for arch, digest in entries if arch}
    digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    config = json.loads(inspect("--config", ref.rsplit(":", 1)[0] + "@" + digest))
    return {platform_key(config): digest}


def main():
    work = Path("work")
    candidates = binaries(set((work / "k3s-assets").read_text().splitlines()),
                          set((work / "helm-assets").read_text().splitlines()), sys.argv[1])
    refs = set()
    for role in ("ess", "cm"):
        refs.update((work / f"{role}-images.txt").read_text().splitlines())
    images = {ref: image_platforms(ref) for ref in sorted(refs)}
    plan = {}
    for arch, binary in candidates.items():
        missing = [ref for ref, platforms in images.items() if arch not in platforms]
        if missing:
            print(f"Excluding linux/{arch}: unavailable for {', '.join(missing)}", file=sys.stderr)
        else:
            plan[arch] = {"binary": binary, "images": {ref: platforms[arch] for ref, platforms in images.items()}}
    if not plan:
        raise SystemExit("No architecture has all binaries and all required Linux images.")
    print(json.dumps(plan, sort_keys=True))


if __name__ == "__main__":
    main()
