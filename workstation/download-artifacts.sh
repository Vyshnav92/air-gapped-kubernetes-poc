#!/usr/bin/env bash
# =============================================================================
# download-artifacts.sh — Air-Gapped Kubernetes PoC, connected-workstation side
#
# Downloads EVERYTHING the air-gapped cluster needs, verifies it, and packs it
# into one ISO that is attached to bastion-mirror as a virtual CD-ROM.
#
#   1. debs       OS packages + full dependency closure (clean Ubuntu 22.04 container)
#   2. images     container images saved as tarballs (skopeo)
#   3. binaries   CNI plugins, crictl, Helm, CNCF Distribution registry (+ checksum check)
#   4. manifests  Calico, metrics-server, Traefik Helm chart
#   5. package    repo configs + BOM + SHA256SUMS + tarball + ISO
#
# Usage:
#   ./download-artifacts.sh            # run every step
#   ./download-artifacts.sh images     # run one step only
#   BUNDLE_VERSION=1.1 ./download-artifacts.sh
#
# Needs on the workstation: docker, curl, tar, sha256sum, xorriso
# =============================================================================
set -euo pipefail

# ---------- Versions (single source of truth) --------------------------------
BUNDLE_VERSION="${BUNDLE_VERSION:-1.0}"
K8S_VERSION="1.28.15"          # kubeadm / kubelet / kubectl
K8S_MINOR="v1.28"              # pkgs.k8s.io repo line
CONTAINERD_VERSION="1.7.29"
CALICO_VERSION="v3.28.5"
CNI_PLUGINS_VERSION="v1.2.0"
CRICTL_VERSION="v1.28.0"
HELM_VERSION="v3.16.4"
REGISTRY_VERSION="3.0.0"       # CNCF Distribution
TRAEFIK_CHART_VERSION="41.7.1" # app v3.7.14
METRICS_SERVER_VERSION="v0.7.2"

# Packages for the k8s nodes and for the bastion (deps are resolved automatically)
NODE_PKGS="containerd.io kubelet kubeadm kubectl socat conntrack ebtables iptables chrony"
BASTION_PKGS="dnsmasq nginx skopeo ansible dpkg-dev"

# Images: "source reference|tarball name" (names match load-images.sh on the bastion)
IMAGES=(
  "registry.k8s.io/kube-apiserver:v${K8S_VERSION}|kube-apiserver_v${K8S_VERSION}.tar"
  "registry.k8s.io/kube-controller-manager:v${K8S_VERSION}|kube-controller-manager_v${K8S_VERSION}.tar"
  "registry.k8s.io/kube-scheduler:v${K8S_VERSION}|kube-scheduler_v${K8S_VERSION}.tar"
  "registry.k8s.io/kube-proxy:v${K8S_VERSION}|kube-proxy_v${K8S_VERSION}.tar"
  "registry.k8s.io/etcd:3.5.15-0|etcd_3.5.15-0.tar"
  "registry.k8s.io/coredns/coredns:v1.10.1|coredns_v1.10.1.tar"
  "registry.k8s.io/pause:3.9|pause_3.9.tar"
  "docker.io/calico/cni:${CALICO_VERSION}|calico_cni_${CALICO_VERSION}.tar"
  "docker.io/calico/node:${CALICO_VERSION}|calico_node_${CALICO_VERSION}.tar"
  "docker.io/calico/kube-controllers:${CALICO_VERSION}|calico_kube-controllers_${CALICO_VERSION}.tar"
  "registry.k8s.io/metrics-server/metrics-server:${METRICS_SERVER_VERSION}|metrics-server_metrics-server_${METRICS_SERVER_VERSION}.tar"
  "docker.io/library/traefik:v3.7.14|traefik_v3.7.14.tar"
  "docker.io/library/busybox:1.36|library_busybox_1.36.tar"
  "docker.io/library/nginx:1.27-alpine|library_nginx_1.27-alpine.tar"
)

# ---------- Paths -------------------------------------------------------------
WORK="${WORK:-$HOME/airgap}"
BUNDLE="$WORK/bundle"
OUT="$WORK/out"
TOOLS="$WORK/tools"
NAME="airgap-bundle-v${BUNDLE_VERSION}"

# ---------- Helpers -----------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    OK: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

check_tools() {
  for t in docker curl tar sha256sum xorriso; do
    command -v "$t" >/dev/null || die "'$t' is not installed"
  done
  docker info >/dev/null 2>&1 || die "Docker is not running"
}

# Compare a file with the first field of its published checksum file
verify_sha() {
  local file="$1" sumfile="$2" want got
  want=$(awk '{print $1}' "$sumfile")
  got=$(sha256sum "$file" | awk '{print $1}')
  [[ "$want" == "$got" ]] || die "checksum mismatch: $(basename "$file")"
  ok "checksum $(basename "$file")"
}

# ---------- Step 1: OS packages ----------------------------------------------
step_debs() {
  log "Step 1/5: OS packages + full dependency closure"
  mkdir -p "$BUNDLE/debs"

  # A clean Ubuntu 22.04 container = same OS as the air-gapped VMs.
  # Pinning forces the exact k8s / containerd versions.
  docker run --rm -i \
    -e K8S_VERSION="$K8S_VERSION" -e K8S_MINOR="$K8S_MINOR" \
    -e CONTAINERD_VERSION="$CONTAINERD_VERSION" \
    -e PKGS="$NODE_PKGS $BASTION_PKGS" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$BUNDLE/debs:/out" ubuntu:22.04 bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gpg ca-certificates dpkg-dev >/dev/null

# Extra repos: Docker (containerd.io) and Kubernetes
install -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" \
  > /etc/apt/sources.list.d/docker.list
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/k8s.gpg
echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/k8s.list

# Pin exact versions
cat > /etc/apt/preferences.d/pin <<PIN
Package: kubelet kubeadm kubectl
Pin: version ${K8S_VERSION}-*
Pin-Priority: 1001

Package: containerd.io
Pin: version ${CONTAINERD_VERSION}-*
Pin-Priority: 1001
PIN
apt-get update -qq

# Every package the list needs, recursively (virtual packages like <foo> are skipped)
apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
  --no-breaks --no-replaces --no-enhances $PKGS | grep '^\w' | sort -u > /tmp/all.txt
echo "    resolving $(wc -l < /tmp/all.txt) packages"

cd /out
while read -r p; do
  apt-get download -qq "$p" 2>/dev/null || echo "    skipped (virtual/unavailable): $p"
done < /tmp/all.txt

# Repo index so apt can use this folder as a repository
dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9 > Packages.gz
chown -R "$HOST_UID:$HOST_GID" /out
EOF
  ok "$(ls "$BUNDLE/debs"/*.deb | wc -l) debs downloaded"

  # Prove the set is complete: install with NO network, from the local folder only
  log "Step 1b: offline install test (no network)"
  docker run --rm -i --network none -e PKGS="$NODE_PKGS $BASTION_PKGS" \
    -v "$BUNDLE/debs:/repo:ro" ubuntu:22.04 bash -s <<'EOF'
set -euo pipefail
rm -f /etc/apt/sources.list.d/*
echo "deb [trusted=yes] file:/repo ./" > /etc/apt/sources.list
apt-get update -qq 2>/dev/null
apt-get install -s -qq $PKGS >/dev/null
EOF
  ok "all packages install offline"
}

# ---------- Step 2: container images ------------------------------------------
step_images() {
  log "Step 2/5: container images (skopeo)"
  mkdir -p "$BUNDLE/images"
  : > "$BUNDLE/images/images.txt"
  for entry in "${IMAGES[@]}"; do
    src="${entry%%|*}"
    file="${entry##*|}"
    if [[ -f "$BUNDLE/images/$file" ]]; then
      ok "already have $file"
    else
      # skopeo runs in a container, so nothing needs installing on the workstation
      docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$BUNDLE/images:/out" quay.io/skopeo/stable:latest \
        copy --override-os linux --override-arch amd64 \
        "docker://$src" "docker-archive:/out/$file:$src" >/dev/null
      ok "$src"
    fi
    echo "$src" >> "$BUNDLE/images/images.txt"
  done
}

# ---------- Step 3: binaries ---------------------------------------------------
step_binaries() {
  log "Step 3/5: binaries (with checksum verification)"
  local d="$BUNDLE/binaries"
  mkdir -p "$d" "$TOOLS"
  local cni="cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz"
  local crictl="crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  local helm="helm-${HELM_VERSION}-linux-amd64.tar.gz"
  local reg="registry_${REGISTRY_VERSION}_linux_amd64.tar.gz"

  curl -fL --progress-bar -o "$d/$cni"           "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/$cni"
  curl -fL --progress-bar -o "$d/$cni.sha256"    "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/$cni.sha256"
  curl -fL --progress-bar -o "$d/$crictl"        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/$crictl"
  curl -fL --progress-bar -o "$d/$crictl.sha256" "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/$crictl.sha256"
  curl -fL --progress-bar -o "$d/$helm"          "https://get.helm.sh/$helm"
  curl -fL --progress-bar -o "$d/$helm.sha256sum" "https://get.helm.sh/$helm.sha256sum"
  curl -fL --progress-bar -o "$d/$reg"           "https://github.com/distribution/distribution/releases/download/v${REGISTRY_VERSION}/$reg"
  curl -fL --progress-bar -o "$d/$reg.sha256"    "https://github.com/distribution/distribution/releases/download/v${REGISTRY_VERSION}/$reg.sha256"

  verify_sha "$d/$cni"    "$d/$cni.sha256"
  verify_sha "$d/$crictl" "$d/$crictl.sha256"
  verify_sha "$d/$helm"   "$d/$helm.sha256sum"
  verify_sha "$d/$reg"    "$d/$reg.sha256"

  # Helm is also needed here, on the workstation, to download the Traefik chart
  tar -xzf "$d/$helm" -C "$TOOLS" --strip-components=1 linux-amd64/helm
}

# ---------- Step 4: manifests and charts --------------------------------------
step_manifests() {
  log "Step 4/5: manifests and Helm chart"
  local d="$BUNDLE/manifests"
  mkdir -p "$d" "$BUNDLE/config"
  curl -fL --progress-bar -o "$d/calico.yaml" \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  curl -fL --progress-bar -o "$d/metrics-server.yaml" \
    "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
  ok "calico.yaml, metrics-server.yaml"

  [[ -x "$TOOLS/helm" ]] || die "helm not found in $TOOLS (run the 'binaries' step first)"
  "$TOOLS/helm" repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  "$TOOLS/helm" repo update traefik >/dev/null
  "$TOOLS/helm" pull traefik/traefik --version "$TRAEFIK_CHART_VERSION" -d "$d"
  ok "traefik-${TRAEFIK_CHART_VERSION}.tgz"
}

# ---------- Step 5: BOM, checksums, tarball, ISO ------------------------------
step_package() {
  log "Step 5/5: BOM, checksums, tarball, ISO"
  [[ -d "$BUNDLE/debs" && -d "$BUNDLE/images" ]] || die "bundle is incomplete, run all steps first"

  # Ship this repository's configs (Ansible, bastion configs, manifests) inside the bundle,
  # so they cross the air gap on the same ISO. They land in /srv/airgap/bundle/config.
  local repo
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -d "$repo/ansible" && -d "$repo/kubernetes" ]]; then
    rm -rf "$BUNDLE/config" && mkdir -p "$BUNDLE/config"
    cp -r "$repo/ansible" "$repo/bastion" "$repo/kubernetes" "$BUNDLE/config/"
    ok "repository configs copied to bundle/config"
  fi

  {
    echo "Air-Gapped K8s PoC bundle ${NAME}"
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname)"
    echo
    echo "== Versions =="
    echo "Kubernetes            ${K8S_VERSION}"
    echo "containerd.io         ${CONTAINERD_VERSION}"
    echo "Calico                ${CALICO_VERSION}"
    echo "CNI plugins           ${CNI_PLUGINS_VERSION}"
    echo "crictl                ${CRICTL_VERSION}"
    echo "Helm                  ${HELM_VERSION}"
    echo "Registry (Distrib.)   ${REGISTRY_VERSION}"
    echo "Traefik chart         ${TRAEFIK_CHART_VERSION}"
    echo "metrics-server        ${METRICS_SERVER_VERSION}"
    echo
    echo "== Images ($(wc -l < "$BUNDLE/images/images.txt")) =="
    cat "$BUNDLE/images/images.txt"
    echo
    echo "== Debian packages ($(ls "$BUNDLE/debs"/*.deb | wc -l)) =="
    (cd "$BUNDLE/debs" && printf '%s\n' *.deb)
    echo
    echo "== Binaries =="
    ls "$BUNDLE/binaries"
    echo
    echo "== Manifests =="
    ls "$BUNDLE/manifests"
    echo
    echo "== Configs =="
    ls "$BUNDLE/config"
  } > "$BUNDLE/BOM.txt"
  ok "BOM.txt"

  # One fingerprint per file, so the bastion can verify nothing changed in transit
  (cd "$BUNDLE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
  ok "SHA256SUMS ($(wc -l < "$BUNDLE/SHA256SUMS") files)"

  mkdir -p "$OUT"
  tar -cf "$OUT/$NAME.tar" -C "$WORK" bundle
  (cd "$OUT" && sha256sum "$NAME.tar" > "$NAME.tar.sha256")
  cp "$BUNDLE/BOM.txt" "$OUT/BOM.txt"
  ok "$NAME.tar"

  # The ISO is what crosses the air gap (attached to the bastion as a CD-ROM)
  xorriso -as mkisofs -r -J -V "AIRGAP_V${BUNDLE_VERSION//./_}" \
    -o "$WORK/$NAME.iso" "$OUT" 2>/dev/null
  (cd "$WORK" && sha256sum "$NAME.iso" > "$NAME.iso.sha256")
  ok "$NAME.iso ($(du -h "$WORK/$NAME.iso" | cut -f1))"
  echo
  echo "Next: copy $NAME.iso and its .sha256 to Proxmox, attach it to bastion-mirror as a CD-ROM."
}

# ---------- Main ----------------------------------------------------------------
check_tools
case "${1:-all}" in
  debs)      step_debs ;;
  images)    step_images ;;
  binaries)  step_binaries ;;
  manifests) step_manifests ;;
  package)   step_package ;;
  all)       step_debs; step_images; step_binaries; step_manifests; step_package ;;
  *)         die "unknown step '$1' (use: all | debs | images | binaries | manifests | package)" ;;
esac
log "Done."
