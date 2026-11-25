#!/usr/bin/env bash
# Mirrors everything the `element` installer needs into ./dist and publishes it
# as a GitHub Release. Runs on a GitHub-hosted runner (see mirror.yml).
# Needs: gh, curl, skopeo, python3. Platform selection is based on upstream artifacts.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
rm -rf dist work && mkdir -p dist work
: > work/files.tsv
register() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> work/files.tsv; }  # role arch name [ref]

# ---------------------------------------------------------------- versions --
latest() { gh api "repos/$1/releases/latest" --jq .tag_name; }
# Resolve one immutable main revision touching the chart, including its resources.
ESS_COMMIT="$(gh api 'repos/element-hq/ess-helm/commits?sha=main&path=charts/matrix-stack&per_page=1' --jq '.[0].sha')"
[[ $ESS_COMMIT =~ ^[a-f0-9]{40}$ ]] || die "invalid ESS source revision"
curl -fsSL --retry 3 "https://codeload.github.com/element-hq/ess-helm/tar.gz/$ESS_COMMIT" -o work/source.tgz
tar -xzf work/source.tgz -C work "ess-helm-$ESS_COMMIT/charts/matrix-stack"
chart="work/ess-helm-$ESS_COMMIT/charts/matrix-stack"
base=$(awk '$1=="version:" {print $2}' "$chart/Chart.yaml")
[[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+(-dev)?$ ]] || die "unexpected chart version $base"
ESS_VER="${base%-dev}-sha${ESS_COMMIT:0:12}"
ESS_TAG="$ESS_VER"
CM_TAG="$(latest cert-manager/cert-manager)"
# Same channel the official K3s installer uses by default.
K3S_TAG="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://update.k3s.io/v1-release/channels/stable \
           | sed 's|.*/tag/||; s|%2B|+|' || true)"
[[ $K3S_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || K3S_TAG="$(latest k3s-io/k3s)"
# The installer needs Helm 3 (Helm 4 is a different major version).
HELM_TAG="$(gh api 'repos/helm/helm/releases?per_page=100' --jq '.[] | select(.prerelease|not) | .tag_name' \
           | grep -E '^v3\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

[[ $CM_TAG   =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]                 || die "odd cert-manager tag: $CM_TAG"
[[ $K3S_TAG  =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]]      || die "odd K3s tag: $K3S_TAG"
[[ $HELM_TAG =~ ^v3\.[0-9]+\.[0-9]+$ ]]                      || die "odd Helm tag: $HELM_TAG"
# -------------------------------------------------------------------- helm --
get_helm() {  # arch outdir
  local f="helm-${HELM_TAG}-linux-$1.tar.gz"
  if [[ ! -f work/helm-$1.sum ]]; then
    curl -fsSL --retry 3 "https://get.helm.sh/$f.sha256sum" -o "work/helm-$1.sum"
  fi
  curl -fsSL --retry 3 "https://get.helm.sh/$f" -o "$2/$f"
  echo "$(awk 'NR == 1 {print $1}' "work/helm-$1.sum")  $f" | (cd "$2" && sha256sum -c -)
}
get_helm amd64 work
tar -xzf "work/helm-${HELM_TAG}-linux-amd64.tar.gz" -C work --strip-components=1 linux-amd64/helm
HELM="$PWD/work/helm"

# ------------------------------------------------------------------ charts --
"$HELM" package "$chart" --version "$ESS_VER" -d dist
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

# Discover complete targets before checking the release: a newly supported
# platform or an upstream image retag must invalidate the previous bundle.
gh release view "$K3S_TAG" -R k3s-io/k3s --json assets --jq '.assets[].name' > work/k3s-assets
gh release view "$HELM_TAG" -R helm/helm --json assets --jq '.assets[].name' > work/helm-assets
python3 scripts/platforms.py "$HELM_TAG" > work/platforms.json
ARCHES=$(jq -r 'keys | join(" ")' work/platforms.json)
curl -fsSL --retry 3 "https://raw.githubusercontent.com/k3s-io/k3s/$K3S_TAG/install.sh" -o dist/k3s-install.sh
head -c 2 dist/k3s-install.sh | grep -q '#!' || die "invalid K3s install script"
register k3s-install all k3s-install.sh
for arch in $ARCHES; do
  gh release download "$K3S_TAG" -R k3s-io/k3s -D work -p "sha256sum-$arch.txt"
  if [[ ! -f work/helm-$arch.sum ]]; then
    curl -fsSL --retry 3 "https://get.helm.sh/helm-$HELM_TAG-linux-$arch.tar.gz.sha256sum" -o "work/helm-$arch.sum"
  fi
done
fingerprint=$(python3 scripts/bundle_inputs.py candidate work "$ESS_VER" "$CM_TAG" "$K3S_TAG" "$HELM_TAG")
# Compare to the release actually offered to a fresh VPS, including bundles
# published before input fingerprints were added. Fail on network errors.
latest_tag=$(gh release list --exclude-drafts --exclude-pre-releases --limit 100 --json isLatest,tagName --jq '.[] | select(.isLatest) | .tagName')
if [[ -n $latest_tag ]]; then
  gh release download "$latest_tag" -p manifest.json -D work/latest
  previous=$(jq -r '.inputs_sha256 // empty' work/latest/manifest.json)
  if [[ -z $previous ]]; then
    gh release download "$latest_tag" -p 'matrix-stack-*.tgz' -p 'cert-manager-*.tgz' -D work/latest
    previous=$(python3 scripts/bundle_inputs.py published work/latest)
  fi
  if [[ $fingerprint == "$previous" ]]; then
    echo "Installation inputs match $latest_tag. No new release."
    exit 0
  fi
fi
BUNDLE_TAG="bundle-ess${ESS_VER}-cm${CM_TAG}-k3s${K3S_TAG//+/-}-helm${HELM_TAG}-${fingerprint:0:16}"
echo "Bundle $BUNDLE_TAG for $ARCHES"
draft=$(gh release view "$BUNDLE_TAG" --json isDraft --jq .isDraft 2>/dev/null || true)
if [[ $draft == false ]]; then
  gh release edit "$BUNDLE_TAG" --latest
  echo "Restored matching release as latest."
  exit 0
fi

for arch in $ARCHES; do
  get_helm "$arch" dist
  register helm "$arch" "helm-${HELM_TAG}-linux-$arch.tar.gz"
done

# -------------------------------------------------------------------- k3s ---
for arch in $ARCHES; do
  bin=$(jq -r --arg arch "$arch" '.[$arch].binary' work/platforms.json)
  air="k3s-airgap-images-$arch.tar.gz"
  sums="sha256sum-$arch.txt"
  gh release download "$K3S_TAG" -R k3s-io/k3s -D "work/k3s-$arch" -p "$bin" -p "$air"
  (cd "work/k3s-$arch"
   awk -v b="$bin" -v a="$air" '$2==b || $2==a' "../$sums" > want.txt
   [[ $(wc -l < want.txt) -eq 2 ]] || die "K3s checksums missing for $arch"
   sha256sum -c want.txt)
  mv "work/k3s-$arch/$bin" "dist/k3s-$arch"
  mv "work/k3s-$arch/$air" "dist/$air"
  register k3s-bin "$arch" "k3s-$arch"
  register k3s-airgap "$arch" "$air"
done

mirror_image() {  # role arch ref
  local role=$1 arch=$2 ref=$3 name
  name="image-${arch}-$(tr '/:' '__' <<<"$ref").tar"
  echo "==> $ref ($arch)"
  local digest pinned
  digest=$(jq -er --arg arch "$arch" --arg ref "$ref" '.[$arch].images[$ref]' work/platforms.json)
  pinned="${ref%:*}@$digest"
  skopeo copy --retry-times 5 --override-os linux --override-arch "$arch" \
    "docker://$pinned" "docker-archive:work/$name:$ref"
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
export ESS_COMMIT ARCHES BUNDLE_TAG ESS_TAG ESS_VER CM_TAG K3S_TAG HELM_TAG fingerprint
python3 - <<'PY'
import hashlib, json, os, pathlib

plan = json.loads(pathlib.Path("work/platforms.json").read_text())
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
        item["source_digest"] = plan[arch]["images"][ref]
    files.append(item)

env = os.environ
manifest = {"schema": 1, "tag": env["BUNDLE_TAG"], "inputs_sha256": env["fingerprint"],
            "versions": {"ess": env["ESS_VER"], "ess_tag": env["ESS_TAG"],
                         "cert_manager": env["CM_TAG"], "k3s": env["K3S_TAG"], "helm": env["HELM_TAG"]},
            "source_commit": env["ESS_COMMIT"], "architectures": env["ARCHES"].split(), "files": files}
with open("dist/manifest.json", "w") as out:
    json.dump(manifest, out, indent=2)
print(f"manifest.json: {len(files)} files, {sum(f['size'] for f in files) / 1e9:.2f} GB")
PY
# Check that the uploaded files match the inputs inspected before mirroring.
[[ $(python3 scripts/bundle_inputs.py published dist) == "$fingerprint" ]] || die "bundle inputs changed during build"

# ----------------------------------------------------------------- publish --
# Create as a draft, then publish, so the VPS never sees a half-uploaded release.
if [[ $draft != true ]]; then
  gh release create "$BUNDLE_TAG" --draft --title "$BUNDLE_TAG" --target "$GITHUB_SHA" \
    --notes "ESS ${ESS_VER}, cert-manager ${CM_TAG}, K3s ${K3S_TAG}, Helm ${HELM_TAG}. Built for: ${ARCHES}."
fi
gh release upload "$BUNDLE_TAG" dist/* --clobber
gh release edit "$BUNDLE_TAG" --draft=false --latest
echo "Published $BUNDLE_TAG"

