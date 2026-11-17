#!/usr/bin/env bash
# Push every image tarball from the bundle into the local registry.
# Run on bastion-mirror after the bundle ISO is extracted to /srv/airgap/bundle.
#
# Tarball names are <name>_<tag>.tar, with '/' in the name written as '_'.
# Example: calico_node_v3.28.5.tar -> bastion-mirror:5000/calico/node:v3.28.5
set -euo pipefail

cd /srv/airgap/bundle/images
for f in *.tar; do
  base=${f%.tar}          # strip .tar
  tag=${base##*_}         # part after the last _
  name=${base%_*}         # part before the last _
  name=${name//_//}       # every _ becomes /
  case $name in
    kube-*|etcd|coredns|pause) name=k8s/$name ;;
    library/*) name=${name#library/} ;;
    traefik) name=traefik/traefik ;;
  esac
  skopeo copy "docker-archive:$f" "docker://bastion-mirror:5000/$name:$tag"
done
