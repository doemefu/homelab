# APPS.md — App Deployment Guide

> **Stand:** M4-Stub. Vollständige Inhalte folgen in M5.

---

## Namespace Conventions

| Namespace        | Purpose                                                      | Notes                                      |
|------------------|--------------------------------------------------------------|--------------------------------------------|
| `platform`       | Cluster infrastructure (cert-manager, cloudflared, Traefik) | No app workloads                           |
| `longhorn-system`| Longhorn storage (Helm-Chart-Konvention)                    | No app workloads                           |
| `monitoring`     | Prometheus, Grafana, Alertmanager                           | No app workloads                           |
| `apps`           | All application workloads                                   | Resource limits required; no cluster-admin ServiceAccounts |

Do not create namespaces outside this list without explicit discussion (CLAUDE.md non-negotiable).

---

## Cloudflare Tunnel Ingress Pattern

Services in `apps` are exposed externally by adding an entry to the cloudflared ingress list in
`infra/playbooks/40_platform.yml`. No Kubernetes Ingress resource or TLS certificate is required —
TLS is terminated at the Cloudflare edge.

Cross-namespace access uses the cluster-internal FQDN:

```
http://<service-name>.<namespace>.svc.cluster.local:<port>
```

Example (Grafana in `monitoring` namespace, accessed by cloudflared in `platform`):

```yaml
- hostname: grafana.furchert.ch
  service: http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80
```

After updating the ingress list, re-run the platform playbook (cloudflared Pod restarts automatically):

```bash
ansible-playbook infra/playbooks/40_platform.yml
```

> **Hinweis:** The cloudflared ingress PUT replaces the full list — always include all existing
> entries (SSH, Grafana, 404 fallback). The 404 fallback must be last.

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

## Reference Manifests

> To be completed in M5. See `examples/` directory (not yet created).
