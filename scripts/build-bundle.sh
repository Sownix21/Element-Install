#!/usr/bin/env bash
# Mirrors everything the `element` installer needs into ./dist and publishes it
# as a GitHub Release. Runs on a GitHub-hosted runner (see mirror.yml).
# Needs: gh, curl, skopeo, python3. Set ARCHES="amd64 arm64" to mirror both.
set -euo pipefail

ARCHES="${ARCHES:-amd64}"
die() { echo "ERROR: $*" >&2; exit 1; }
rm -rf dist work && mkdir -p dist work
: > work/files.tsv
register() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> work/files.tsv; }  # role arch name [ref]

# ---------------------------------------------------------------- versions --
latest() { gh api "repos/$1/releases/latest" --jq .tag_name; }
ESS_TAG="$(latest element-hq/ess-helm)"
CM_TAG="$(latest cert-manager/cert-manager)"
# Same channel the official K3s installer uses by default.
K3S_TAG="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://update.k3s.io/v1-release/channels/stable \
           | sed 's|.*/tag/||; s|%2B|+|' || true)"
[[ $K3S_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || K3S_TAG="$(latest k3s-io/k3s)"
# The installer needs Helm 3 (Helm 4 is a different major version).
HELM_TAG="$(gh api 'repos/helm/helm/releases?per_page=100' --jq '.[] | select(.prerelease|not) | .tag_name' \
           | grep -E '^v3\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

[[ $ESS_TAG  =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]                || die "odd ESS tag: $ESS_TAG"
[[ $CM_TAG   =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]                 || die "odd cert-manager tag: $CM_TAG"
[[ $K3S_TAG  =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]]      || die "odd K3s tag: $K3S_TAG"
[[ $HELM_TAG =~ ^v3\.[0-9]+\.[0-9]+$ ]]                      || die "odd Helm tag: $HELM_TAG"
ESS_VER="${ESS_TAG#v}"

BUNDLE_TAG="bundle-ess${ESS_VER}-cm${CM_TAG}-k3s${K3S_TAG//+/-}-helm${HELM_TAG}"
echo "Bundle: $BUNDLE_TAG"
if gh release view "$BUNDLE_TAG" >/dev/null 2>&1; then
  echo "Release $BUNDLE_TAG already exists, nothing to do."
  exit 0
fi

# -------------------------------------------------------------------- helm --
get_helm() {  # arch outdir
  local f="helm-${HELM_TAG}-linux-$1.tar.gz"
  curl -fsSL --retry 3 "https://get.helm.sh/$f" -o "$2/$f"
  echo "$(curl -fsSL --retry 3 "https://get.helm.sh/$f.sha256sum" | cut -d' ' -f1)  $f" | (cd "$2" && sha256sum -c -)
}
get_helm amd64 work
tar -xzf "work/helm-${HELM_TAG}-linux-amd64.tar.gz" -C work --strip-components=1 linux-amd64/helm
HELM="$PWD/work/helm"

for arch in $ARCHES; do
  [[ $arch == amd64 || $arch == arm64 ]] || die "unsupported arch $arch"
  get_helm "$arch" dist
  register helm "$arch" "helm-${HELM_TAG}-linux-$arch.tar.gz"
done

# -------------------------------------------------------------------- k3s ---
curl -fsSL --retry 3 https://get.k3s.io -o dist/k3s-install.sh
head -c 2 dist/k3s-install.sh | grep -q '#!' || die "get.k3s.io did not return a script"
register k3s-install all k3s-install.sh

for arch in $ARCHES; do
  bin=k3s; [[ $arch == arm64 ]] && bin=k3s-arm64
  air="k3s-airgap-images-$arch.tar.gz"
  sums="sha256sum-$arch.txt"
  gh release download "$K3S_TAG" -R k3s-io/k3s -D "work/k3s-$arch" -p "$bin" -p "$air" -p "$sums"
  (cd "work/k3s-$arch"
   awk -v b="$bin" -v a="$air" '$2==b || $2==a' "$sums" > want.txt
   [[ $(wc -l < want.txt) -eq 2 ]] || die "K3s checksums missing for $arch"
   sha256sum -c want.txt)
  cp "work/k3s-$arch/$bin" "dist/k3s-$arch"
  cp "work/k3s-$arch/$air" "dist/$air"
  register k3s-bin "$arch" "k3s-$arch"
  register k3s-airgap "$arch" "$air"
done

# ------------------------------------------------------------------ charts --
"$HELM" pull oci://ghcr.io/element-hq/ess-helm/matrix-stack --version "$ESS_VER" -d dist
"$HELM" pull oci://quay.io/jetstack/charts/cert-manager --version "$CM_TAG" -d dist
register chart-ess all "matrix-stack-${ESS_VER}.tgz"
register chart-cm all "cert-manager-${CM_TAG}.tgz"
[[ -f dist/matrix-stack-${ESS_VER}.tgz && -f dist/cert-manager-${CM_TAG}.tgz ]] || die "chart download failed"

# ------------------------------------------------------------------ images --
# Render the charts exactly as the installer will use them and collect every image.
cat > work/ess-values.yaml <<'EOF'
serverName: example.org
certManager: {clusterIssuer: letsencrypt-prod}
synapse: {ingress: {host: matrix.example.org}}
matrixAuthenticationService: {ingress: {host: account.example.org}}
matrixRTC: {ingress: {host: mrtc.example.org}}
elementWeb: {ingress: {host: chat.example.org}}
elementAdmin: {ingress: {host: admin.example.org}}
EOF
"$HELM" template ess "dist/matrix-stack-${ESS_VER}.tgz" -n ess -f work/ess-values.yaml > work/ess.yaml
"$HELM" template cert-manager "dist/cert-manager-${CM_TAG}.tgz" -n cert-manager \
  --set crds.enabled=true > work/cm.yaml

REF_RE='^[a-z0-9.-]+\.[a-z]+(:[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+$'
images_of() {
  { grep -Eoh '(^|[[:space:]])image:[[:space:]]*"?[^"[:space:]]+' "$1" | sed -E 's/.*image:[[:space:]]*"?//'
    grep -Eoh -- '--acme-http01-solver-image=[^"[:space:]]+' "$1" | sed 's/.*=//' || true; } | sort -u
}
check_refs() {
  local ref
  while read -r ref; do
    [[ $ref =~ $REF_RE ]] || die "Unsupported image reference (digest-pinned or odd): $ref"
  done
}
images_of work/ess.yaml > work/ess-images.txt
{ images_of work/cm.yaml; echo "quay.io/jetstack/cert-manager-acmesolver:${CM_TAG}"; } | sort -u > work/cm-images.txt
check_refs < work/ess-images.txt
check_refs < work/cm-images.txt
[[ $(wc -l < work/ess-images.txt) -ge 5 ]] || die "Too few ESS images found, chart layout may have changed"
[[ $(wc -l < work/cm-images.txt)  -ge 4 ]] || die "Too few cert-manager images found"
echo "ESS images:";          cat work/ess-images.txt
echo "cert-manager images:"; cat work/cm-images.txt

mirror_image() {  # role arch ref
  local role=$1 arch=$2 ref=$3 name
  name="image-${arch}-$(tr '/:' '__' <<<"$ref").tar"
  echo "==> $ref ($arch)"
  skopeo copy --retry-times 5 --override-os linux --override-arch "$arch" \
    "docker://$ref" "docker-archive:work/$name:$ref"
  gzip -6 -f "work/$name"
  mv "work/$name.gz" "dist/$name.gz"
  register "$role" "$arch" "$name.gz" "$ref"
}
for arch in $ARCHES; do
  while read -r ref; do mirror_image image-cm  "$arch" "$ref"; done < work/cm-images.txt
  while read -r ref; do mirror_image image-ess "$arch" "$ref"; done < work/ess-images.txt
done

# GitHub rejects release assets of 2 GiB or more.
if [[ -n "$(find dist -type f -size +1900M)" ]]; then die "an asset is too large for a release"; fi

# ---------------------------------------------------------------- manifest --
export BUNDLE_TAG ESS_TAG ESS_VER CM_TAG K3S_TAG HELM_TAG
python3 - <<'PY'
import hashlib, json, os, pathlib

files = []
for line in open("work/files.tsv"):
    role, arch, name, ref = line.rstrip("\n").split("\t")
    path = pathlib.Path("dist") / name
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    item = {"role": role, "arch": arch, "name": name,
            "sha256": digest.hexdigest(), "size": path.stat().st_size}
    if ref:
        item["ref"] = ref
    files.append(item)

env = os.environ
manifest = {"schema": 1, "tag": env["BUNDLE_TAG"],
            "versions": {"ess": env["ESS_VER"], "ess_tag": env["ESS_TAG"],
                         "cert_manager": env["CM_TAG"], "k3s": env["K3S_TAG"], "helm": env["HELM_TAG"]},
            "files": files}
with open("dist/manifest.json", "w") as out:
    json.dump(manifest, out, indent=2)
print(f"manifest.json: {len(files)} files, {sum(f['size'] for f in files) / 1e9:.2f} GB")
PY

# ----------------------------------------------------------------- publish --
# Create as a draft, then publish, so the VPS never sees a half-uploaded release.
gh release create "$BUNDLE_TAG" dist/* --draft --title "$BUNDLE_TAG" \
  --notes "ESS ${ESS_VER}, cert-manager ${CM_TAG}, K3s ${K3S_TAG}, Helm ${HELM_TAG}. Built for: ${ARCHES}."
gh release edit "$BUNDLE_TAG" --draft=false --latest
echo "Published $BUNDLE_TAG"

