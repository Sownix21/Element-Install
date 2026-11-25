"""Compare installation inputs independently of Git revisions and archive metadata."""
import hashlib
import json
import re
import sys
import tarfile
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def chart_digest(path, snapshot=False):
    files = {}
    with tarfile.open(path) as archive:
        for entry in archive:
            if not entry.isfile():
                continue
            name = entry.name.split("/", 1)[1]
            # These top-level files are documentation and the upstream chart's
            # CI fixtures. Keep unknown paths, including future runtime files.
            if name in ("README.md", "CHANGELOG.md") or name.startswith(("ci/", "ci_extra/", "docs/")):
                continue
            data = archive.extractfile(entry).read()
            if snapshot and name == "Chart.yaml":
                # The builder appends the upstream commit solely for traceability.
                data = re.sub(rb"(?m)^(version: [0-9.]+)-sha[0-9a-f]{12}$", rb"\1", data)
            files[name] = digest(data)
    return json_digest(files)


def json_digest(obj):
    return digest(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode())


def identity(versions, files):
    inputs = {"versions": {k: versions[k] for k in ("cert_manager", "helm", "k3s")}, "files": {}}
    for item in files:
        role, arch = item["role"], item["arch"]
        key = "/".join((role, arch, item.get("ref", "")))
        if key in inputs["files"]:
            raise ValueError(f"Duplicate input: {key}")
        inputs["files"][key] = item.get("source_digest") or item["sha256"]
    return json_digest(inputs)


def main():
    root = Path(sys.argv[2])
    if sys.argv[1] == "published":
        man = json.loads((root / "manifest.json").read_text())
        for item in man["files"]:
            if item["role"] in ("chart-ess", "chart-cm"):
                path = root / item["name"]
                if digest(path.read_bytes()) != item["sha256"]:
                    raise ValueError(f"Published chart checksum mismatch: {path}")
                item["sha256"] = chart_digest(path, item["role"] == "chart-ess")
        print(identity(man["versions"], man["files"]))
        return

    ess, cm, k3s, helm = sys.argv[3:]
    plan = json.loads((root / "platforms.json").read_text())
    files = []
    def add(role, arch, checksum, **kwargs):
        if not re.fullmatch("[0-9a-f]{64}", checksum):
            raise ValueError(f"Invalid checksum for {role}/{arch}")
        files.append(dict(role=role, arch=arch, sha256=checksum, **kwargs))
    add("chart-ess", "all", chart_digest(Path(f"dist/matrix-stack-{ess}.tgz"), True))
    add("chart-cm", "all", chart_digest(Path(f"dist/cert-manager-{cm}.tgz")))
    add("k3s-install", "all", digest(Path("dist/k3s-install.sh").read_bytes()))
    for arch, target in plan.items():
        add("helm", arch, (root / f"helm-{arch}.sum").read_text().split()[0])
        sums = {name.lstrip("*"): checksum for checksum, name in
                (line.split(maxsplit=1) for line in (root / f"sha256sum-{arch}.txt").read_text().splitlines() if line.strip())}
        add("k3s-bin", arch, sums[target["binary"]])
        add("k3s-airgap", arch, sums[f"k3s-airgap-images-{arch}.tar.gz"])
        for group in ("cm", "ess"):
            for ref in (root / f"{group}-images.txt").read_text().splitlines():
                checksum = target["images"][ref]
                add("image-" + group, arch, checksum.removeprefix("sha256:"), ref=ref, source_digest=checksum)
    print(identity(dict(cert_manager=cm, helm=helm, k3s=k3s), files))


if __name__ == "__main__":
    main()
