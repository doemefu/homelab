# Homelab Platform

Infrastructure-as-Code for a heterogeneous homelab cluster: Raspberry Pis + MacBook Airs,
provisioned with Ansible, running k3s, with Longhorn storage, Cloudflare Tunnel access,
and Prometheus/Grafana observability.

This repository is the **platform layer** for the homelab ecosystem. Application code lives in
separate repositories and is deployed onto this platform via Flux (auth-service/device-service)
or Ansible-managed manifests (n8n/LiteLLM).

## Architecture

```
LAN
 ├─ raspi5 (arm64, 8 GB) — k3s Control-Plane + Worker, Backup-Target (USB/SSD)
 ├─ raspi4 (arm64, 4 GB) — k3s Worker
 ├─ mba1   (amd64, 8 GB) — k3s Worker
 └─ mba2   (amd64, 8 GB) — k3s Worker

Internet → Cloudflare Tunnel → cloudflared (in-cluster) → Traefik → Services
```

### Node Inventory

| Hostname | Hardware            | Arch  | RAM  | k3s Role              |
|----------|---------------------|-------|------|-----------------------|
| `raspi5` | Raspberry Pi 5      | arm64 | 8 GB | Control-Plane + Worker |
| `raspi4` | Raspberry Pi 4      | arm64 | 4 GB | Worker                |
| `mba1`   | MacBook Air 2020 i5 | amd64 | 8 GB | Worker                |
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
| GitOps      | Flux CD (image automation + app deployments) |
| AI Gateway  | LiteLLM v1.83.7-stable.patch.1 (OpenAI-compatible proxy) |
| Backups     | Restic → USB/SSD (pi5)                      |

### Pinned Versions

| Component             | Version        |
|-----------------------|----------------|
| k3s                   | v1.32.2+k3s1   |
| Longhorn              | 1.7.2          |
| cert-manager          | v1.17.1        |
| kube-prometheus-stack | 69.3.1         |
| cloudflared           | 2025.2.1       |
| Flux CD               | v2.8.5 (bootstrap manifests in `cluster/flux-system/gotk-components.yaml`) |
| postgres-exporter     | v0.15.0        |
| mosquitto-exporter    | v0.6.3         |
| LiteLLM               | v1.83.7-stable.patch.1 |

---

## Platform Features (What this repo delivers)

| Area | Feature | Source of truth |
|------|---------|-----------------|
| Provisioning | Idempotent node bootstrap, base hardening, storage setup | `infra/playbooks/00_bootstrap.yml`, `10_base.yml` |
| Kubernetes platform | k3s install/upgrade, Traefik config, cert-manager, Cloudflare tunnel | `20_k3s.yml`, `40_platform.yml` |
| Storage | Longhorn as default StorageClass (RF=2), local-path as non-default fallback | `30_longhorn.yml` |
| Observability | kube-prometheus-stack, ServiceMonitors, Alertmanager→Discord | `41_monitoring.yml`, `cluster/values/kube-prometheus-stack.yaml` |
| Shared app infra | PostgreSQL 17, InfluxDB 2, Mosquitto 2 (+ exporters) | `50_apps_infra.yml` |
| App runtimes | Home Assistant, n8n, LiteLLM | `51_homeassistant.yml`, `52_n8n.yml`, `53_litellm.yml` |
| App secrets/bootstrap | Auth/device/n8n/litellm secrets + DB bootstrap | `59_app_services.yml` |
| GitOps | Flux CD sync + image automation for auth-service/device-service | `cluster/flux-system/apps-sync.yaml`, `cluster/apps/{auth-service,device-service}` |
| Backup | Restic-based node backups | `infra/roles/storage/` |

---

## Public URLs and API Surfaces

Canonical external hostnames are managed via Cloudflare Tunnel ingress in `infra/playbooks/40_platform.yml`.

| URL / Surface | Type | Backing service | Notes |
|---------------|------|-----------------|-------|
| `ssh.furchert.ch` | SSH access | `ssh://192.168.1.61:22` | Cloudflare Access SSH proxy to raspi5 |
| `https://grafana.furchert.ch` | Web UI | `kube-prometheus-stack-grafana.monitoring.svc` | Grafana dashboard UI |
| `https://auth.furchert.ch` | Service URL | `auth-service.apps.svc:8080` | Auth service base URL (detailed endpoint contract in app repo) |
| `https://device.furchert.ch` | Service URL | `device-service.apps.svc:8081` | Device service base URL (detailed endpoint contract in app repo) |
| `https://n8n.furchert.ch` | Web UI + webhooks | `n8n.apps.svc:80` | n8n public host and webhook base |
| `https://ai.furchert.ch` | OpenAI-compatible API + UI | `litellm.apps.svc:4000` | LiteLLM gateway (`/models`, `/v1/chat/completions`, `/health/liveliness`, `/ui`) |
| `https://auth.furchert.ch/.well-known/openid-configuration` | OIDC discovery | auth-service | Referenced by n8n SSO config in `cluster/apps/n8n/deployment.yaml` |
| `https://auth.furchert.ch/oauth2/authorize` | OIDC/OAuth2 endpoint | auth-service | Referenced by LiteLLM OIDC env config |
| `https://auth.furchert.ch/oauth2/token` | OIDC/OAuth2 endpoint | auth-service | Referenced by LiteLLM OIDC env config |
| `https://auth.furchert.ch/userinfo` | OIDC endpoint | auth-service | Referenced by LiteLLM OIDC env config |

For deep API schemas and endpoint contracts, see:
- [homelab-auth-service](https://github.com/doemefu/homelab-auth-service)
- [homelab-device-service](https://github.com/doemefu/homelab-device-service)

---

## Where to go next

- **Deploy / operate the platform:** `OPERATIONS.md`
- **Understand app/platform contracts:** `APPS.md`
- **Contribute safely to this repo:** `CONTRIBUTING.md`

---

## Milestones

| # | Status | Deliverable |
|---|--------|-------------|
| M1 | ✅ done | Ansible baseline + hardening — all 4 nodes (raspi5, raspi4, mba1, mba2); k3s cluster complete |
| M2 | ✅ done | k3s + Traefik + cert-manager + Cloudflare Tunnel |
| M3 | ✅ done | Longhorn v1.7.2 + RF=2 + Worker-Failover test |
| M4 | ✅ done | Monitoring (kube-prometheus-stack v69.3.1 + Grafana) + Restic Backups |
| M5 | ✅ done | Production-ready: APPS.md complete, examples/ created, Grafana PVC, Alertmanager → Discord |
| M6 | ✅ done | App infrastructure: PostgreSQL 17, InfluxDB 2, Mosquitto 2 (`apps` ns); Home Assistant (`homeassistant` ns, hostNetwork, http://node-ip:8123) |
| M7 | ✅ done | Flux CD GitOps: automated deployments for auth-service + device-service via ImagePolicy + ImageUpdateAutomation |
| M8 | ✅ done | LiteLLM AI gateway v1.83.7-stable.patch.1 (`apps` ns); public at `https://ai.furchert.ch`; routes: `mistral-large`, `mistral-small`, `devstral`, `magistral`, `codestral` (all via latest aliases); Anthropic routes intentionally disabled; Postgres DB `litellm` on shared postgresql instance |

---

## Open Items (Post-M5)

Infrastructure work that is explicitly deferred — the cluster is fully operational without these.

| Item | Description |
|------|-------------|
| **raspi4 SSH tunnel** | Add `ssh-raspi4.furchert.ch → 192.168.1.163:22` to cloudflared ingress in `40_platform.yml` (same pattern as raspi5) |
| **Restic restore test** | Run the documented restore procedure (`OPERATIONS.md → Backup → Restore`) after external SSD is attached to raspi5 |

Planned extensions (see `docs/01-homelab-platform.md` → Erweiterungen):
- kured — automated node reboots after kernel updates
- Cloudflare Zero Trust Access Policy for SSH
- Automated update script with rollback

---

## Security Baseline

- SSH: keys only, `PasswordAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 3`
- UFW: default deny incoming; LAN-only rules for k3s, Longhorn, Node Exporter ports
- Secrets: SOPS + age — no plaintext in git, age key stored outside the repo
- External exposure: exclusively via Cloudflare Tunnel
- Namespaces: `platform`, `longhorn-system`, `monitoring`, `apps`, `homeassistant`, `flux-system` (no cross-namespace deps from `apps`)
- Longhorn Dashboard: internal only, no public Ingress

---

## Repository Structure

```
infra/
  inventory/
    hosts.yml               # Node IPs and group assignments
    group_vars/             # Variables per group (all, k3s_server, mac, …)
  playbooks/                # 00_bootstrap → 10_base → 20_k3s → 30_longhorn → 40_platform → 50_apps_infra → 51_homeassistant → 52_n8n → 53_litellm → 59_app_services
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
  flux-system/              # Flux bootstrap components (auto-generated by flux bootstrap)
                            #   apps-sync.yaml — Kustomization pointing to cluster/apps/
  apps/                     # App manifests: Flux-managed (auth-service, device-service) + Ansible-managed n8n base manifests
    kustomization.yaml      # Lists device-service/ and auth-service/
    device-service/         # source, sync, imagerepo, imagepolicy, imageupdate CRDs
    auth-service/           # source, sync, imagerepo, imagepolicy, imageupdate CRDs
    n8n/                    # n8n manifests (deployment, service, pvc) applied by 52_n8n.yml
    litellm/                # LiteLLM manifests (configmap, deployment, service) applied by 53_litellm.yml
  platform/                 # Helm chart references
  values/                   # Pinned Helm values (kube-prometheus-stack, cloudflared, longhorn,
                            #   influxdb2, home-assistant)
examples/                   # Reference manifests for app deployments (see APPS.md)
                            #   simple-deployment, with-postgres, with-ingress-public, helm-values-template
docs/
  01-homelab-platform.md    # Full platform specification
  050-iot-app-rewrite.md    # IoT app migration plan (monolith -> microservices)
  051-architecture-current.md  # Legacy monolith architecture
  052-architecture-target.md   # Target microservices architecture
```

For operational runbooks see `OPERATIONS.md`. For app deployment patterns see `APPS.md`.

---

## Related Repositories

This repo provides the platform infrastructure. The application services run on this cluster and live in their own repos:

| Repo | Description | Status |
|------|-------------|--------|
| [homelab-auth-service](https://github.com/doemefu/homelab-auth-service) | JWT authentication service — user CRUD, token issuance, JWKS endpoint | Deployed; Flux-managed |
| [homelab-device-service](https://github.com/doemefu/homelab-device-service) | Real-time IoT device management — MQTT, InfluxDB writer, WebSocket, scheduling | Deployed; Flux-managed |
| homelab-data-service | Historical data queries (InfluxDB) + schedule CRUD | Not yet created |

Architecture docs for the full migration plan are in `docs/`.

---
