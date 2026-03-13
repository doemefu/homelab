# Homelab Platform

Infrastructure-as-Code for a heterogeneous homelab cluster: Raspberry Pis + MacBook Airs,
provisioned with Ansible, running k3s, with Longhorn storage, Cloudflare Tunnel access,
and Prometheus/Grafana observability.

## Architecture

```
LAN
 ├─ pi5  (arm64, 8 GB) — k3s Control-Plane + Worker, Backup-Target (USB/SSD)
 ├─ pi4  (arm64, 4 GB) — k3s Worker
 ├─ mba1 (amd64, 8 GB) — k3s Worker, Docker/Home Assistant host
 └─ mba2 (amd64, 8 GB) — k3s Worker

Internet → Cloudflare Tunnel → cloudflared (in-cluster) → Traefik → Services
```

### Node Inventory

| Hostname | Hardware            | Arch  | RAM  | k3s Role              |
|----------|---------------------|-------|------|-----------------------|
| `pi5`    | Raspberry Pi 5      | arm64 | 8 GB | Control-Plane + Worker |
| `pi4`    | Raspberry Pi 4      | arm64 | 4 GB | Worker                |
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
| Observability | kube-prometheus-stack (Prometheus + Grafana) |
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
brew install sops age helm kubectl
```

age key setup (once):
```bash
mkdir -p ~/.config/age
age-keygen -o ~/.config/age/homelab.key
# Add the public key to .sops.yaml
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
| `10_base.yml`     | OS baseline + hardening + storage               | M1, then on changes |
| `20_k3s.yml`      | k3s server + agents                             | M2                  |
| `30_longhorn.yml` | Longhorn prerequisites + Helm deploy            | M3                  |
| `40_platform.yml` | cert-manager, cloudflared, monitoring           | M4                  |

Run a playbook against all nodes:
```bash
ansible-playbook infra/playbooks/10_base.yml
```

Run against a single node:
```bash
ansible-playbook infra/playbooks/10_base.yml -l pi5
```

Dry-run (no changes applied):
```bash
ansible-playbook infra/playbooks/10_base.yml --check --diff -l pi5
```

---

## Milestones

| # | Status | Deliverable |
|---|--------|-------------|
| M1 | 🔄 in progress | Ansible baseline + hardening on all 4 nodes |
| M2 | ⬜ | k3s + Traefik + cert-manager + Cloudflare Tunnel |
| M3 | ⬜ | Longhorn + replication + failover test |
| M4 | ⬜ | Monitoring + backups + restore test |
| M5 | ⬜ | Production-ready + all docs complete |

---

## Security Baseline

- SSH: keys only, `PasswordAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 3`
- UFW: default deny incoming; LAN-only rules for k3s, Longhorn, Node Exporter ports
- Secrets: SOPS + age — no plaintext in git, age key stored outside the repo
- External exposure: exclusively via Cloudflare Tunnel
- Namespaces: `platform`, `monitoring`, `apps` — no cross-namespace deps from `apps`
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
