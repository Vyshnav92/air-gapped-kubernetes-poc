#!/usr/bin/env bash
# Extra names (aliases) for images already in the registry. Layers are shared, so 0 MB extra.
#
# Why: containerd mirror rules keep the original image path. A request for
# docker.io/library/nginx asks the bastion for "library/nginx", but we store it as "nginx".
# These aliases make the mirror rules work for un-rewritten image names.
set -euo pipefail
R=bastion-mirror:5000

# Acceptance test 3 uses 'bastion-mirror:5000/busybox' with no tag (= :latest)
skopeo copy "docker://$R/busybox:1.36" "docker://$R/busybox:latest"

# Original-style paths for the mirror rules
skopeo copy "docker://$R/nginx:1.27-alpine"   "docker://$R/library/nginx:1.27-alpine"
skopeo copy "docker://$R/busybox:1.36"        "docker://$R/library/busybox:1.36"
skopeo copy "docker://$R/busybox:1.36"        "docker://$R/library/busybox:latest"
skopeo copy "docker://$R/traefik/traefik:v3.7.14" "docker://$R/library/traefik:v3.7.14"
skopeo copy "docker://$R/k8s/coredns:v1.10.1" "docker://$R/k8s/coredns/coredns:v1.10.1"
skopeo copy "docker://$R/metrics-server/metrics-server:v0.7.2" \
            "docker://$R/k8s/metrics-server/metrics-server:v0.7.2"
