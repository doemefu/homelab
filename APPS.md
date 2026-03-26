# APPS.md — App Deployment Guide

---

## Namespace Conventions

| Namespace        | Purpose                                                      | Notes                                      |
|------------------|--------------------------------------------------------------|--------------------------------------------|
| `platform`       | Cluster infrastructure (cert-manager, cloudflared, Traefik) | No app workloads                           |
| `longhorn-system`| Longhorn storage (Helm-Chart-Konvention)                    | No app workloads                           |
| `monitoring`     | Prometheus, Grafana, Alertmanager                           | No app workloads                           |
| `apps`           | All application workloads                                   | Resource limits required; no cluster-admin ServiceAccounts |

Do not create namespaces outside this list without explicit discussion (CLAUDE.md non-negotiable).

Create the `apps` namespace once before your first deployment:

```bash
kubectl create namespace apps
```

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

The cluster runs ARM64 nodes (raspi5, raspi4) and will include amd64 nodes (mba1, mba2) post-M5.
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
