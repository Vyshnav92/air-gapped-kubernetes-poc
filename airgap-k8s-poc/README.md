# Air-Gapped Kubernetes Cluster PoC

A multi-node Kubernetes cluster (kubeadm, 1 control plane + 2 workers) built and run inside an
isolated network with **zero internet access**. Every package, image and binary is harvested on a
connected workstation, shipped in as one ISO, and served to the cluster from a local bastion.

## Architecture

```
  CONNECTED SIDE                          AIR-GAPPED SIDE (192.168.50.0/24, no uplink, no default route)
  ──────────────                          ───────────────────────────────────────────────────────────────
  Workstation                             bastion-mirror  192.168.50.10
  download-artifacts.sh                   ├─ Registry (CNCF Distribution, TLS :5000)   images + Helm charts
   ├─ debs + dependencies   ── ISO ──►    ├─ nginx :80        apt repo + binaries
   ├─ images (skopeo)      (virtual       ├─ dnsmasq :53      internal DNS, external names refused
   ├─ binaries + checksums   CD-ROM,      ├─ chrony :123      time source
   └─ BOM, SHA256SUMS, ISO   one-way)     ├─ Root CA          signs the registry certificate
                                          └─ Ansible          configures the nodes
                                                   │
                                   ┌───────────────┼───────────────┐
                                   ▼               ▼               ▼
                              k8s-cp-01      k8s-worker-01    k8s-worker-02
                              .11            .12              .13
                              control plane  worker           worker
```

The only thing that crosses into the isolated network is the ISO. Nothing inside can reach out.

## Versions

| Component | Version |
| --- | --- |
| OS | Ubuntu 22.04 LTS |
| Kubernetes | 1.28.15 (as required by the assignment; EOL upstream, see upgrade notes in the runbook) |
| containerd | 1.7.29 |
| CNI | Calico v3.28.5 |
| Registry | CNCF Distribution v3.0.0 |
| Helm | 3.16.4 |
| Pod / Service CIDR | 10.244.0.0/16 / 10.96.0.0/12 |

## Repository layout

| Path | What it is | Where it runs |
| --- | --- | --- |
| `workstation/download-artifacts.sh` | Harvests everything and builds the ISO | Connected workstation |
| `bastion/registry/` | Registry config + systemd unit | bastion-mirror |
| `bastion/nginx/`, `dnsmasq/`, `chrony/` | Repo server, internal DNS, time server configs | bastion-mirror |
| `bastion/pki/` | How the Root CA and registry certificate are made (no keys) | bastion-mirror |
| `bastion/scripts/load-images.sh` | Pushes the image tarballs into the registry | bastion-mirror |
| `bastion/scripts/add-mirror-aliases.sh` | Extra image names so containerd mirror rules work | bastion-mirror |
| `ansible/` | Node preparation playbooks (`site.yml` runs them all) | bastion → nodes |
| `kubernetes/kubeadm-config.yaml` | Cluster definition (`imageRepository: bastion-mirror:5000/k8s`) | k8s-cp-01 |
| `kubernetes/calico.yaml` | Calico manifest, images swapped to the local registry, pod CIDR set | kubectl |
| `kubernetes/tests/` | Acceptance test 4 workload, Pod Security test | kubectl |
| `kubernetes/demo/` | Air-gap proof app, NetworkPolicies, RBAC | kubectl |
| `kubernetes/security/` | Pod Security labels, Secrets encryption template | kubectl / k8s-cp-01 |
| `docs/` | Runbook, decisions, acceptance test report | |

## Build order

1. **Workstation:** `./workstation/download-artifacts.sh` produces `airgap-bundle-v1.0.iso`.
2. **Proxmox:** attach the ISO to bastion-mirror as a CD-ROM.
3. **Bastion:** mount the ISO, verify `SHA256SUMS`, extract to `/srv/airgap/bundle`, install packages
   from the local repo, create the CA (`bastion/pki/`), start the registry, nginx, dnsmasq, chrony,
   run `load-images.sh` and `add-mirror-aliases.sh`.
4. **Nodes:** `cd ansible && ansible-playbook site.yml`.
5. **Cluster:** `kubeadm init --config=kubeadm-config.yaml` on k8s-cp-01, `kubectl apply -f calico.yaml`,
   `kubeadm join` on both workers.
6. **Security:** `kubernetes/security/pod-security.sh`, `kubectl apply -f kubernetes/demo/`, Secrets encryption.

Full step-by-step instructions, troubleshooting and the mirror update procedure are in `docs/`.

## Air-gap specific fixes

The nodes have no default route by design. Kubernetes assumes one exists, so `ansible/node-network.yml`:

- sets kubelet's `--node-ip` explicitly (kubelet normally detects it from the default route);
- adds a route for the Service CIDR only (10.96.0.0/12), so pods can reach ClusterIPs;
- adds a /32 route for 169.254.1.1, Calico's pod gateway, so the node answers proxy ARP for pods.

External traffic stays unreachable: every outside request fails instantly.

## Not in this repository

- Private keys (`ca.key`, `registry.key`), the Secrets encryption key, kubeconfig files.
- The ISO, debs and image tarballs: they are large and fully reproducible with `download-artifacts.sh`.
