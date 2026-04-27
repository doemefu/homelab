# Homelab Platform — Infrastructure Overview

This is the **Infrastructure-as-Code** repository for a heterogeneous Kubernetes homelab cluster running on Raspberry Pis and MacBook Airs. This repository provides the platform layer; application code lives in separate repositories and is deployed onto this platform.

---

## Architecture

### Network Topology

```
Internet → Cloudflare Tunnel → cloudflared (in-cluster) → Traefik → Services
                           ↓
                    LAN (192.168.1.0/24)
```

### Node Inventory

| Hostname | Hardware | Arch | RAM | k3s Role | IP Address |
|----------|----------|------|-----|-----------|------------|
| `raspi5` | Raspberry Pi 5 | arm64 | 8 GB | Control-Plane + Worker | 192.168.1.61 |
| `raspi4` | Raspberry Pi 4 | arm64 | 4 GB | Worker | 192.168.1.163 |
| `mba1` | MacBook Air 2020 (i5) | amd64 | 8 GB | Worker | 192.168.1.66 |
| `mba2` | MacBook Air 2019 (i5) | amd64 | 8 GB | Worker | 192.168.1.16 |

### Namespace Layout

| Namespace | Purpose | Managed By |
|-----------|---------|------------|
| `platform` | Cluster infrastructure (cert-manager, cloudflared, Traefik) | Ansible |
| `longhorn-system` | Longhorn distributed storage | Helm (k3s) |
| `monitoring` | Prometheus, Grafana, Alertmanager, ServiceMonitors | Ansible/Helm |
| `apps` | Application workloads + shared infrastructure (PostgreSQL, InfluxDB, Mosquitto, n8n, LiteLLM) | Mixed |
| `homeassistant` | Home Assistant | Ansible/Helm |
| `flux-system` | Flux CD controllers | Flux (self-managed) |

---

## Technology Stack

### Provisioning & Configuration
- **Provisioning**: Ansible (idempotent, self-discovering playbooks)
- **Secrets Management**: SOPS + age (no plaintext secrets in git)
- **GitOps**: Flux CD (image automation for auth-service, device-service)

### Kubernetes Platform
- **Distribution**: k3s v1.32.2+k3s1 (lightweight, embedded etcd, ServiceLB)
- **Ingress**: Traefik (with Cloudflare Tunnel)
- **TLS**: cert-manager v1.17.1 with Let's Encrypt (DNS-01 challenge via Cloudflare)
- **CNI**: Flannel (VXLAN overlay)

### Storage
- **Primary**: Longhorn v1.7.2 (distributed block storage, RF=2, default StorageClass)
- **Fallback**: local-path (non-default, for node-local/ephemeral storage)
- **Backup**: Restic (daily at 03:00 on raspi5, repository on root filesystem)

### Observability
- **Metrics**: kube-prometheus-stack v69.3.1 (Prometheus operator)
- **Dashboards**: Grafana (public at `https://grafana.furchert.ch`)
- **Alerting**: Alertmanager with Discord webhook receiver
- **Exporters**: Node Exporter (DaemonSet), postgres-exporter, mosquitto-exporter

### External Access
- **Tunnel Provider**: Cloudflare Tunnel (cloudflared v0.1.2 helm chart)
- **DNS**: Cloudflare-managed domains

### Application Infrastructure (Shared Services in `apps` namespace)
- **PostgreSQL**: v17 (with postgres-exporter)
- **InfluxDB**: v2.x (with 30d retention, `homelab` org)
- **Mosquitto**: v2.x MQTT broker (with mosquitto-exporter)

### Application Runtimes
- **Home Assistant**: Deployed in `homeassistant` namespace with hostNetwork
- **n8n**: v2.17.1 (workflow automation, Ansible-managed)
- **LiteLLM**: v1.83.7-stable.patch.1 (AI gateway, OpenAI-compatible, Ansible-managed)

---

## Platform Features

| Area | Feature | Source of Truth |
|------|---------|-----------------|
| **Provisioning** | Idempotent node bootstrap, base hardening, storage setup | `infra/playbooks/00_bootstrap.yml`, `10_base.yml`, `infra/roles/{base,hardening,storage,mac_tweaks}` |
| **Kubernetes** | k3s install/upgrade, Traefik config, cert-manager, Cloudflare tunnel | `infra/playbooks/20_k3s.yml`, `40_platform.yml` |
| **Storage** | Longhorn as default StorageClass (RF=2), local-path as non-default fallback | `infra/playbooks/30_longhorn.yml`, `cluster/values/longhorn.yaml` |
| **Observability** | kube-prometheus-stack, ServiceMonitors, Alertmanager→Discord | `infra/playbooks/41_monitoring.yml`, `cluster/values/kube-prometheus-stack.yaml` |
| **Shared Infrastructure** | PostgreSQL 17, InfluxDB 2, Mosquitto 2 (+ exporters) | `infra/playbooks/50_apps_infra.yml`, `cluster/values/{postgresql,influxdb2}.yaml` |
| **App Runtimes** | Home Assistant, n8n, LiteLLM | `infra/playbooks/51_homeassistant.yml`, `52_n8n.yml`, `53_litellm.yml` |
| **App Secrets/Bootstrap** | Auth/device/n8n/litellm secrets + DB bootstrap | `infra/playbooks/59_app_services.yml` |
| **GitOps** | Flux CD sync + image automation for auth-service/device-service | `cluster/flux-system/apps-sync.yaml`, `cluster/apps/{auth-service,device-service}` |
| **Backup** | Restic-based node backups (daily 03:00 on raspi5) | `infra/roles/storage/`, `infra/playbooks/10_base.yml` |

---

## Public URLs and API Surfaces

All external access is via Cloudflare Tunnel. Canonical hostnames are configured in `infra/playbooks/40_platform.yml`.

### Endpoints

| URL | Type | Backing Service | Port | Notes |
|-----|------|------------------|------|-------|
| `ssh.furchert.ch` | SSH access | Node raspi5 | 22 | Cloudflare Access SSH proxy |
| `https://grafana.furchert.ch` | Web UI | `kube-prometheus-stack-grafana.monitoring.svc` | 80 | Grafana dashboard, login: admin |
| `https://auth.furchert.ch` | Service API | `auth-service.apps.svc:8080` | 8080 | JWT authentication service |
| `https://device.furchert.ch` | Service API | `device-service.apps.svc:8081` | 8081 | IoT device management service |
| `https://n8n.furchert.ch` | Web UI + Webhooks | `n8n.apps.svc:80` | 80 | Workflow automation platform (container: 5678) |
| `https://ai.furchert.ch` | OpenAI-compatible API + UI | `litellm.apps.svc:4000` | 4000 | LiteLLM AI gateway |

### OIDC/OAuth2 Endpoints (Auth Service)

| URL | Purpose | Used By |
|-----|---------|---------|
| `https://auth.furchert.ch/.well-known/openid-configuration` | OIDC discovery | n8n SSO configuration |
| `https://auth.furchert.ch/oauth2/authorize` | Authorization endpoint | LiteLLM SSO |
| `https://auth.furchert.ch/oauth2/token` | Token endpoint | LiteLLM SSO |
| `https://auth.furchert.ch/userinfo` | UserInfo endpoint | LiteLLM SSO |

### LiteLLM API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health/liveliness` | Liveness probe |
| GET | `/health/readiness` | Readiness probe |
| GET | `/models` | List available models |
| POST | `/v1/chat/completions` | OpenAI-compatible chat completions |
| GET | `/ui` | Web dashboard |

**Authentication**: Bearer token — `Authorization: Bearer <LITELLM_MASTER_KEY>`

**Available Routes**: `mistral-large`, `mistral-small`, `devstral`, `magistral`, `codestral` (all via latest aliases, Mistral-only; Anthropic disabled)

---

## Internal Service Endpoints

Services available for in-cluster consumption via Kubernetes DNS.

### Shared Infrastructure (`apps` namespace)

| Service | FQDN | Port | Notes |
|---------|------|------|-------|
| PostgreSQL 17 | `postgresql.apps.svc.cluster.local` | 5432 | Metrics: `:9187/metrics` (postgres-exporter) |
| InfluxDB 2 | `influxdb2.apps.svc.cluster.local` | 8086 | Metrics: `:80/metrics` (native) |
| Mosquitto 2 | `mosquitto.apps.svc.cluster.local` | 1883 | MQTT broker, anonymous (LAN-only) |
| Mosquitto Exporter | `mosquitto-metrics.apps.svc.cluster.local` | 9234 | Prometheus metrics endpoint |
| LiteLLM | `litellm.apps.svc.cluster.local` | 4000 | AI gateway |
| n8n | `n8n.apps.svc.cluster.local` | 80 | Workflow automation (container: 5678) |

### Flux-Managed Services

| Service | FQDN | Port | Status |
|---------|------|------|--------|
| auth-service | `auth-service.apps.svc.cluster.local` | 8080 | Deployed, Flux-managed |
| device-service | `device-service.apps.svc.cluster.local` | 8081 | Deployed, Flux-managed |

### Home Assistant

| Service | Node Access | Notes |
|---------|-------------|-------|
| Home Assistant | `http://<node-ip>:8123` | hostNetwork, direct node port access |

---

## Current Status

### Milestones Completed

| # | Status | Deliverable |
|---|--------|-------------|
| M1 | ✅ Done | Ansible baseline + hardening — all 4 nodes |
| M2 | ✅ Done | k3s cluster + Traefik + cert-manager + Cloudflare Tunnel |
| M3 | ✅ Done | Longhorn v1.7.2 + RF=2 + Worker-Failover test |
| M4 | ✅ Done | Monitoring (kube-prometheus-stack v69.3.1 + Grafana) + Restic Backups |
| M5 | ✅ Done | Production-ready: examples/ created, Grafana PVC, Alertmanager → Discord |
| M6 | ✅ Done | App infrastructure: PostgreSQL 17, InfluxDB 2, Mosquitto 2, Home Assistant |
| M7 | ✅ Done | Flux CD GitOps: auto-deployments for auth-service + device-service |
| M8 | ✅ Done | LiteLLM AI gateway v1.83.7-stable.patch.1 + public endpoint |

### Resolved Issues

| Item | Description | Status |
|------|-------------|--------|
| raspi4 SSH tunnel | Cloudflare Tunnel ingress not yet configured for raspi4 | ⚠️ Open (see below) |
| Restic restore test | Documented restore procedure awaits external SSD attachment | ⚠️ Deferred |

> **Note on raspi4 SSH**: The SSH tunnel for raspi4 (`ssh-raspi4.furchert.ch → 192.168.1.163:22`) is not yet configured in `40_platform.yml`. To add: include `- hostname: ssh-raspi4.furchert.ch, service: ssh://192.168.1.163:22` in the ingress list, then re-run `ansible-playbook infra/playbooks/40_platform.yml`.

---

## Security Baseline

| Area | Configuration |
|------|---------------|
| **SSH** | Keys only, `PasswordAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 3` |
| **Firewall (UFW)** | Default deny incoming; LAN-only rules for k3s, Longhorn, Node Exporter, Mosquitto ports |
| **Secrets** | SOPS + age encryption; no plaintext in git; age key stored outside repo |
| **External Exposure** | Exclusively via Cloudflare Tunnel (no public IPs, no port forwarding) |
| **Namespaces** | Isolated: `platform`, `longhorn-system`, `monitoring`, `apps`, `homeassistant`, `flux-system` |
| **Storage** | Longhorn default (RF=2), local-path non-default fallback |
| **Access Control** | No cluster-admin ServiceAccounts in `apps` namespace |

---

## Repository Structure

```
infra/
  inventory/
    hosts.yml                 # Node IPs and group assignments
    group_vars/
      all.yml                  # Common variables (non-secret)
      all.sops.yml             # Encrypted secrets (SOPS + age)
      all.sops.yml.example     # Template with CHANGE_ME placeholders
      k3s_server.yml           # Control-plane specific vars
      k3s_agent.yml            # Worker node vars
      mac.yml                  # Mac-specific tweaks
      docker_hosts.yml         # Docker host configuration
  playbooks/                 # Sequential deployment (00_bootstrap → 59_app_services)
    00_bootstrap.yml          # Initial node setup (Python, ansible user, SSH key)
    10_base.yml               # Base packages, hardening, UFW, fail2ban
    20_k3s.yml                # k3s installation and configuration
    30_longhorn.yml           # Longhorn storage system
    40_platform.yml           # cert-manager, Cloudflare Tunnel, Traefik
    41_monitoring.yml         # kube-prometheus-stack (Helm)
    50_apps_infra.yml         # Shared app infrastructure (PostgreSQL, InfluxDB, Mosquitto)
    51_homeassistant.yml      # Home Assistant deployment
    52_n8n.yml                 # n8n deployment (Ansible-managed)
    53_litellm.yml            # LiteLLM deployment (Ansible-managed)
    59_app_services.yml       # App secrets and bootstrap (auth, n8n, litellm)
  roles/
    base/                     # Hostname, timezone, NTP, packages, unattended-upgrades
    hardening/                # UFW, fail2ban, SSH hardening
    storage/                  # Restic, backup directories, external mount
    mac_tweaks/               # Lid-close fix, T2 kernel modules, watchdog
    k3s/                      # k3s server + agent install
    longhorn_prereqs/         # open-iscsi, nfs-common, kernel modules
    observability_agent/      # Node Exporter preparation (placeholder)
    docker/                   # Docker CE for Home Assistant host

cluster/
  flux-system/                # Flux CD bootstrap and GitOps sync
    gotk-components.yaml       # Flux controllers (auto-generated)
    gotk-sync.yaml             # Flux configuration sync
    apps-sync.yaml             # Kustomization for app reconciliation
  apps/                       # Application manifests
    kustomization.yaml          # Lists Flux-managed apps
    auth-service/              # Flux reconciliation objects
      source.yaml              # GitRepository resource
      sync.yaml                # Kustomization resource
      imagerepo.yaml           # ImageRepository for GHCR
      imagepolicy.yaml         # ImagePolicy for tag filtering
      imageupdate.yaml         # ImageUpdateAutomation for write-back
    device-service/            # Same structure as auth-service
    n8n/                       # Ansible-managed manifests
      deployment.yaml
      service.yaml
      pvc.yaml
      kustomization.yaml
    litellm/                   # Ansible-managed manifests
      configmap.yaml
      deployment.yaml
      service.yaml
      kustomization.yaml
  platform/                   # Helm chart references (remote charts)
  values/                     # Pinned Helm values
    kube-prometheus-stack.yaml # Prometheus/Grafana/Alertmanager config
    cloudflared.yaml           # Cloudflare Tunnel Helm values
    longhorn.yaml              # Longhorn storage config
    cert-manager.yaml          # cert-manager config
    postgresql.yaml            # PostgreSQL 17 config
    influxdb2.yaml              # InfluxDB 2 config
    home-assistant.yaml         # Home Assistant config

examples/                    # Reference manifests for app deployments
  simple-deployment.yml      # Basic deployment + service template
  with-postgres.yml           # App with PostgreSQL backend
  with-ingress-public.yml     # Cloudflare Tunnel exposure
  helm-values-template.yml    # Helm values starting point

docs/                        # Architecture and planning documents
  01-homelab-platform.md      # Full platform specification
  050-iot-app-rewrite.md      # IoT app migration plan
  051-architecture-current.md # Legacy monolith architecture
  052-architecture-target.md  # Target microservices architecture
  plans/                      # Feature plans
  specs/                      # Architecture specifications

scripts/                     # Utility scripts
  smoke-test-litellm.sh       # LiteLLM health and endpoint verification

.agent/                       # Agent workflow files
.claude/                      # Claude agent configurations
.github/                      # GitHub workflows
```

---

## Related Repositories

This repository provides the **platform infrastructure**. Application services that run on this cluster live in their own repositories:

| Repository | Description | Status | Deployment |
|------------|-------------|--------|------------|
| [homelab-auth-service](https://github.com/doemefu/homelab-auth-service) | JWT authentication service — user CRUD, token issuance, JWKS endpoint | Deployed | Flux-managed |
| [homelab-device-service](https://github.com/doemefu/homelab-device-service) | Real-time IoT device management — MQTT, InfluxDB writer, WebSocket, scheduling | Deployed | Flux-managed |
| homelab-data-service | Historical data queries (InfluxDB) + schedule CRUD | Not yet created | - |

Architecture and migration planning documents are in `docs/`.

---

## Next Steps

| Task | File |
|------|------|
| Understand how to deploy apps on this platform | **[APP-DEPLOYMENT.md](APP-DEPLOYMENT.md)** |
| View platform interfaces and contracts | **[INTERFACES.md](INTERFACES.md)** |
| Contribute to this infrastructure repo | **[DEVELOPMENT.md](DEVELOPMENT.md)** |
| Deploy or operate the cluster | **[DEPLOYMENT.md](DEPLOYMENT.md)** |
