# APPS.md — App Deployment Guide

---

## Namespace Conventions

| Namespace        | Purpose                                                      | Notes                                      |
|------------------|--------------------------------------------------------------|--------------------------------------------|
| `platform`       | Cluster infrastructure (cert-manager, cloudflared, Traefik) | No app workloads                           |
| `longhorn-system`| Longhorn storage (Helm-Chart-Konvention)                    | No app workloads                           |
| `monitoring`     | Prometheus, Grafana, Alertmanager                           | No app workloads. ServiceMonitors for all namespaces (including `apps`) live here. |
| `apps`           | All application workloads + shared platform services (PostgreSQL 17, InfluxDB 2, Mosquitto 2) | Resource limits required; no cluster-admin ServiceAccounts |
| `homeassistant`  | Home Assistant                                              | hostNetwork; port 8123 on node IP |

Do not create namespaces outside this list without explicit discussion (CLAUDE.md non-negotiable).

Create the `apps` namespace once before your first deployment:

```bash
kubectl create namespace apps
```

---

## Platform App Infrastructure

Die folgenden Shared Services laufen im `apps` Namespace und können von App-Deployments cluster-intern genutzt werden.

| Service       | Interner FQDN                               | Port | Metrics Endpoint | Hinweise |
|---------------|---------------------------------------------|------|------------------|----------|
| PostgreSQL 17 | `postgresql.apps.svc.cluster.local`         | 5432 | `:9187/metrics` (postgres-exporter sidecar) | Single Replica; Passwort aus SOPS `postgresql_password` |
| InfluxDB 2    | `influxdb2.apps.svc.cluster.local`          | 8086 | `:80/metrics` (native) | Org `homelab`, Bucket `default`, 30d Retention; Token aus SOPS `influxdb_admin_token` |
| Mosquitto 2   | `mosquitto.apps.svc.cluster.local`          | 1883 | `mosquitto-metrics.apps:9234/metrics` (exporter) | Auch LAN-seitig via LoadBalancer Port 1883; anonym in M6 |
| LiteLLM       | `litellm.apps.svc.cluster.local`            | 4000 | — | OpenAI-compatible AI proxy; Auth: `Authorization: Bearer <LITELLM_MASTER_KEY>`; extern: `https://ai.furchert.ch` |

**Wichtig:** Mosquitto ist in M6 ohne Authentifizierung — nur LAN-seitiger Zugriff. Nicht extern exponieren ohne `password_file` (Post-M6).

---

## Cloudflare Tunnel Ingress Pattern

Services in `apps` are exposed externally by adding an entry to the cloudflared ingress list in
`infra/playbooks/40_platform.yml`. No Kubernetes Ingress resource or TLS certificate is required —
TLS is terminated at the Cloudflare edge.

Cross-namespace access uses the cluster-internal FQDN:

```
http://<service-name>.<namespace>.svc.cluster.local:<port>
```

Example (app in `apps` namespace, port 8080):

```yaml
- hostname: myapp.furchert.ch
  service: http://myapp.apps.svc.cluster.local:8080
```

Add this entry to the ingress list in `infra/playbooks/40_platform.yml` (before the `http_status:404` fallback), then re-run the platform playbook — the playbook automatically restarts the cloudflared Pod via a rolling annotation update:

```bash
ansible-playbook infra/playbooks/40_platform.yml
```

> **Hinweis:** The cloudflared ingress PUT replaces the full list — always include all existing
> entries (SSH, Grafana, 404 fallback). The 404 fallback must be last.

For Traefik-based access (requires DNS pointing to the cluster's Traefik LoadBalancer IP and
a cert-manager certificate), see `examples/simple-deployment.yml`.

---

## StorageClass

Longhorn is the default StorageClass (RF=2, replicated across nodes). PVCs that do not specify
`storageClassName` use Longhorn automatically.

For scratch / non-replicated storage use `local-path` explicitly:

```yaml
storageClassName: local-path
```

> Longhorn volumes are accessible from any node and survive node failures. Use Longhorn for
> databases and stateful workloads. Use `local-path` only for ephemeral or node-local storage.

> **Note on Replication Factor:** With 2 active nodes (raspi5 + raspi4), RF=2 means one replica
> per node. If raspi4 goes offline, a RF=2 volume degrades to RF=1 until it comes back. This is
> expected and Longhorn will automatically rebuild when the node rejoins.

---

## Resource Limits

Resource limits are required for all workloads in the `apps` namespace (CLAUDE.md non-negotiable).

Baseline template for ARM64 Pi hardware:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

Adjust based on actual workload. Check `kubectl top pods -n apps` after deploy.

---

## Multi-Architecture Requirements

The cluster currently runs four Ready nodes: ARM64 `raspi5` (8 GB) and `raspi4` (4 GB), plus AMD64 `mba1` (8 CPU, ~8 Gi RAM) and `mba2` (4 CPU, ~8 Gi RAM).
**All container images must support both architectures** (`linux/arm64` and `linux/amd64`).

Check whether an image is multi-arch before using it:

```bash
docker buildx imagetools inspect <image>:<tag> | grep Platform
```

Expected output should include both:
```
Platform: linux/amd64
Platform: linux/arm64
```

Official images from Docker Hub (e.g., `postgres`, `nginx`, `redis`) are multi-arch.
Third-party or self-built images may not be — check before deploying.

If your app image only supports one architecture, add a `nodeSelector` to constrain scheduling:

```yaml
nodeSelector:
  kubernetes.io/arch: arm64
```

---

## Secrets for Apps

All secrets must be encrypted via SOPS before committing (CLAUDE.md non-negotiable).

### Adding an app secret

1. Open the secrets file for editing:
   ```bash
   sops infra/inventory/group_vars/all.sops.yml
   ```
2. Add your key:
   ```yaml
   myapp_db_password: "your-secret-value"
   ```
3. Save and close (SOPS re-encrypts automatically).

### Using the secret in a playbook

Inject via a `kubernetes.core.k8s` task (avoid writing secrets to values files):

```yaml
- name: myapp Secret anlegen
  kubernetes.core.k8s:
    kubeconfig: "{{ kubeconfig }}"
    definition:
      apiVersion: v1
      kind: Secret
      metadata:
        name: myapp-secret
        namespace: apps
      stringData:
        db-password: "{{ myapp_db_password }}"
  delegate_to: localhost
  no_log: true
```

Then reference in your Deployment:

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: myapp-secret
        key: db-password
```

> **Never** put secret values directly in `cluster/values/*.yaml` or `examples/` files.

---

## Prometheus Observability for Apps

To wire a new app into Prometheus, create a ServiceMonitor in the `monitoring` namespace. The ServiceMonitor must carry label `release: kube-prometheus-stack` for the Prometheus Operator to discover it.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - apps
  selector:
    matchLabels:
      app: myapp
  endpoints:
    - port: metrics      # named port on the Service pointing at the exporter / native /metrics
      path: /metrics
      interval: 30s
```

The targeted Service must expose a named port `metrics`. If the app has no native `/metrics` endpoint, add a sidecar exporter container (see `infra/playbooks/50_apps_infra.yml` postgres-exporter sidecar for an example) or a separate exporter Deployment.

Verify targets are UP in Prometheus:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# → http://localhost:9090/targets
```

---

## Reference Manifests

Working examples are in `examples/`. Copy and adapt for your app.

| File | What it shows |
|------|---------------|
| [`examples/simple-deployment.yml`](examples/simple-deployment.yml) | Deployment + Service + Traefik IngressRoute with cert-manager TLS (letsencrypt-prod; requires DNS to Traefik IP) |
| [`examples/with-postgres.yml`](examples/with-postgres.yml) | App + Postgres + Longhorn PVC + Secret |
| [`examples/with-ingress-public.yml`](examples/with-ingress-public.yml) | Public exposure via Cloudflare Tunnel (no IngressRoute) |
| [`examples/helm-values-template.yml`](examples/helm-values-template.yml) | Starting point for custom Helm chart values |

All examples use:
- Namespace `apps`
- Multi-arch images
- Resource limits per the baseline above
- No hardcoded secrets (comments show where SOPS-backed values belong)

---

## Deploying Your App

### Prerequisites

Ensure `kubectl` is configured to talk to the homelab cluster:

```bash
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes  # should show raspi5, raspi4, mba1, mba2 as Ready
```

> Add `export KUBECONFIG=~/.kube/homelab.yaml` to your `~/.zshrc` to make it permanent.

### Create the namespace (once)

```bash
kubectl create namespace apps
```

### Flux-managed apps (device-service, auth-service)

`device-service` and `auth-service` are managed by **Flux CD**. Do not `kubectl apply` their manifests manually — Flux will overwrite any manual change within the next reconciliation interval (≤10 min).

**Prerequisites (one-time bootstrap):**

1. Apply the apps Kustomization to the cluster (not auto-reconciled by the flux-system bootstrap):
   ```bash
   kubectl apply -f cluster/flux-system/apps-sync.yaml
   ```

2. Create the SSH deploy key Secret for each service in the `flux-system` namespace. The key must have **write access** to the app repo (ImageUpdateAutomation pushes tag commits back to `main`). Add the private key, public key, and known_hosts to your SOPS-encrypted vars and create the Secret via an Ansible task (same pattern as other Secrets in `50_apps_infra.yml`):
   ```bash
   # Secret name expected by source.yaml:
    # auth-service:   auth-service-flux-auth
    # device-service: device-service-flux-auth
   # Fields: identity (SSH private key), identity.pub, known_hosts
   ```

**Deploying a new version:**  
- `auth-service` / `device-service`: Push to `main` in the app repo. CI builds a `main-YYYYMMDDTHHmmss` image tag, Flux Image Automation updates the app repo, then Flux applies the rollout.  

### Ansible-managed app: n8n

n8n is managed via Ansible playbooks, not Flux reconciliation.

```bash
ansible-playbook infra/playbooks/52_n8n.yml
ansible-playbook infra/playbooks/59_app_services.yml
```

For secret rotation or updates, re-run:

```bash
ansible-playbook infra/playbooks/59_app_services.yml
```

Do not expect Flux reconcile to create or update n8n resources.

### Ansible-managed app: LiteLLM

LiteLLM is managed via Ansible playbooks, not Flux reconciliation. Secrets must be bootstrapped before manifests are applied.
Current active routes are Mistral-only (`mistral-large`, `mistral-small`, `devstral`, `magistral`, `codestral`) using latest provider aliases. Anthropic routes are intentionally disabled.

```bash
ansible-playbook infra/playbooks/59_app_services.yml   # DB init + Secret
ansible-playbook infra/playbooks/53_litellm.yml        # deploy manifests
ansible-playbook infra/playbooks/40_platform.yml       # CF Tunnel ingress (ai.furchert.ch)
```

Do not add `litellm` to `cluster/apps/kustomization.yaml` — Flux must not reconcile it.

**Checking status:**
```bash
flux get kustomizations -n flux-system          # reconciliation state
flux get image update -n flux-system            # last automation commit
kubectl rollout status deployment/<app> -n apps # pod rollout
```

**Suspending automation** (e.g. for emergency pin):
```bash
flux suspend image update <app> -n flux-system
# fix the image tag manually if needed, then:
flux resume image update <app> -n flux-system
```

**Forcing a reconciliation:**
```bash
flux reconcile kustomization <app> -n flux-system --with-source
```

### kubectl apply workflow (non-Flux apps)

For apps not managed by Flux, use the standard apply workflow:

1. **Apply your manifest:**
   ```bash
   kubectl apply -f your-app.yml
   ```

2. **Wait for rollout:**
   ```bash
   kubectl rollout status deployment/<your-app> -n apps
   ```

3. **Verify pods are Running:**
   ```bash
   kubectl get pods -n apps
   ```

See `examples/simple-deployment.yml` for a complete manifest to start from.

### Helm workflow

If your app uses a Helm chart, store your values in `cluster/values/<your-app>.yaml` and always pin the chart version.

1. **Add the chart repo (once):**
   ```bash
   helm repo add <repo-name> <repo-url>
   helm repo update
   ```

2. **Install or upgrade (same command for both):**
   ```bash
   helm upgrade --install <release-name> <repo>/<chart> \
     --namespace apps --create-namespace \
     -f cluster/values/<your-app>.yaml \
     --version <pinned-version>
   ```

3. **Verify:**
   ```bash
   helm list -n apps
   kubectl get pods -n apps
   ```

See `examples/helm-values-template.yml` as a starting point for your values file.

### Updating a running app

**Manifest-based** — edit your manifest, then re-apply:
```bash
kubectl apply -f your-app.yml
kubectl rollout status deployment/<your-app> -n apps
```

**Helm-based** — bump the version in your values file, then upgrade:
```bash
helm upgrade <release-name> <repo>/<chart> \
  --namespace apps \
  -f cluster/values/<your-app>.yaml \
  --version <new-version>
```

### Rollback

**Manifest-based:**
```bash
kubectl rollout undo deployment/<your-app> -n apps
```

**Helm-based:**
```bash
helm history <release-name> -n apps        # list revisions
helm rollback <release-name> <revision> -n apps
```

---

## Post-Deploy Verification

After deploying, verify:

```bash
# Pods are Running, not CrashLoopBackOff or Pending
kubectl get pods -n apps

# PVCs are Bound (if using Longhorn storage)
kubectl get pvc -n apps

# Resource usage is within limits
kubectl top pods -n apps

# Endpoint responds (for cluster-internal IngressRoute)
kubectl port-forward -n apps svc/<service-name> 8080:80
curl -s http://localhost:8080  # or the expected health path
```

For publicly exposed apps (Cloudflare Tunnel), verify the DNS entry is set and the tunnel shows the hostname as healthy:

```bash
# Check cloudflared pod is running with the updated ingress
kubectl logs -n platform deployment/cloudflared-cloudflare-tunnel-remote | tail -20
```

---

## App Troubleshooting

### CrashLoopBackOff
```bash
kubectl logs -n apps <pod-name> --previous
kubectl describe pod -n apps <pod-name>
```
Common causes: missing environment variables, wrong image, insufficient memory (OOMKilled).

### Pod stuck in Pending
```bash
kubectl describe pod -n apps <pod-name>
# Look for: Insufficient cpu/memory, No nodes matched NodeSelector
```
Common causes: resource requests exceed available capacity, or node affinity mismatch.

Check node capacity:
```bash
kubectl describe node raspi5 | grep -A 5 "Allocatable:"
kubectl describe node raspi4 | grep -A 5 "Allocatable:"
```

### PVC stuck in Pending
```bash
kubectl describe pvc -n apps <pvc-name>
```
Common causes: Longhorn not healthy, wrong storageClass name.

Check Longhorn status:
```bash
kubectl get pods -n longhorn-system
# Access Longhorn UI:
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Open: http://localhost:8080
```

### ImagePullBackOff
```bash
kubectl describe pod -n apps <pod-name> | grep -A 5 "Events:"
```
Common causes: image name typo, private registry without imagePullSecret, image not available for arm64.

### Service not reachable via Cloudflare Tunnel
1. Verify the hostname entry is in the ingress list in `40_platform.yml`
2. Re-run: `ansible-playbook infra/playbooks/40_platform.yml`
3. Check cloudflared pod restarted and shows the hostname in logs
4. Verify DNS CNAME: `<hostname> → <tunnel-id>.cfargotunnel.com` (Proxy: enabled) in Cloudflare Dashboard
