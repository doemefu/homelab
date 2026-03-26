# Homelab Platform

Infrastructure-as-Code for a heterogeneous homelab cluster: Raspberry Pis + MacBook Airs,
provisioned with Ansible, running k3s, with Longhorn storage, Cloudflare Tunnel access,
and Prometheus/Grafana observability.

## Architecture

```
LAN
 ├─ raspi5 (arm64, 8 GB) — k3s Control-Plane + Worker, Backup-Target (USB/SSD)
 ├─ raspi4 (arm64, 4 GB) — k3s Worker
 ├─ mba1   (amd64, 8 GB) — k3s Worker, Docker/Home Assistant host
 └─ mba2   (amd64, 8 GB) — k3s Worker

Internet → Cloudflare Tunnel → cloudflared (in-cluster) → Traefik → Services
```

### Node Inventory

| Hostname | Hardware            | Arch  | RAM  | k3s Role              |
|----------|---------------------|-------|------|-----------------------|
| `raspi5` | Raspberry Pi 5      | arm64 | 8 GB | Control-Plane + Worker |
| `raspi4` | Raspberry Pi 4      | arm64 | 4 GB | Worker                |
| `mba1`   | MacBook Air 2020 i5 | amd64 | 8 GB | Worker + HA host      |
| `mba2`   | MacBook Air 2019 i5 | amd64 | 8 GB | Worker                |

### Stack

| Layer       | Technology                                  |
|-------------|---------------------------------------------|
| Provisioning | Ansible (idempotent, self-discovering)     |
| Secrets     | SOPS + age                                  |
| Cluster     | k3s (containerd, Traefik, ServiceLB)        |
| Storage     | Longhorn (RF=2, default StorageClass)       |
| Ingress/TLS | Traefik + cert-manager (Let's Encrypt)      |
| External    | Cloudflare Tunnel                           |
| Observability | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| Backups     | Restic → USB/SSD (pi5)                      |

### Pinned Versions

| Component             | Version        |
|-----------------------|----------------|
| k3s                   | v1.32.2+k3s1   |
| Longhorn              | 1.7.2          |
| cert-manager          | v1.17.1        |
| kube-prometheus-stack | 69.3.1         |
| cloudflared           | 2025.2.1       |

---

## Prerequisites

### On each node (before Ansible)
- Ubuntu 24.04 LTS installed, hostname set
- Static IP or DHCP reservation configured
- SSH key of the operator present for the initial user
- MacBook Air only: USB-C Ethernet adapter, `apple-bce` module loaded during install

### On your local machine
```bash
pip install ansible ansible-lint --break-system-packages
ansible-galaxy collection install -r infra/requirements.yml -p ~/.ansible/collections
# Note: helm@3 required — kubernetes.core.helm does not support Helm 4.x
brew install sops age helm@3 kubectl
```

age key + SOPS setup (once):
```bash
mkdir -p ~/.config/age
age-keygen -o ~/.config/age/homelab.key
# Add to ~/.zshrc — required by both sops and the Ansible vars plugin:
echo 'export SOPS_AGE_KEY_FILE=~/.config/age/homelab.key' >> ~/.zshrc
source ~/.zshrc
```

Kubeconfig (after `20_k3s.yml` has run):
```bash
# The playbook writes ~/.kube/homelab.yaml — use it directly or set an alias:
export KUBECONFIG=~/.kube/homelab.yaml
# or per-command: kubectl --kubeconfig ~/.kube/homelab.yaml get nodes
```

---

## Quick Start — Adding a New Node

1. Install Ubuntu 24.04 LTS, set hostname, ensure SSH access
2. Add node to `infra/inventory/hosts.yml` with its IP and group
3. Bootstrap (creates `ansible` user, hardens SSH, updates packages):
   ```bash
   ansible-playbook infra/playbooks/00_bootstrap.yml \
     -e ansible_user=<initial-user> -l <node> --become
   ```
4. Apply base configuration (OS, NTP, UFW, fail2ban, storage):
   ```bash
   ansible-playbook infra/playbooks/10_base.yml -l <node>
   ```
5. For k3s: run `20_k3s.yml` (see Milestones below)

**Target: < 30 minutes from fresh Ubuntu to cluster-joined.**

---

## Playbooks

| Playbook          | Purpose                                          | When to run         |
|-------------------|--------------------------------------------------|---------------------|
| `00_bootstrap.yml` | Create `ansible` user, SSH key, passwordless sudo | Once per new node  |
| `10_base.yml`     | OS baseline + hardening + storage + Restic cron (raspi5) | M1, then on changes |
| `20_k3s.yml`      | k3s server + agents + Longhorn prereqs          | M2                  |
| `30_longhorn.yml` | Longhorn Helm deploy + Default StorageClass     | M3                  |
| `40_platform.yml` | cert-manager, Cloudflare Tunnel, Traefik config, Monitoring | M2, M4              |

Run a playbook against all nodes:
```bash
ansible-playbook infra/playbooks/10_base.yml
```

Run against a single node:
```bash
ansible-playbook infra/playbooks/10_base.yml -l raspi5
```

Dry-run (no changes applied):
```bash
ansible-playbook infra/playbooks/10_base.yml --check --diff -l raspi5
```

---

## Milestones

| # | Status | Deliverable |
|---|--------|-------------|
| M1 | ✅ done (Pi nodes) | Ansible baseline + hardening — raspi5 + raspi4; mba1/mba2 deferred |
| M2 | ✅ done | k3s + Traefik + cert-manager + Cloudflare Tunnel |
| M3 | ✅ done | Longhorn v1.7.2 + RF=2 + Worker-Failover test |
| M4 | ✅ done | Monitoring (kube-prometheus-stack v69.3.1 + Grafana) + Restic Backups |
| M5 | ⬜ | Production-ready + all docs complete |

---

## Security Baseline

- SSH: keys only, `PasswordAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 3`
- UFW: default deny incoming; LAN-only rules for k3s, Longhorn, Node Exporter ports
- Secrets: SOPS + age — no plaintext in git, age key stored outside the repo
- External exposure: exclusively via Cloudflare Tunnel
- Namespaces: `platform`, `longhorn-system`, `monitoring`, `apps` — no cross-namespace deps from `apps`
- Longhorn Dashboard: internal only, no public Ingress

---

## Repository Structure

```
infra/
  inventory/
    hosts.yml               # Node IPs and group assignments
    group_vars/             # Variables per group (all, k3s_server, mac, …)
  playbooks/                # 00_bootstrap → 10_base → 20_k3s → 30_longhorn → 40_platform
  roles/
    base/                   # Hostname, timezone, NTP, packages, unattended-upgrades
    hardening/              # UFW, fail2ban, SSH hardening
    storage/                # Restic, backup directories, external mount (pi5)
    mac_tweaks/             # Lid-close fix, T2 kernel modules (x86_64 only)
    k3s/                    # k3s server + agent install (M2)
    longhorn_prereqs/       # open-iscsi, nfs-common, kernel modules (M3)
    observability_agent/    # Node Exporter (M4)
    docker/                 # Docker CE for Home Assistant host (M2)
cluster/
  platform/                 # Helm chart references
  values/                   # Pinned Helm values
examples/                   # Reference manifests for app deployments (M5)
docs/
  01-homelab-platform.md    # Full platform specification
```

For operational runbooks see `OPERATIONS.md`. For app deployment patterns see `APPS.md`.

---

## kubectl Quick Reference

All commands use `~/.kube/homelab.yaml`. Set once to avoid repeating the flag:

```bash
export KUBECONFIG=~/.kube/homelab.yaml
```

### Cluster Health

```bash
kubectl get nodes -o wide                          # Node status + IPs
kubectl get pods -A                                # All pods across all namespaces
kubectl get events -A --sort-by='.lastTimestamp'   # Recent events (errors first)
kubectl top nodes                                  # CPU/Memory per node (requires metrics-server)
```

### Storage (Longhorn)

```bash
kubectl get storageclass                                      # longhorn=default, local-path=non-default
kubectl get pvc -A                                            # All PVCs and their status
kubectl get volumes.longhorn.io -n longhorn-system            # Longhorn volumes + state
kubectl get replicas.longhorn.io -n longhorn-system           # Replica placement per volume
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80  # UI → http://localhost:8080
```

### TLS / cert-manager

```bash
kubectl get clusterissuer                          # letsencrypt-staging + letsencrypt-prod
kubectl get cert -A                                # All certificates + READY status
kubectl get certificaterequest -A                  # ACME challenge requests
kubectl describe cert <name> -n <namespace>        # Troubleshoot a failing certificate
```

### Networking

```bash
kubectl get ingress -A                             # All Ingress resources
kubectl get svc -A                                 # All Services
kubectl -n platform get pods                       # cert-manager, cloudflared pods
kubectl -n platform logs -l app=cloudflared --tail=50  # Cloudflare Tunnel logs
kubectl -n monitoring get pods                     # prometheus, grafana, alertmanager
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80  # Grafana UI → http://localhost:3000
```

### Debugging

```bash
kubectl describe pod <pod> -n <namespace>          # Events + container state
kubectl logs <pod> -n <namespace> --previous       # Logs of crashed container
kubectl exec -it <pod> -n <namespace> -- /bin/sh   # Shell into a running pod
kubectl get pod <pod> -n <namespace> -o yaml       # Full pod spec + status
```
