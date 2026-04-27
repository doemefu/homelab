# Platform Interfaces — How Services Integrate with the Homelab

This document defines all **integration interfaces** this infrastructure platform exposes to external services, applications, and developers. Use this to understand how to connect with, consume from, or deploy onto this platform.

> **For deploying YOUR apps on this platform**: See **[APP-DEPLOYMENT.md](APP-DEPLOYMENT.md)**
> **For platform contracts and source-of-truth locations**: See **[INTERFACES.md](INTERFACES.md)**

---

## 1) Interface Overview

| Interface | Audience | Contract | Source of Truth |
|-----------|----------|----------|-----------------|
| **Public URL Interface** | External clients, end users | Public hostnames routed via Cloudflare Tunnel | `infra/playbooks/40_platform.yml` |
| **Internal Service Discovery** | In-cluster workloads | Kubernetes DNS: `<service>.<namespace>.svc.cluster.local` | Kubernetes Service objects |
| **GitOps Interface (Flux)** | App repositories (auth-service, device-service) | Flux reconciliation from `cluster/apps/<app>/` | `cluster/apps/`, `cluster/flux-system/apps-sync.yaml` |
| **Ansible App Interface** | Ansible-managed apps (n8n, LiteLLM, Home Assistant) | Playbook-applied manifests from `cluster/apps/<app>/` | `infra/playbooks/52_n8n.yml`, `53_litellm.yml`, `51_homeassistant.yml`, `59_app_services.yml` |
| **Storage Interface** | Stateful workloads | Longhorn default StorageClass (RF=2), local-path for ephemeral | `infra/playbooks/30_longhorn.yml` |
| **Secrets Interface** | Workloads needing credentials | SOPS-encrypted vars → Kubernetes Secrets | `infra/inventory/group_vars/all.sops.yml`, `infra/playbooks/59_app_services.yml` |
| **Observability Interface** | Metrics-producing workloads | ServiceMonitors in `monitoring` namespace with `release: kube-prometheus-stack` label | `infra/playbooks/50_apps_infra.yml` (reference implementation) |
| **Network Interface** | Firewall rules, port exposure | UFW LAN-only rules, Cloudflare Tunnel for external | `infra/roles/hardening/`, `infra/playbooks/40_platform.yml` |

---

## 2) Namespace Contract

| Namespace | Owner | Permitted Workloads | Prohibited |
|-----------|-------|---------------------|------------|
| `platform` | Ansible | cert-manager, cloudflared, Traefik | Any app workloads |
| `longhorn-system` | Helm (k3s) | Longhorn components only | Any non-Longhorn workloads |
| `monitoring` | Ansible/Helm | Prometheus, Grafana, Alertmanager, **ServiceMonitors for all namespaces** | App workloads, non-observability resources |
| `apps` | Mixed | Application workloads, shared infrastructure (PostgreSQL, InfluxDB, Mosquitto, n8n, LiteLLM) | Cluster-admin ServiceAccounts, workloads without resource limits |
| `homeassistant` | Ansible/Helm | Home Assistant only | Any non-HA workloads |
| `flux-system` | Flux CD | Flux controllers only | Any application workloads |

> **Do not create namespaces outside this list** without explicit approval (CLAUDE.md non-negotiable).

---

## 3) Public Exposure Interface (Cloudflare Tunnel)

All external access goes through Cloudflare Tunnel. Public hostnames are **centrally managed** in `infra/playbooks/40_platform.yml` via the Cloudflare API.

### Current Public Endpoints

| Hostname | Service Target | Protocol | Backing Service | Notes |
|----------|----------------|----------|------------------|-------|
| `ssh.furchert.ch` | `ssh://192.168.1.61:22` | SSH | raspi5 node | Cloudflare Access SSH proxy |
| `grafana.furchert.ch` | `http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80` | HTTP | Grafana | Dashboard UI |
| `auth.furchert.ch` | `http://auth-service.apps.svc.cluster.local:8080` | HTTP | auth-service | JWT auth service |
| `device.furchert.ch` | `http://device-service.apps.svc.cluster.local:8081` | HTTP | device-service | IoT device management |
| `n8n.furchert.ch` | `http://n8n.apps.svc.cluster.local:80` | HTTP | n8n | Workflow automation (container: 5678) |
| `ai.furchert.ch` | `http://litellm.apps.svc.cluster.local:4000` | HTTP | LiteLLM | AI gateway, OpenAI-compatible |

### Adding a New Public Endpoint

To expose a new service publicly via Cloudflare Tunnel:

1. **Add ingress entry** in `infra/playbooks/40_platform.yml`. Add to the `ingress` list in the `cf_ingress_body` fact (before the `http_status:404` fallback):
   ```yaml
   ingress:
     - hostname: myapp.furchert.ch
       service: http://myapp.apps.svc.cluster.local:8080
     - hostname: existing1.furchert.ch
       service: http://existing1.svc:port
     - hostname: existing2.furchert.ch
       service: http://existing2.svc:port
     - service: http_status:404  # MUST be last
   ```

2. **Re-apply the platform playbook**:
   ```bash
   ansible-playbook infra/playbooks/40_platform.yml
   ```

3. **Create DNS CNAME** (if new subdomain) in Cloudflare Dashboard:
   - Type: `CNAME`
   - Name: `myapp` (or `@` for root domain)
   - Target: `<tunnel-id>.cfargotunnel.com` (get from `cloudflare_tunnel_id` in SOPS)
   - Proxy: **enabled**

4. **Verify** the pod restarts and shows the new hostname in logs:
   ```bash
   kubectl -n platform logs -l app=cloudflared-cloudflare-tunnel-remote | tail -20
   kubectl -n platform get pods -w
   ```

### Contract Rules

1. **The ingress list is replaced, not merged** — always include ALL existing entries
2. **`http_status:404` MUST be the final entry** in the list
3. **TLS is terminated at Cloudflare edge** — no cert-manager Certificates needed for Cloudflare-routed hostnames
4. **No Kubernetes Ingress resources** are required for Cloudflare Tunnel exposure
5. **Changes require playbook re-run** — cloudflared reads config only at startup

---

## 4) Internal Service Interface (Cluster DNS)

All services are discoverable via Kubernetes internal DNS.

### Shared Infrastructure (`apps` namespace)

| Service | FQDN | Port | Metrics Port | Authentication | Notes |
|---------|------|------|---------------|----------------|-------|
| PostgreSQL 17 | `postgresql.apps.svc.cluster.local` | 5432 | 9187 | SOPS: `postgresql_password` | Single replica; metrics via postgres-exporter sidecar |
| InfluxDB 2 | `influxdb2.apps.svc.cluster.local` | 8086 | 80 | SOPS: `influxdb_admin_token` | Org: `homelab`, Bucket: `default`, 30d retention |
| Mosquitto 2 | `mosquitto.apps.svc.cluster.local` | 1883 | - | Anonymous | LAN-only MQTT; also exposed via LoadBalancer on 1883 |
| mosquitto-metrics | `mosquitto-metrics.apps.svc.cluster.local` | - | 9234 | - | Prometheus exporter for Mosquitto |
| LiteLLM | `litellm.apps.svc.cluster.local` | 4000 | - | Bearer `LITELLM_MASTER_KEY` | OpenAI-compatible AI gateway |
| n8n | `n8n.apps.svc.cluster.local` | 80 | - | OIDC via auth-service | Workflow automation platform (container: 5678) |

### Flux-Managed Services (`apps` namespace)

| Service | FQDN | Port | Contract |
|---------|------|------|----------|
| auth-service | `auth-service.apps.svc.cluster.local` | 8080 | JWT auth, OIDC provider |
| device-service | `device-service.apps.svc.cluster.local` | 8081 | IoT device management |

### Platform Services

| Service | FQDN | Port | Namespace |
|---------|------|------|----------|
| Traefik metrics | `traefik.kube-system.svc.cluster.local` | 9101 | `kube-system` |
| cert-manager | `cert-manager.platform.svc.cluster.local` | 9402 | `platform` |
| cloudflared | `cloudflared-cloudflare-tunnel-remote.platform.svc.cluster.local` | - | `platform` |

---

## 5) API and Authentication Interfaces

### LiteLLM Gateway (Public: `https://ai.furchert.ch`, Internal: `http://litellm.apps.svc.cluster.local:4000`)

**Authentication**: Bearer token via `Authorization: Bearer <LITELLM_MASTER_KEY>`

**Verified Endpoints** (source: `cluster/apps/litellm/deployment.yaml`, `scripts/smoke-test-litellm.sh`):

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health/liveliness` | Liveness probe (120s initial delay) |
| GET | `/health/readiness` | Readiness probe (120s initial delay) |
| GET | `/models` | List available model routes |
| POST | `/v1/chat/completions` | OpenAI-compatible chat completions |
| GET | `/ui` | Web dashboard |

**Available Model Routes** (Mistral-only, Anthropic disabled):
- `mistral-large` → `mistral-large-latest`
- `mistral-small` → `mistral-small-latest`
- `devstral` → `devstral-latest`
- `magistral` → `magistral-latest`
- `codestral` → `codestral-latest` (uses dedicated `MISTRAL_CODESTRAL_API_KEY`)

**OIDC Integration**: LiteLLM UI and API use auth-service for SSO login:
- Discovery: `https://auth.furchert.ch/.well-known/openid-configuration`
- Client ID: `litellm`
- Client Secret: `LITELLM_OIDC_CLIENT_SECRET` (from `litellm-secrets`)
- PKCE: Required (`GENERIC_CLIENT_USE_PKCE: true`)
- Callback: `https://ai.furchert.ch/sso/callback` (via `PROXY_BASE_URL`)

### Auth Service (Public: `https://auth.furchert.ch`, Internal: `http://auth-service.apps.svc.cluster.local:8080`)

**OIDC/OAuth2 Provider Endpoints**:

| URL | Purpose |
|-----|---------|
| `https://auth.furchert.ch/.well-known/openid-configuration` | OIDC discovery document |
| `https://auth.furchert.ch/oauth2/authorize` | Authorization endpoint |
| `https://auth.furchert.ch/oauth2/token` | Token endpoint |
| `https://auth.furchert.ch/userinfo` | UserInfo endpoint |

**Registered OIDC Clients** (from `59_app_services.yml`):
- `n8n` — for n8n SSO
- `litellm` — for LiteLLM UI SSO
- `grafana` — for Grafana SSO
- `homeassistant` — for Home Assistant SSO
- `device-service` — for device-service authentication

> **Full API contract**: See [homelab-auth-service repository](https://github.com/doemefu/homelab-auth-service)

### Device Service (Public: `https://device.furchert.ch`, Internal: `http://device-service.apps.svc.cluster.local:8081`)

Real-time IoT device management service.
- MQTT integration with Mosquitto
- InfluxDB writer for time-series data
- WebSocket for real-time communication
- Scheduling capabilities

> **Full API contract**: See [homelab-device-service repository](https://github.com/doemefu/homelab-device-service)

---

## 6) Ownership and Reconciliation Interface

### Flux-Managed Applications

**Applications**: `auth-service`, `device-service`

**Reconciliation Flow**:
1. App repository contains `k8s/` directory with Kubernetes manifests
2. Manifest includes `$imagepolicy` marker comment on the container image field
3. Flux ImageRepository polls GHCR for new tags matching `^main-[0-9]{8}T[0-9]{6}$`
4. ImagePolicy filters and selects the appropriate tag
5. ImageUpdateAutomation commits updated tag back to app repo's `k8s/deployment.yaml`
6. Flux Kustomization applies the updated manifests from `k8s/`

**Required Files** in `cluster/apps/<app>/`:
```
cluster/apps/<app>/
  kustomization.yaml      # Lists all CRDs for this app
  source.yaml            # GitRepository pointing to app repo
  sync.yaml               # Kustomization applying k8s/ manifests
  imagerepo.yaml          # ImageRepository for GHCR scanning
  imagepolicy.yaml        # ImagePolicy for tag filtering (alphabetical: asc)
  imageupdate.yaml        # ImageUpdateAutomation for write-back
```

**App Repository Requirements**:
1. `k8s/` directory with all manifest files
2. `k8s/kustomization.yaml` listing all manifest files
3. deployment image field includes marker: `image: ghcr.io/...:main-<timestamp> # {"$imagepolicy": "flux-system:<app>"}`
4. SSH deploy key with write access to app repo (Secret in `flux-system` namespace)

**Contract**: Do NOT manually `kubectl apply` Flux-managed resources. Flux will overwrite changes.

### Ansible-Managed Applications

**Applications**: `n8n`, `litellm`, `homeassistant`

**Ownership Guardrails** (enforced via CLAUDE.md and CONTRIBUTING.md):
- Do NOT add `n8n` or `litellm` to `cluster/apps/kustomization.yaml`
- Do NOT add `n8n` or `litellm` Flux reconciliation objects
- n8n and LiteLLM resources are applied via dedicated playbooks:
  - n8n: `infra/playbooks/52_n8n.yml` + `59_app_services.yml`
  - LiteLLM: `infra/playbooks/53_litellm.yml` + `59_app_services.yml`
  - Home Assistant: `infra/playbooks/51_homeassistant.yml`
- App secrets are provisioned via `infra/playbooks/59_app_services.yml` from SOPS variables

### Shared App Infrastructure

PostgreSQL, InfluxDB, and Mosquitto are **platform-managed** shared services in the `apps` namespace. They are:
- Deployed via `infra/playbooks/50_apps_infra.yml`
- NOT Flux-managed
- Available for all apps to consume via cluster DNS

---

## 7) Secrets Interface

### Source of Truth

All secrets originate in **SOPS-encrypted YAML**:
- File: `infra/inventory/group_vars/all.sops.yml`
- Encryption: SOPS + age (key at `~/.config/age/homelab.key`, NOT in repo)
- Template: `infra/inventory/group_vars/all.sops.yml.example` (with CHANGE_ME placeholders)

### Materialization Pattern

Secrets are materialized into Kubernetes Secrets via Ansible `kubernetes.core.k8s` tasks (never via plaintext in Helm values or manifests).

**Example Secret Creation** (from `59_app_services.yml`):
```yaml
- name: LiteLLM Secrets anlegen
  kubernetes.core.k8s:
    kubeconfig: "{{ kubeconfig }}"
    definition:
      apiVersion: v1
      kind: Secret
      metadata:
        name: litellm-secrets
        namespace: apps
      stringData:
        LITELLM_MASTER_KEY: "{{ litellm_master_key }}"
        LITELLM_SALT_KEY: "{{ litellm_salt_key }}"
        DATABASE_URL: "{{ litellm_db_url }}"
        MISTRAL_API_KEY: "{{ mistral_api_key }}"
  delegate_to: localhost
  no_log: true
```

### Notable Secret Contracts

| Secret | Namespace | Contains | Used By | Rotation Notes |
|--------|-----------|---------|---------|-----------------|
| `homelab-auth-secrets` | `apps` | OIDC client secrets (n8n, litellm, grafana, ha, device-service) | auth-service, n8n, LiteLLM | Some keys require `{noop}` prefix (auth-service convention) |
| `n8n-secrets` | `apps` | n8n encryption key | n8n | Rotate via `59_app_services.yml`, restart n8n deployment |
| `litellm-secrets` | `apps` | LiteLLM master key, salt key, DB password, Mistral API keys | LiteLLM | **`litellm_salt_key` MUST NEVER rotate** — invalidates all virtual keys in DB |
| `postgresql-secret` | `apps` | PostgreSQL admin password | PostgreSQL, connecting apps | Set in `50_apps_infra.yml` |
| `influxdb2-secret` | `apps` | InfluxDB admin password, token | InfluxDB, connecting apps | Set in `50_apps_infra.yml` |
| `cloudflare-api-token` | `platform` | Cloudflare API token | cert-manager DNS-01 challenges | Set in `40_platform.yml` |

### Required SOPS Variables

**Always Encrypted** (assert guards in playbooks fail without these):

From `59_app_services.yml` (app secrets):
- `homelab_db_username`, `homelab_db_password`
- `device_service_mqtt_password`
- `influxdb_admin_token`
- `auth_service_grafana_client_secret`, `auth_service_ha_client_secret`
- `auth_service_device_service_client_secret`, `auth_service_n8n_client_secret`
- `n8n_encryption_key` (generate with `openssl rand -hex 32`)
- `auth_service_rsa_private_key`, `auth_service_rsa_public_key`
- `litellm_master_key` (starts with `sk-`)
- `litellm_salt_key` (**PERMANENT — never rotate**)
- `litellm_db_password`
- `mistral_api_key`, `mistral_codestral_api_key`
- `litellm_client_secret`

From `50_apps_infra.yml` (shared infrastructure):
- `postgresql_password`
- `influxdb_admin_password`, `influxdb_admin_token`
- `sentry_dsn`

From `41_monitoring.yml` (observability):
- `grafana_admin_password`
- `alertmanager_discord_webhook_url`

From `40_platform.yml` (platform):
- `cloudflare_api_token`, `cloudflared_tunnel_token`
- `cloudflare_account_id`, `cloudflare_tunnel_id`, `cloudflare_tunnel_api_token`

---

## 8) Storage Interface

### Default StorageClass: Longhorn

- **Provider**: Longhorn v1.7.2
- **Replication Factor**: 2 (replicated across 2 nodes)
- **Default**: Yes — PVCs without `storageClassName` use Longhorn automatically
- **Access Modes**: ReadWriteOnce (RWO), ReadWriteMany (RWX via RWX storage class)
- **Survives**: Node failures, k3s restarts

**Source of Truth**: `infra/playbooks/30_longhorn.yml`, `cluster/values/longhorn.yaml`

### Fallback: local-path

- **Default**: No — must be explicitly specified
- **Use Case**: Node-local, ephemeral storage
- **Does NOT**: Replicate or survive node failures

```yaml
# To use local-path explicitly:
storageClassName: local-path
```

### Usage Examples

**Longhorn PVC (default)**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
  namespace: apps
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  # storageClassName: longhorn (optional - it's default)
```

**Local-path PVC**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-scratch
  namespace: apps
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
```

### Replication Notes

With 4 nodes (raspi5, raspi4, mba1, mba2) and RF=2:
- Each Longhorn volume has 2 replicas on different nodes
- If 1 node goes offline, volumes degrade to RF=1 (still functional)
- Longhorn automatically rebuilds replicas when the node rejoins

> **Check volume health**: `kubectl get volumes -n longhorn-system` or use Longhorn UI (port-forward `svc/longhorn-frontend:80`)

---

## 9) Observability Interface

### For Apps Exposing Metrics

To integrate your app with Prometheus monitoring:

1. **Expose a metrics port** on your Service:
   ```yaml
   spec:
     ports:
       - name: metrics  # Named port required
         port: 9090
         targetPort: 9090
   ```

2. **Create a ServiceMonitor** in the `monitoring` namespace with label `release: kube-prometheus-stack`:
   ```yaml
   apiVersion: monitoring.coreos.com/v1
   kind: ServiceMonitor
   metadata:
     name: myapp
     namespace: monitoring
     labels:
       release: kube-prometheus-stack  # REQUIRED for discovery
   spec:
     namespaceSelector:
       matchNames:
         - apps  # Where your Service lives
     selector:
       matchLabels:
         app: myapp  # Must match your Service labels
     endpoints:
       - port: metrics  # Must match your Service port name
         path: /metrics
         interval: 30s
   ```

3. **Verify** in Prometheus:
   ```bash
   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
   # Open: http://localhost:9090/targets
   # Look for: serviceMonitor/monitoring/myapp → state UP
   ```

**Reference Implementation**: See `infra/playbooks/50_apps_infra.yml` for postgres-exporter, mosquitto-exporter ServiceMonitors.

### Pre-Installed Exporters

| Exporter | Service | Port | Namespace | Source |
|----------|---------|------|----------|--------|
| node-exporter | Node metrics | 9100 | `monitoring` | kube-prometheus-stack subchart |
| postgres-exporter | PostgreSQL metrics | 9187 | `apps` | Sidecar in `50_apps_infra.yml` |
| mosquitto-exporter | MQTT broker metrics | 9234 | `apps` | Separate Deployment in `50_apps_infra.yml` |

---

## 10) Network Interface

### Firewall Rules (UFW)

All incoming connections are **denied by default**. Only LAN-originating traffic is allowed on specific ports.

**Managed by**: `infra/roles/hardening/` role, applied by `10_base.yml`

| Port(s) | Protocol | Purpose | Scope | Service |
|---------|----------|---------|-------|---------|
| 22 | TCP | SSH | LAN only | Node access |
| 80, 443 | TCP | HTTP/HTTPS | LAN only | Traefik Ingress |
| 6443 | TCP | k3s API Server | LAN only | Kubernetes API |
| 10250 | TCP | kubelet metrics | LAN only | Monitoring |
| 8472 | UDP | Flannel VXLAN | LAN only | CNI overlay |
| 2379-2380 | TCP | etcd | LAN only | Control-Plane only |
| 9100 | TCP | Node Exporter | LAN only | Prometheus scraping |
| 9500-9502 | TCP | Longhorn | LAN only | Storage replication |
| 1883 | TCP | Mosquitto MQTT | LAN only | MQTT broker (LoadBalancer) |

**Internal Cluster Ports** (no UFW entry needed — reachable via CNI):
- 9101 (Traefik metrics)
- 9187 (postgres-exporter)
- 9234 (mosquitto-exporter)

### Port Access Patterns

**From LAN** → Direct access via node IP + port (if UFW allows)
**From internet** → Only via Cloudflare Tunnel (no direct IP exposure)
**From cluster** → Via Kubernetes DNS `<service>.<namespace>.svc.cluster.local:<port>`

---

## 11) Multi-Architecture Interface

### Cluster Node Architecture

| Architecture | Nodes | Role |
|--------------|-------|------|
| `linux/arm64` | raspi5, raspi4 | Control-plane + Workers |
| `linux/amd64` | mba1, mba2 | Workers |

### Image Requirements

**All container images MUST support both architectures** (`linux/arm64` and `linux/amd64`).

**Verify multi-arch support**:
```bash
docker buildx imagetools inspect <image>:<tag> | grep Platform
```

Expected output includes both:
```
Platform: linux/amd64
Platform: linux/arm64
```

**Official Docker Hub images** (postgres, nginx, redis, etc.) are typically multi-arch.
Third-party or custom images must be checked.

### Architecture-Specific Deployments

If your image only supports one architecture, constrain scheduling with `nodeSelector`:

```yaml
nodeSelector:
  kubernetes.io/arch: arm64  # or amd64
```

Or use node affinity:
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/arch
          operator: In
          values:
            - arm64
```

---

## 12) Resource Interface

### Resource Limits Requirement

**Resource limits are REQUIRED for all workloads in the `apps` namespace** (CLAUDE.md non-negotiable, enforced via Ansible lint rules).

### Baseline Resource Template

For ARM64 Pi hardware (raspi5: 8GB, raspi4: 4GB):

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

For larger workloads (MBA nodes have ~8GB):
```yaml
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi
```

**Verify resource usage**:
```bash
kubectl top pods -n apps
kubectl describe nodes | grep -A 5 Allocatable
```

---

## Interface-to-Documentation Mapping

| Need | File |
|------|------|
| Deploy your app on this platform | **[APP-DEPLOYMENT.md](APP-DEPLOYMENT.md)** |
| Deploy/operate the cluster itself | **[DEPLOYMENT.md](DEPLOYMENT.md)** |
| Contribute to this repo | **[DEVELOPMENT.md](DEVELOPMENT.md)** |
| General platform overview | **[OVERVIEW.md](OVERVIEW.md)** |
