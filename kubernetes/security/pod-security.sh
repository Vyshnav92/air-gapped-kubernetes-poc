#!/usr/bin/env bash
# Pod Security Admission levels per namespace (run from the bastion with kubectl).
#   kube-system : privileged  (Calico and kube-proxy need host access; set explicitly so it is a decision)
#   default     : enforce baseline, warn restricted
#   airgap-demo : enforce restricted (set in kubernetes/demo/airgap-demo.yaml)
set -euo pipefail
kubectl label ns kube-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label ns default pod-security.kubernetes.io/enforce=baseline \
                         pod-security.kubernetes.io/warn=restricted --overwrite
kubectl get ns --show-labels
