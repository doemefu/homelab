# App Deployment Guide — Deploying Applications on the Homelab Platform

This document is a **hand-off guide for developers** who want to deploy their applications **ON** this infrastructure platform. It explains namespace conventions, available shared services, deployment workflows, and troubleshooting.

> **For deploying/operating the cluster itself**: See [DEPLOYMENT.md](DEPLOYMENT.md)
> **For platform interfaces and contracts**: See [INTERFACES.md](INTERFACES.md)

---

## 1) Namespace Conventions

| Namespace | Purpose | Notes |
|-----------|---------|-------|
| `platform` | Cluster infrastructure (cert-manager, cloudflared, Traefik) | **No app workloads** |
| `longhorn-system` | Longhorn storage system | Helm chart convention, no app workloads |
| `monitoring` | Prometheus, Grafana, Alertmanager | ServiceMonitors for all namespaces live here |
| `apps` | **Application workloads + shared app infrastructure** | Resource limits **required**; no cluster-admin ServiceAccounts |
| `homeassistant` | Home Assistant | Dedicated namespace; hostNetwork; no public Cloudflare route by default |
| `flux-system` | Flux CD controllers | **No application workloads** |

> **Do not create namespaces outside this list** without explicit discussion.

**Create the `apps` namespace once before your first deployment**:
```bash
kubectl create namespace apps
```

---

## 2) Platform App Infrastructure

The following **shared services** run in the `apps` namespace and are available for your app deployments to consume via Kubernetes internal DNS.

| Service | Internal FQDN | Port | Metrics Endpoint | Authentication | Notes |
|---------|---------------|------|-----------------|----------------|-------|
| PostgreSQL 17 | `postgresql.apps.svc.cluster.local` | 5432 | `:9187/metrics` (sidecar) | Signle replica | Password from SOPS `postgresql_password` |
| InfluxDB 2 | `influxdb2.apps.svc.cluster.local` | 8086 | `:80/metrics` (native) | Token-based | Org: `homelab`, Bucket: `default`, 30d retention |
| Mosquitto 2 | `mosquitto.apps.svc.cluster.local` | 1883 | - | **Anonymous** (LAN-only) | Also exposed via LoadBalancer on port 1883 |
| mosquitto-metrics | `mosquitto-metrics.apps.svc.cluster.local` | - | `:9234/metrics` | - | Prometheus exporter for Mosquitto |

> **Important**: Mosquitto is currently configured without authentication (`allow_anonymous true`) and is LAN-oriented. Do **not** expose it externally without `password_file` configuration.

---

## 3) Public Exposure via Cloudflare Tunnel

Services in the `apps` namespace are exposed externally by adding an entry to the Cloudflare Tunnel ingress list in `infra/playbooks/40_platform.yml`. No Kubernetes Ingress resource or TLS certificate is required — TLS is terminated at the Cloudflare edge.

### How to Expose Your App

1. **Add ingress entry** to `infra/playbooks/40_platform.yml` in the `cf_ingress_body` fact (before the `http_status:404` fallback):

   ```yaml
   ingress:
     - hostname: myapp.furchert.ch
       service: http://myapp.apps.svc.cluster.local:8080
     # ... keep all existing entries ...
     - service: http_status:404  # MUST be last
   ```

2. **Re-apply the platform playbook** (this restarts cloudflared with the new config):
   ```bash
   ansible-playbook infra/playbooks/40_platform.yml
   ```

3. **Create DNS CNAME** in Cloudflare Dashboard for your subdomain:
   - Type: `CNAME`
   - Name: `myapp`
   - Target: `<tunnel-id>.cfargotunnel.com` (get tunnel ID from your SOPS file)
   - Proxy: **enabled**

> **Critical rules**:
> - The ingress list is **replaced, not merged** — always include ALL existing entries
> - `http_status:404` MUST be the **final entry**
> - Cross-namespace access uses the internal FQDN: `http://<service-name>.<namespace>.svc.cluster.local:<port>`

### Example: Full Ingress List Addition

```yaml
# In infra/playbooks/40_platform.yml, the cf_ingress_body fact:
config:
  ingress:
    # Existing entries (DO NOT REMOVE):
    - hostname: "ssh.furchert.ch"
      service: "ssh://192.168.1.61:22"
    - hostname: "grafana.furchert.ch"
      service: "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80"
    - hostname: "auth.furchert.ch"
      service: "http://auth-service.apps.svc.cluster.local:8080"
    - hostname: "device.furchert.ch"
      service: "http://device-service.apps.svc.cluster.local:8081"
    - hostname: "n8n.furchert.ch"
      service: "http://n8n.apps.svc.cluster.local:80"
    - hostname: "ai.furchert.ch"
      service: "http://litellm.apps.svc.cluster.local:4000"
    # Your new entry:
    - hostname: "myapp.furchert.ch"
      service: "http://myapp.apps.svc.cluster.local:8080"
    # Fallback (MUST BE LAST):
    - service: "http_status:404"
```

---

## 4) Storage

### Default StorageClass: Longhorn

- **Replication Factor**: 2 (distributed across nodes)
- **Default**: Yes — PVCs without `storageClassName` use Longhorn automatically
- **Survives**: Node failures, k3s restarts
- **Use for**: Databases and stateful workloads that need persistence

### Fallback: local-path

- **Default**: No — must be explicitly specified
- **Use for**: Node-local, ephemeral storage only
- **Does NOT**: Replicate or survive node failures

```yaml
# Explicit local-path usage:
storageClassName: local-path
```

### PVC Examples

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
  # storageClassName: longhorn  # Optional - it's the default
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

### Replication Behavior

With 4 nodes (raspi5, raspi4, mba1, mba2) and RF=2:
- Each Longhorn volume has 2 replicas on different nodes
- If 1 node goes offline, volumes **degrade to RF=1** (still functional)
- Longhorn **automatically rebuilds** replicas when the node rejoins
- If 2 nodes go offline simultaneously, volumes may become **degraded or unavailable**

> **Check volume health**:
> ```bash
> kubectl get volumes -n longhorn-system
> # Or use Longhorn UI:
> kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
> # Open: http://localhost:8080
> ```

---

## 5) Resource Limits

**Resource limits are REQUIRED for all workloads in the `apps` namespace** (non-negotiable).

### Baseline Template for ARM64 Pi Hardware

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

### Adjusted for Larger Workloads

MBA nodes have ~8GB RAM available:

```yaml
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi
```

**Verify resource usage after deploy**:
```bash
kubectl top pods -n apps
```

**Check node capacity**:
```bash
kubectl describe node raspi5 | grep -A 5 Allocatable
kubectl describe node raspi4 | grep -A 5 Allocatable
kubectl describe node mba1 | grep -A 5 Allocatable
kubectl describe node mba2 | grep -A 5 Allocatable
```

---

## 6) Multi-Architecture Support

### Cluster Architecture

| Architecture | Nodes | Role |
|--------------|-------|------|
| `linux/arm64` | raspi5 (8GB), raspi4 (4GB) | Control-plane + Workers |
| `linux/amd64` | mba1 (8GB), mba2 (8GB) | Workers |

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

**Official Docker Hub images** (postgres, nginx, redis, etc.) are typically multi-arch. Third-party or custom images **must be checked**.

### Architecture-Specific Scheduling

If your image **only** supports one architecture, constrain scheduling:

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

## 7) Secrets for Apps

**All secrets must be encrypted via SOPS** before committing. Never put secrets in plaintext in manifests, Helm values, or examples.

### Adding an App Secret

1. Edit the secrets file:
   ```bash
   sops infra/inventory/group_vars/all.sops.yml
   ```

2. Add your secret variable:
   ```yaml
   myapp_db_password: "your-secret-value"
   ```

3. Save and close — SOPS automatically re-encrypts

4. Use the variable in a playbook task (if Ansible-managed):
   ```yaml
   - name: Create myapp Secret
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

5. Reference in your Deployment:
   ```yaml
   env:
     - name: DB_PASSWORD
       valueFrom:
         secretKeyRef:
           name: myapp-secret
           key: db-password
   ```

> **NEVER** put secret values directly in `cluster/values/*.yaml` or `examples/` files.

---

## 8) Secrets Provisioning via Ansible

For most apps, secrets are provisioned via `infra/playbooks/59_app_services.yml`. If you need additional secrets:

1. Add the variable to `infra/inventory/group_vars/all.sops.yml` (encrypted)
2. Add a task to `59_app_services.yml` to create the Kubernetes Secret
3. Re-run: `ansible-playbook infra/playbooks/59_app_services.yml`

This is the **preferred pattern** for platform-managed secrets.

---

## 9) Prometheus Observability for Apps

To wire your app into Prometheus monitoring, create a ServiceMonitor in the `monitoring` namespace.

### Requirements

1. Your app **must** expose a `/metrics` HTTP endpoint
2. Your Service **must** have a named port `metrics`

### ServiceMonitor Example

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

### If Your App Has No Native Metrics

Add a **sidecar exporter** or a **separate exporter Deployment** (see `infra/playbooks/50_apps_infra.yml` for the postgres-exporter sidecar as a reference implementation).

### Verify Prometheus Targets

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open: http://localhost:9090/targets
# Look for: serviceMonitor/monitoring/myapp → state: UP
```

---

## 10) Reference Manifests

Working examples are in `examples/`. Copy and adapt for your app.

| File | What It Shows |
|------|--------------|
| [`examples/simple-deployment.yml`](examples/simple-deployment.yml) | Deployment + Service + Traefik IngressRoute with cert-manager TLS (requires DNS to Traefik IP) |
| [`examples/with-postgres.yml`](examples/with-postgres.yml) | App + PostgreSQL connection + Longhorn PVC |
| [`examples/with-ingress-public.yml`](examples/with-ingress-public.yml) | Public exposure via Cloudflare Tunnel (no IngressRoute) |
| [`examples/helm-values-template.yml`](examples/helm-values-template.yml) | Starting point for Helm chart values |

All examples use:
- Namespace: `apps`
- Multi-arch compatible images
- Resource limits (required)
- No hardcoded secrets (use SOPS-backed variables with comments showing where they belong)

---

## 11) Deployment Workflows

### Option A: kubectl apply (For Simple Apps)

For non-Flux, non-Ansible managed apps:

1. **Ensure `kubectl` is configured**:
   ```bash
   export KUBECONFIG=~/.kube/homelab.yaml
   kubectl get nodes  # Should show 4 Ready nodes
   ```
   
   > Add `export KUBECONFIG=~/.kube/homelab.yaml` to your `~/.zshrc` to make it permanent.

2. **Create your manifest** (see `examples/` for templates)

3. **Apply**:
   ```bash
   kubectl apply -f myapp.yml -n apps
   ```

4. **Wait for rollout**:
   ```bash
   kubectl rollout status deployment/myapp -n apps
   ```

5. **Verify**:
   ```bash
   kubectl get pods -n apps
   ```

### Option B: Helm (For Chart-Based Apps)

1. **Ensure `kubectl` is configured** (see above)

2. **Store your values** in `cluster/values/myapp.yaml` (pinned chart version):
   ```yaml
   # cluster/values/myapp.yaml
   version: "1.2.3"  # Pinned chart version
   image:
     tag: "v1.2.3"  # Pinned image tag
   ```

3. **Install or upgrade**:
   ```bash
   helm upgrade --install myapp <repo>/<chart> \
     --namespace apps --create-namespace \
     -f cluster/values/myapp.yaml \
     --version 1.2.3
   ```

4. **Verify**:
   ```bash
   helm list -n apps
   kubectl get pods -n apps
   ```

### Option C: Flux-Managed (For GitOps Apps)

**Only for apps that need automatic image updates** and have their own Git repository.

**Prerequisites**:
- Your app has its own Git repository with `k8s/` directory
- Your app uses timestamped image tags: `main-YYYYMMDDTHHmmss`
- Your CI pushes tagged images to GHCR

**Setup**:

1. Follow the Flux onboarding procedure in [DEVELOPMENT.md](DEVELOPMENT.md#adding-a-flux-managed-app)
2. **DO NOT** manually `kubectl apply` Flux-managed resources — Flux will overwrite changes

**Verify**:
```bash
flux check
flux get kustomizations -n flux-system
flux get image update -n flux-system
```

---

## 12) Updating Running Apps

### kubectl apply Workflow

1. Edit your manifest
2. Re-apply:
   ```bash
   kubectl apply -f myapp.yml -n apps
   ```
3. Wait for rollout:
   ```bash
   kubectl rollout status deployment/myapp -n apps
   ```

### Helm Workflow

1. Update version in `cluster/values/myapp.yaml`
2. Upgrade:
   ```bash
   helm upgrade myapp <repo>/<chart> \
     --namespace apps \
     -f cluster/values/myapp.yaml \
     --version <new-version>
   ```

### Flux-Managed Workflow

**Do NOT manually update image tags** — Flux Image Automation handles this.

1. Push new code to your app repo's `main` branch
2. CI builds and pushes a new timestamped image
3. Flux detects the new image and commits the updated tag back to your repo
4. Flux applies the updated manifests

**Verify**:
```bash
flux get image update -n flux-system
kubectl get pods -n apps -o wide
```

---

## 13) Rollback

### kubectl apply Workflow

```bash
kubectl rollout undo deployment/myapp -n apps
```

### Helm Workflow

```bash
helm history myapp -n apps        # List revisions
helm rollback myapp <revision> -n apps
```

---

## 14) Post-Deploy Verification

After deploying your app, verify:

```bash
# Pods are Running (not CrashLoopBackOff or Pending)
kubectl get pods -n apps

# If using PVCs - they should be Bound
kubectl get pvc -n apps

# Resource usage is within limits
kubectl top pods -n apps

# For cluster-internal access, test endpoint:
kubectl port-forward -n apps svc/myapp 8080:80
curl -s http://localhost:8080
```

### For Publicly Exposed Apps (Cloudflare Tunnel)

1. Verify DNS CNAME is set and correct
2. Check cloudflared pod logs show your hostname:
   ```bash
   kubectl -n platform logs -l app=cloudflared-cloudflare-tunnel-remote | tail -20
   ```
3. Verify the hostname is in the ingress list:
   ```bash
   kubectl -n platform get cm cloudflared-config -o yaml
   ```

---

## 15) App Troubleshooting

### Pod Stuck in CrashLoopBackOff

```bash
# View previous logs (before the crash)
kubectl logs -n apps <pod-name> --previous

# Describe the pod for events
kubectl describe pod -n apps <pod-name>
```

**Common causes**:
- Missing environment variables
- Wrong image name or tag
- Insufficient memory (OOMKilled)
- Missing secrets or configmaps
- Application errors

### Pod Stuck in Pending

```bash
kubectl describe pod -n apps <pod-name>
```

**Look for** in Events:
- `Insufficient cpu` or `Insufficient memory` → Resource requests exceed available capacity
- `No nodes available that match all constraints` → NodeSelector or affinity mismatch
- `0/4 nodes are available` → Check node conditions with `kubectl describe nodes`

**Check node capacity**:
```bash
kubectl describe nodes | grep -A 5 Allocatable
```

### PVC Stuck in Pending

```bash
kubectl describe pvc -n apps <pvc-name>
```

**Common causes**:
- Longhorn is not healthy
- Wrong `storageClassName` (did you mean to use default Longhorn?)
- No available storage

**Check Longhorn status**:
```bash
kubectl get pods -n longhorn-system

# Access Longhorn UI:
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open: http://localhost:8080
```

### ImagePullBackOff

```bash
kubectl describe pod -n apps <pod-name> | grep -A 5 Events
```

**Common causes**:
- Image name typo
- Private registry without `imagePullSecret`
- Image not available for the node's architecture
- Image doesn't exist in the registry

**Verify multi-arch**:
```bash
docker buildx imagetools inspect <image>:<tag> | grep Platform
```

### Service Not Reachable via Cloudflare Tunnel

1. Verify the hostname entry is in the ingress list in `40_platform.yml`
2. Re-run: `ansible-playbook infra/playbooks/40_platform.yml`
3. Check cloudflared pod restarted and shows the hostname in logs:
   ```bash
   kubectl -n platform logs -l app=cloudflared-cloudflare-tunnel-remote | grep myapp
   ```
4. Verify DNS CNAME: `<hostname> -> <tunnel-id>.cfargotunnel.com` (Proxy: enabled) in Cloudflare Dashboard

### Connection Refused to Internal Service

```bash
# Check if the Service exists
kubectl get svc -n apps myapp

# Check endpoints (pods behind the Service)
kubectl get endpoints -n apps myapp

# Test connectivity from a pod:
kubectl exec -it -n apps <any-pod> -- curl http://myapp.apps.svc.cluster.local:8080
```

**Common causes**:
- Wrong port in Service definition
- Pods not Running
- Wrong `targetPort` in Service
- Application not listening on the expected port

---

## 16) Useful kubectl Aliases

Add these to your `~/.zshrc` for convenience:

```bash
# Set default namespace
alias k='kubectl'
alias kapps='kubectl -n apps'
alias kmon='kubectl -n monitoring'

# Shortcuts
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias kpf='kubectl port-forward'

# Wide output
alias kgpw='kubectl get pods -o wide'
alias kgpgw='kubectl get pods -A -o wide'

# Resource usage
alias ktop='kubectl top'
alias ktp='kubectl top pods'
```

---

## Quick Start Checklist

- [ ] Kubeconfig set: `export KUBECONFIG=~/.kube/homelab.yaml`
- [ ] App uses `apps` namespace
- [ ] Resource limits set for all containers
- [ ] Multi-arch image verified
- [ ] Secrets encrypted via SOPS
- [ ] All file paths in manifests exist and are valid
- [ ] Manifest tested with `kubectl apply --dry-run=client -f <file>`
- [ ] Post-deploy verification commands documented
- [ ] Rollback procedure documented

---

## Where to Go Next

| Need | File |
|------|------|
| Deploy/operate the cluster itself | [DEPLOYMENT.md](DEPLOYMENT.md) |
| View platform interfaces and contracts | [INTERFACES.md](INTERFACES.md) |
| Understand the platform context | [OVERVIEW.md](OVERVIEW.md) |
| Contribute to this infrastructure repo | [DEVELOPMENT.md](DEVELOPMENT.md) |
