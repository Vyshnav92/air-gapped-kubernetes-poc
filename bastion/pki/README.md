# Local Root CA and registry certificate

Run on **bastion-mirror** in `/srv/airgap/pki`. The keys never leave the bastion and are never committed.

```bash
sudo mkdir /srv/airgap/pki && cd /srv/airgap/pki

# 1. The CA: private key + self-signed certificate (10 years)
sudo openssl genrsa -out ca.key 4096
sudo openssl req -x509 -new -key ca.key -days 3650 -subj "/CN=Airgap Lab Root CA" -out ca.crt

# 2. The registry: private key + signing request
sudo openssl genrsa -out registry.key 2048
sudo openssl req -new -key registry.key -subj "/CN=bastion-mirror" -out registry.csr

# 3. Every name the registry is reached by (SANs)
echo "subjectAltName=DNS:bastion-mirror,DNS:bastion-mirror.lab.home.arpa,IP:192.168.50.10" | sudo tee registry.ext

# 4. The CA signs the registry certificate
sudo openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -extfile registry.ext -out registry.crt

# 5. Lock down the private keys
sudo chmod 600 ca.key registry.key

# 6. Trust the CA on the bastion itself
sudo cp ca.crt /usr/local/share/ca-certificates/airgap-lab-ca.crt
sudo update-ca-certificates
openssl verify -CAfile ca.crt registry.crt   # registry.crt: OK
```

The nodes get `ca.crt` (public part only) through Ansible: in the OS trust store and in
`/etc/containerd/certs.d/bastion-mirror:5000/`.

| File | Secret? | Where it goes |
| --- | --- | --- |
| `ca.key` | Yes | Stays on the bastion only |
| `ca.crt` | No | Every node |
| `registry.key` | Yes | Bastion only (used by the registry) |
| `registry.crt` | No | Shown to every client that connects |
