# APPS.md — Platform Interfaces for Services and Applications

This document defines the **integration interfaces** this infrastructure repo exposes.

Use this file to understand how other services/apps interact with the platform.  
Use `OPERATIONS.md` for runnable deployment/troubleshooting procedures.

---

## 1) Interface Overview

| Interface | Who uses it | Contract |
|-----------|-------------|----------|
| **GitOps app interface (Flux)** | App repos (auth-service, device-service) | App repo provides `k8s/` manifests + image policy marker; this repo provides Flux source/sync/image automation objects under `cluster/apps/<app>/`. |
| **Ansible app interface** | Operators/agents deploying platform-managed apps | App resources are applied by dedicated playbooks (`52_n8n.yml`, `53_litellm.yml`) and secrets/bootstrap via `59_app_services.yml`. |
| **Ingress interface (Cloudflare Tunnel)** | External users/clients | Public hostnames are defined in `infra/playbooks/40_platform.yml` ingress list and routed to in-cluster services. |
| **Service discovery interface** | In-cluster services/apps | Services are consumed via Kubernetes DNS: `<service>.<namespace>.svc.cluster.local[:port]`. |
| **Secrets interface** | App workloads + operators | Secret values originate in `infra/inventory/group_vars/all.sops.yml` and are materialized into Kubernetes Secrets by Ansible. |
| **Storage interface** | Stateful apps | Default StorageClass is Longhorn (RF=2); apps can request PVCs without explicit `storageClassName` unless they need `local-path`. |
| **Observability interface** | Apps exposing metrics | ServiceMonitors must live in `monitoring` namespace with label `release: kube-prometheus-stack`; app Services must expose a metrics port. |

---

## 2) Namespace Contract

| Namespace | Role | Rules |
|-----------|------|-------|
| `platform` | Platform components (cert-manager, cloudflared) | No app workloads. |
| `longhorn-system` | Longhorn storage system | Helm chart convention namespace. |
| `monitoring` | Prometheus/Grafana/Alertmanager + ServiceMonitors | ServiceMonitors for app workloads live here. |
| `apps` | Application workloads + shared app infrastructure | Resource limits required; no cluster-admin app ServiceAccounts. |
| `homeassistant` | Home Assistant workload | Dedicated namespace; hostNetwork workload. |
| `flux-system` | Flux controllers and GitOps/image automation resources | No application workloads. |

---

## 3) Public Exposure Interface (Cloudflare Tunnel)

Canonical public hostnames are configured in `infra/playbooks/40_platform.yml`.

| Public hostname | Routed service |
|-----------------|----------------|
| `ssh.furchert.ch` | `ssh://192.168.1.61:22` |
| `grafana.furchert.ch` | `http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80` |
| `auth.furchert.ch` | `http://auth-service.apps.svc.cluster.local:8080` |
| `device.furchert.ch` | `http://device-service.apps.svc.cluster.local:8081` |
| `n8n.furchert.ch` | `http://n8n.apps.svc.cluster.local:80` |
| `ai.furchert.ch` | `http://litellm.apps.svc.cluster.local:4000` |

**Contract rules:**
1. The ingress PUT updates the full list (not partial merge).
2. Keep all existing entries when adding one.
3. Keep `http_status:404` as the final fallback entry.

---

## 4) Internal Service Interface (Cluster DNS + Ports)

Shared services in `apps` namespace that other apps can consume:

| Service | Internal DNS | Port / Endpoint | Interface notes |
|---------|--------------|-----------------|-----------------|
| PostgreSQL 17 | `postgresql.apps.svc.cluster.local` | `5432` | Credentials via `postgresql-secret` / app-specific Secrets from `59_app_services.yml`. |
| InfluxDB 2 | `influxdb2.apps.svc.cluster.local` | service port `http` (chart default) | Metrics available at `/metrics` on service port `http`; admin token from SOPS vars. |
| Mosquitto 2 | `mosquitto.apps.svc.cluster.local` | `1883` | Currently anonymous LAN-oriented setup (`allow_anonymous true`) in `50_apps_infra.yml`; also exposed to LAN via `LoadBalancer` Service on port 1883. |
| Mosquitto exporter | `mosquitto-metrics.apps.svc.cluster.local` | `9234/metrics` | Prometheus scrape target. |
| LiteLLM | `litellm.apps.svc.cluster.local` | `4000` | OpenAI-compatible API; bearer auth with `LITELLM_MASTER_KEY`. |

Flux-managed app services (consumed by public URL and in-cluster DNS):
- `auth-service.apps.svc.cluster.local:8080`
- `device-service.apps.svc.cluster.local:8081`

---

## 5) API and Auth Interface

Only repo-verifiable API surfaces are documented here.

### LiteLLM (public and internal)
- Base URL: `https://ai.furchert.ch` (public), `http://litellm.apps.svc.cluster.local:4000` (internal)
- Auth: `Authorization: Bearer <LITELLM_MASTER_KEY>`
- Repo-verified endpoints:
  - `GET /health/liveliness`
  - `GET /models`
  - `POST /v1/chat/completions`
  - `GET /ui` (dashboard)
  - Source: `cluster/apps/litellm/deployment.yaml`, `scripts/smoke-test-litellm.sh`

### OIDC/Auth endpoints used by platform integrations
- Discovery: `https://auth.furchert.ch/.well-known/openid-configuration` (n8n config)
- Authorization: `https://auth.furchert.ch/oauth2/authorize` (LiteLLM SSO env)
- Token: `https://auth.furchert.ch/oauth2/token` (LiteLLM SSO env)
- UserInfo: `https://auth.furchert.ch/userinfo` (LiteLLM SSO env)

For full auth-service/device-service endpoint contracts, use app repos:
- https://github.com/doemefu/homelab-auth-service
- https://github.com/doemefu/homelab-device-service

---

## 6) Ownership and Reconciliation Interface

### Flux-managed apps
- `auth-service` and `device-service` are declared under `cluster/apps/` and referenced by `cluster/apps/kustomization.yaml`.
- Flux bootstrap in this repo does **not** auto-apply `cluster/apps` until `cluster/flux-system/apps-sync.yaml` is applied.
- Image automation contract:
  - app image tags match `^main-[0-9]{8}T[0-9]{6}$`
  - app deployment manifests in app repo include Flux `$imagepolicy` marker.

### Ansible-managed apps
- `n8n`: manifests in `cluster/apps/n8n/` applied by `infra/playbooks/52_n8n.yml`.
- `litellm`: manifests in `cluster/apps/litellm/` applied by `infra/playbooks/53_litellm.yml`.
- App/bootstrap secrets + DB/user provisioning: `infra/playbooks/59_app_services.yml`.

**Guardrails:**
- Do not add `n8n` or `litellm` to `cluster/apps/kustomization.yaml`.
- Do not add plaintext secret manifests under app directories.

---

## 7) Secrets Interface

### Source of truth
- Encrypted variables: `infra/inventory/group_vars/all.sops.yml`
- Template/generation hints: `infra/inventory/group_vars/all.sops.yml.example`

### Materialization pattern
- Kubernetes Secrets are created by Ansible `kubernetes.core.k8s` tasks in playbooks.
- Sensitive Secret tasks use `no_log: true`.

### Notable contract details
- `homelab-auth-secrets` contains auth-service client secrets with `{noop}` prefix where required by auth-service.
- n8n consumes raw client secret key (`n8n-client-secret`), while auth-service reads prefixed key (`n8n-client-secret-authservice`).
- `litellm_salt_key` is permanent after initial provisioning; rotating it invalidates existing virtual key decryption.

---

## 8) Runtime and Scheduling Interface

| Requirement | Contract |
|-------------|----------|
| Multi-arch images | Workloads should support both `linux/arm64` and `linux/amd64` across Pi and MBA nodes. |
| Resource limits | Required for workloads in `apps` namespace. |
| Storage class default | Longhorn default; use `local-path` only for explicit node-local/ephemeral needs. |
| Home Assistant networking | `homeassistant` namespace app uses `hostNetwork: true`, no public Cloudflare route by default. |

---

## 9) Observability Interface

To expose app metrics to Prometheus:
1. App Service exposes a named metrics port.
2. ServiceMonitor is created in namespace `monitoring`.
3. ServiceMonitor includes label `release: kube-prometheus-stack`.
4. `namespaceSelector` targets workload namespace (e.g. `apps`).

Reference implementation lives in `infra/playbooks/50_apps_infra.yml`.

---

## 10) Interface-to-Procedure Mapping

This file defines contracts.  
For runnable procedures and command sequences, use:

- `OPERATIONS.md` — deploy/redeploy, health checks, troubleshooting
- `CONTRIBUTING.md` — how to safely change this repository itself
- `README.md` — platform context + feature inventory + public URL/API overview
