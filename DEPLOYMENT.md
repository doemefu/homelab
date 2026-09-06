# Deployment Guide — Operating the Homelab Cluster Infrastructure

This document provides **step-by-step instructions for deploying, operating, and troubleshooting the cluster infrastructure** itself (not for deploying apps on the platform — see [APP-DEPLOYMENT.md](APP-DEPLOYMENT.md) for that).

---

## Pre-Flight Checklist

Before starting any deployment or upgrade, verify:

### Infrastructure Requirements

- [ ] All 4 nodes reachable per `infra/inventory/hosts.yml`:
  - `raspi5` (192.168.1.61) — Control-Plane + Worker
  - `raspi4` (192.168.1.163) — Worker
  - `mba1` (192.168.1.66) — Worker
  - `mba2` (192.168.1.16) — Worker
- [ ] Stable IPs (static or DHCP-reserved)
- [ ] LAN connectivity between all nodes

### Local Tooling

- [ ] `ansible` installed
- [ ] `ansible-lint` installed
- [ ] `kubectl` installed and configured (`export KUBECONFIG=~/.kube/homelab.yaml`)
- [ ] `helm@3` installed (NOT Helm 4 — see [CONTRIBUTING.md](CONTRIBUTING.md))
- [ ] `sops` installed
- [ ] `age` installed
- [ ] `flux` installed
- [ ] age key at `~/.config/age/homelab.key` (NOT in repo)

### Secrets Check

- [ ] `infra/inventory/group_vars/all.sops.yml` exists and is decrypted
- [ ] All required variables set (see [CONTRIBUTING.md](CONTRIBUTING.md))
- [ ] SOPS key available: `export SOPS_AGE_KEY_FILE=~/.config/age/homelab.key`

### External Dependencies

- [ ] Cloudflare Tunnel created (`cloudflared tunnel create homelab`)
- [ ] Cloudflare API token with DNS edit permissions
- [ ] DNS records exist or can be created for all public hostnames

---

## Deployment Order (Step-by-Step)

**Execute playbooks in this exact order** for a complete deployment:

```bash
# 0) New nodes only - bootstrap initial access
ansible-playbook infra/playbooks/00_bootstrap.yml \
  -e ansible_user=<initial-node-user> -l <node> --become

# 1) Base system, hardening, UFW, fail2ban
ansible-playbook infra/playbooks/10_base.yml

# 2) k3s cluster (control-plane + workers)
ansible-playbook infra/playbooks/20_k3s.yml

# 3) Longhorn storage (default StorageClass)
ansible-playbook infra/playbooks/30_longhorn.yml

# 4) Platform: cert-manager, Cloudflare Tunnel, Traefik
ansible-playbook infra/playbooks/40_platform.yml

# 5) Monitoring: kube-prometheus-stack
ansible-playbook infra/playbooks/41_monitoring.yml

# 6) Shared app infrastructure: PostgreSQL 17, InfluxDB 2, Mosquitto 2
ansible-playbook infra/playbooks/50_apps_infra.yml

# 7) App secrets and bootstrap (must run before 52 and 53)
ansible-playbook infra/playbooks/59_app_services.yml

# 8) App runtimes (depend on secrets and DB created by 59)
ansible-playbook infra/playbooks/51_homeassistant.yml
ansible-playbook infra/playbooks/52_n8n.yml
ansible-playbook infra/playbooks/53_litellm.yml
ansible-playbook infra/playbooks/54_club_assistant.yml

# 9) Re-apply platform playbook to ensure Cloudflare Tunnel has all routes
ansible-playbook infra/playbooks/40_platform.yml
```

### Post-Deployment Setup

```bash
# Enable Flux GitOps for auth-service, device-service and furchert-ch
kubectl apply -f cluster/flux-system/apps-sync.yaml

# Verify cluster health
kubectl get nodes -o wide
kubectl get pods -A
```

---

## Cluster Health Checks

### Quick Status

```bash
# Set kubeconfig (if not already set)
export KUBECONFIG=~/.kube/homelab.yaml

# Nodes status
kubectl get nodes -o wide

# All pods across all namespaces
kubectl get pods -A

# Recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Namespace overview
kubectl get ns
```

### Expected Pods by Namespace

| Namespace | Expected Pods | Status |
|-----------|---------------|--------|
| `kube-system` | traefik, coredns, metrics-server, svclb-* | Running |
| `platform` | cert-manager (3x), cloudflared | Running |
| `longhorn-system` | longhorn-manager (2x), longhorn-ui (2x), csi-*, engine-image, instance-manager | Running |
| `monitoring` | prometheus-*, grafana-*, alertmanager-*, kube-state-metrics-*, node-exporter-* | Running |
| `apps` | postgresql-0, influxdb2-0, mosquitto-*, auth-service-*, device-service-*, furchert-ch-*, n8n-*, litellm-*, open-webui-* | Running |
| `homeassistant` | home-assistant-0 | Running |
| `flux-system` | source-controller, kustomize-controller, helm-controller, notification-controller, image-reflector-controller, image-automation-controller | Running |

---

## Component-Specific Operations

### k3s

#### Version Pin

Set in `infra/roles/k3s/defaults/main.yml`:
```yaml
k3s_version: "v1.32.2+k3s1"
```

#### Upgrade Procedure

1. Read [k3s Changelog](https://github.com/k3s-io/k3s/releases) for breaking changes
2. Verify monitoring is green: `kubectl get nodes` — all Ready
3. Verify Longhorn volumes healthy: `kubectl get -n longhorn-system volumes`

**Upgrade one node at a time**:

```bash
# Control-Plane first (raspi5)
kubectl drain raspi5 --ignore-daemonsets --delete-emptydir-data
ansible-playbook infra/playbooks/20_k3s.yml -l raspi5
kubectl uncordon raspi5
kubectl get nodes -w  # Wait for Ready

# Then workers (one at a time)
for NODE in raspi4 mba1 mba2; do
  kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
  ansible-playbook infra/playbooks/20_k3s.yml -l $NODE
  kubectl uncordon $NODE
  kubectl get nodes -w  # Wait for Ready before next
  sleep 30
done
```

#### Check Current Version

```bash
ansible all -m command -a "k3s --version"
```

#### Systemd Unit Templates

After major k3s upgrades, verify service templates against current k3s documentation:
- `infra/roles/k3s/templates/k3s-server.service.j2` (control-plane)
- `infra/roles/k3s/templates/k3s-agent.service.j2` (workers)

---

### Longhorn Storage

#### Status

```bash
# Pods
kubectl get pods -n longhorn-system

# Volumes
kubectl get volumes -n longhorn-system

# StorageClass (longhorn should be default: true)
kubectl get storageclass
```

#### Longhorn UI (Internal Only)

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open: http://localhost:8080
```

#### Root Disk Monitoring

Longhorn writes permanently to `/var/lib/longhorn` (root SD card on Pis).

```bash
# Check free space on root (min 10GB recommended)
ansible raspi5,raspi4 -m command -a "df -h /"

# Check Longhorn node storage status in UI
# http://localhost:8080 -> Node
```

#### local-path Non-Default Fix

After k3s restart or upgrade, local-path may become default again:

```bash
ansible-playbook infra/playbooks/30_longhorn.yml
```

#### Recurring Snapshots (#63)

A Longhorn `RecurringJob` named `daily-snapshot` (applied by `infra/playbooks/30_longhorn.yml`)
takes a snapshot of every Longhorn volume once a day:

- **Schedule:** `0 2 * * *` (02:00 **node-local time** daily — one hour ahead of the existing
  03:00 restic backup cron so the two don't overlap; there is no functional dependency between
  them). Both run in the node's system timezone (`base_timezone: Europe/Zurich`, DST-aware), not
  UTC: Longhorn v1.7.2 doesn't set `spec.timeZone` on the `CronJob` it generates, so it follows
  k3s's embedded controller-manager, which inherits the host's local timezone — the same
  mechanism the restic cron (a plain crontab entry, also node-local) relies on.
- **Retention:** 7 snapshots per volume (Longhorn prunes older ones automatically).
- **Concurrency:** 1 (snapshots run one volume at a time).
- **Coverage:** `groups: [default]` — Longhorn applies a `default`-group job to every volume
  that has no more specific recurring-job/group assignment of its own. As of 2026-09-04 that
  covers all 5 stateful `apps` volumes (`postgresql`, `influxdb2`, `mosquitto`, `n8n`,
  `open-webui`) with no per-volume labeling required, and will automatically cover any future
  stateful volume the same way unless it's later opted into something more specific.

**This is a local snapshot, not an off-cluster backup:** snapshots live on the same physical
disks/replicas as the primary data (see the SD-card root-disk risk noted in
`cluster/values/longhorn.yaml`'s header comment), so this protects against logical mistakes
(bad config change, accidental deletion of *data within* a surviving volume) but not node/disk
hardware failure or a cluster-wide incident. It also does **not** protect against deleting the
PVC or Longhorn Volume itself — Longhorn's volume controller deletes a volume's associated
snapshots as part of tearing the volume down, so once the volume is gone, so are its local
snapshots; only a genuinely off-cluster backup can recover from that. Off-cluster durability (a
Longhorn `BackupTarget` + restic restore testing) is tracked separately in #64 and not yet
implemented.

```bash
# Confirm the job exists and its spec
kubectl -n longhorn-system get recurringjobs.longhorn.io daily-snapshot -o yaml

# List all recurring jobs (Longhorn UI: http://localhost:8080 -> Recurring Job)
kubectl -n longhorn-system get recurringjobs.longhorn.io

# Confirm a volume picked up the default group (empty recurringJobSelector on the volume
# spec is expected — default-group membership isn't itself a per-volume field; check the
# Longhorn UI's Volume -> Recurring Jobs tab, or the snapshot list below, for direct proof)
kubectl -n longhorn-system get volumes.longhorn.io

# List snapshots for a specific volume (volume name = PV name, not the PVC name —
# resolve via: kubectl -n apps get pvc <pvc-name> -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get snapshots.longhorn.io -l longhornvolume=<volume-name>
```

**One-time smoke test** (to confirm the schedule actually fires, rather than trusting the cron
string alone): temporarily edit the RecurringJob's `spec.cron` to `"* * * * *"`
(`kubectl -n longhorn-system edit recurringjobs.longhorn.io daily-snapshot`), wait up to a
minute, confirm a new snapshot appears (`kubectl -n longhorn-system get snapshots.longhorn.io`
or the Longhorn UI), then revert `cron` back to `"0 2 * * *"` (or just re-run
`ansible-playbook infra/playbooks/30_longhorn.yml`, which re-applies the checked-in schedule).

Restore from a recurring snapshot uses the same procedure as the manual snapshot recipe in
"Backup & Rollback for Image Updates" -> "Longhorn volume snapshot" below (scale the workload
to 0 replicas, revert via the Longhorn UI).

**Removing the job:** deleting the task from `30_longhorn.yml` and re-running the playbook does
NOT delete the `RecurringJob` CR — `kubernetes.core.k8s` with a `definition:` block only applies
what's present, it doesn't prune resources removed from the playbook (unlike Flux's
`Kustomization` pruning). Delete it explicitly if it's ever decommissioned:
`kubectl -n longhorn-system delete recurringjobs.longhorn.io daily-snapshot`.

---

### cert-manager / TLS

#### Status

```bash
# ClusterIssuers (both should be READY=True)
kubectl get clusterissuer

# Certificates
kubectl get cert -A

# Certificate details
kubectl describe cert <name> -n <namespace>

# CertificateRequests
kubectl get certificaterequest -A
```

#### Manual Renewal

```bash
# Trigger immediate renewal
kubectl annotate cert <name> -n <namespace> \
  cert-manager.io/issue-temporary-certificate="true" --overwrite

# Or delete (cert-manager recreates automatically)
kubectl delete cert <name> -n <namespace>
```

#### DNS-01 Challenge Debug

```bash
kubectl get challenge -A
kubectl describe challenge <name> -n <namespace>

# Check Cloudflare API token secret
kubectl get secret cloudflare-api-token -n platform -o yaml
```

---

### Cloudflare Tunnel

#### Status

```bash
# Pod status
kubectl -n platform get pods -l app=cloudflared

# Logs
kubectl -n platform logs -l app=cloudflared --tail=50
```

#### Add New Public Endpoint

1. Edit `infra/playbooks/40_platform.yml`, add to `ingress` list before `http_status:404`
2. Re-run: `ansible-playbook infra/playbooks/40_platform.yml`
3. Create DNS CNAME in Cloudflare Dashboard

#### Restart Tunnel Pod

```bash
kubectl -n platform rollout restart deployment/cloudflared-cloudflare-tunnel-remote
kubectl -n platform rollout status deployment/cloudflared-cloudflare-tunnel-remote
```

#### Full Tunnel Recreate (Emergency)

```bash
# Delete old tunnel
cloudflared tunnel delete homelab

# Create new tunnel
cloudflared tunnel create homelab
cloudflared tunnel token homelab  # Update all.sops.yml with new token

# Re-encrypt secrets
sops -e -i infra/inventory/group_vars/all.sops.yml

# Redeploy cloudflared
ansible-playbook infra/playbooks/40_platform.yml
```

---

### SSH Access via Cloudflare Tunnel

#### Client Setup (One-Time)

```bash
# Install cloudflared
brew install cloudflared
```

Add to `~/.ssh/config`:
```sshconfig
Host raspi5
  HostName ssh.furchert.ch
  User ansible
  IdentityFile ~/.ssh/homelab
  ProxyCommand cloudflared access ssh --hostname %h
```

#### Update Ingress List

SSH ingress is configured in `infra/playbooks/40_platform.yml`. To add raspi4 SSH:

```yaml
ingress:
  - hostname: "ssh.furchert.ch"
    service: "ssh://192.168.1.61:22"
  - hostname: "ssh-raspi4.furchert.ch"
    service: "ssh://192.168.1.163:22"
  - service: "http_status:404"
```

Then: `ansible-playbook infra/playbooks/40_platform.yml`

#### Off-LAN kubectl / Ansible Access (Port-Forward over the Tunnel)

When you are **not on the home LAN**, the k3s API (`192.168.1.61:6443`) is unreachable
directly. Open a persistent SSH local port-forward through the Cloudflare Access SSH proxy,
then point kubectl at the local end.

1. Open the forward in its own terminal and leave it running (`-N` = no remote shell, just
   hold the tunnel open):

   ```bash
   ssh -i ~/.ssh/homelab \
     -o ProxyCommand="cloudflared access ssh --hostname %h" \
     -N -L 6443:localhost:6443 \
     ansible@ssh.furchert.ch
   ```

2. Use a kubeconfig context whose server is `https://127.0.0.1:6443` (the `tunnel` context in
   `~/.kube/config`):

   ```bash
   export KUBECONFIG=~/.kube/config
   kubectl config use-context tunnel
   kubectl get pods -n apps        # verify it reaches the cluster
   ```

   Note that the shell default is the LAN file (`~/.zshrc` exports `KUBECONFIG=~/.kube/homelab.yaml`,
   the kubeconfig the playbooks use), so the `export` above is required. On a machine whose
   `~/.kube/config` has no `tunnel` context yet, derive a tunnel kubeconfig from the LAN file instead —
   same CA and client certificate, only the server changes (the existing `tunnel` context already
   relies on the k3s API certificate being valid for `127.0.0.1`):

   ```bash
   sed 's#https://192.168.1.61:6443#https://127.0.0.1:6443#' ~/.kube/homelab.yaml > ~/.kube/tunnel.yaml
   kubectl config rename-context default tunnel --kubeconfig ~/.kube/tunnel.yaml
   export KUBECONFIG=~/.kube/tunnel.yaml
   kubectl get pods -n apps
   ```

> **Gotcha — playbooks hardcode the LAN kubeconfig.** Playbooks that shell out to `kubectl`
> (e.g. `infra/playbooks/59_app_services.yml`) set `kubeconfig: ~/.kube/homelab.yaml`, which
> points at the LAN IP `192.168.1.61:6443` and fails off-LAN with
> `dial tcp 192.168.1.61:6443: connect: network is unreachable`. Override the var to use the
> tunnel context instead (the task sets only `KUBECONFIG`, so it honours that file's
> current-context — set it to `tunnel` first as above):
>
> ```bash
> ansible-playbook infra/playbooks/59_app_services.yml -e kubeconfig="$HOME/.kube/config"
> # with a derived tunnel kubeconfig instead: -e kubeconfig="$HOME/.kube/tunnel.yaml"
> ```
>
> Keep the `-N -L …` terminal running for the whole playbook run — if the forward drops, the
> playbook fails the same way.

#### One-shot kubectl over SSH (no port-forward, no `tunnel` context)

For a single read or a single-manifest apply, run kubectl on the control-plane node through the
same Cloudflare Access SSH proxy instead of holding a forward open:

```bash
ssh -i ~/.ssh/homelab -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps get pods'

# apply exactly one manifest from the local checkout (used for PR #73 on 2026-09-03):
ssh -i ~/.ssh/homelab -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl apply -f -' < cluster/apps/<app>/deployment.yaml
```

This is an escape hatch for reads and for single-file hotfixes of **Ansible-applied** apps (n8n,
litellm, open-webui and the platform charts): it applies exactly the manifest you pipe in and none of
the playbook's other tasks (secrets, PVCs, ConfigMaps, waits), so run the owning playbook with
`--check --diff` on the next LAN session (expect `changed=0`). Never use it for the Flux-managed apps
(auth-service, device-service, furchert-ch): change the app repo and let Flux reconcile — a manual
apply there is overwritten by the next reconciliation (see the Flux contract in INTERFACES.md). For
anything beyond a read or a single-file hotfix, run the owning playbook through the port-forward
(`ansible-playbook … -e kubeconfig=…`, see the gotcha above) instead of this one-shot path. The
`Host raspi5` entry from the SSH-access section above already carries `User ansible`,
the `ProxyCommand` and `IdentityFile`, so `ssh raspi5 'sudo k3s kubectl -n apps get pods'` is the
short form of the commands above.

---

### Monitoring (Prometheus + Grafana)

#### Status

```bash
kubectl get pods -n monitoring

# PVCs (should be Bound)
kubectl get pvc -n monitoring
```

#### Access

```bash
# Grafana (public)
open https://grafana.furchert.ch

# Grafana (local port-forward)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# Open: http://localhost:3000

# Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Open: http://localhost:9090

# Alertmanager
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# Open: http://localhost:9093
```

#### Prometheus Targets

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open: http://localhost:9090/targets
```

Expected UP targets:
- `serviceMonitor/monitoring/traefik` → kube-system
- `serviceMonitor/monitoring/postgresql` → apps
- `serviceMonitor/monitoring/influxdb2` → apps
- `serviceMonitor/monitoring/mosquitto` → apps

> **Note:** `kube-controller-manager`, `kube-scheduler`, and `kube-proxy` are intentionally
> absent from this list and from `/targets` entirely (disabled in
> `cluster/values/kube-prometheus-stack.yaml`, #68) — see "Alerting Decisions" below for why.

> **Note:** `postgres-exporter` v0.20.1 (the pinned version in `50_apps_infra.yml`) does not
> expose `pg_stat_checkpointer_*` metrics by default — no `--collector.*` flags are set on the
> exporter container, so that collector stays off. The PG17 `column "checkpoints_timed" does not
> exist` error seen with the older v0.15.0 exporter is gone (v0.20.1 understands the PG17
> `pg_stat_checkpointer` view), but do not expect checkpoint metrics in Prometheus without
> explicitly enabling that collector.

#### ServiceMonitors

```bash
kubectl get servicemonitor -n monitoring
```

#### Alerting Decisions

**`KubeControllerManagerDown` / `KubeSchedulerDown` / `KubeProxyDown` (disabled, #68):** k3s runs
kube-controller-manager, kube-scheduler, and kube-proxy embedded in the k3s server/agent process,
bound to `127.0.0.1` by default — no `--kube-controller-manager-arg bind-address=`,
`--kube-scheduler-arg bind-address=`, or `--kube-proxy-arg metrics-bind-address=` flag is set
anywhere in `infra/`. The chart's default scrape targets for these 3 components therefore have
zero endpoints, so their `absent(up{job="..."} == 1)` alert rules fired as permanent critical
false positives from install (2026-05-16) onward — they can structurally never resolve. Fixed by
disabling both the component scrape config and the matching alert rule groups in
`cluster/values/kube-prometheus-stack.yaml` (`kubeControllerManager.enabled`,
`kubeScheduler.enabled`, `kubeProxy.enabled`, and the matching `defaultRules.rules.*` keys — all
`false`). The Grafana dashboards for these 3 components already showed "No data" (the targets
never existed) and continue to after this change — that's expected, not a regression.
**Alternative, not implemented** (needs a k3s server/agent config change + restart on `raspi5`,
the only control-plane node — a cluster mutation out of scope for a values-only fix, plus real
security prerequisites that would need to be worked out before enabling it): add
`--kube-controller-manager-arg bind-address=0.0.0.0` and `--kube-scheduler-arg bind-address=0.0.0.0`
to the k3s server args, then set `kubeControllerManager.endpoints` / `kubeScheduler.endpoints` to
`["192.168.1.61"]`. Both components serve their metrics on Kubernetes's authenticated HTTPS
"secure serving" port — `https` + `insecureSkipVerify` only skips *certificate validation*, it
does not bypass authentication, so the ServiceMonitor would additionally need a working bearer
token/RBAC credential for Prometheus to actually scrape (not yet designed here). `kube-proxy` is
different: `--kube-proxy-arg metrics-bind-address=0.0.0.0:10249` exposes a **plain HTTP, unauthenticated**
metrics endpoint (no TLS support in kube-proxy itself), so `kubeProxy.endpoints`/`https` config
does not apply to it the same way — it would need its own values wiring and, because binding any
of these three to `0.0.0.0` exposes the listener on every node network interface, network-level
restriction (firewall rule or NetworkPolicy scoped to the `monitoring` namespace's Prometheus pod)
before it's safe to enable. None of this is implemented; revisit as a separate, security-reviewed
task if real coverage of these 3 components is ever wanted.

**`CPUThrottlingHigh` review (#68, following the 2026-08-28 auth-service/device-service CPU-limit
changes to 1000m):** 24h throttled-CFS-period ratios — `postgres-exporter` (in the `postgresql-0`
pod) **0.67**, the only container above the 25% alert threshold, at a `limits.cpu: 100m` against
~0.0016 cores average usage (classic scrape-burst-vs-tiny-quota pattern); `auth-service` 0.009 and
`device-service` 0.007 at their new 1000m limits — both already fine, no further tuning needed.
Decision: raised `postgres-exporter`'s `limits.cpu` to `250m` in `infra/playbooks/50_apps_infra.yml`
(`requests` unchanged); kept the alert itself (severity `info`, already excluded from paging by
`InfoInhibitor`) rather than tuning its expression — it was correctly identifying a genuinely
undersized CPU quota, not a false positive.

---

### Home Assistant

#### Deploy/Redeploy

```bash
ansible-playbook infra/playbooks/51_homeassistant.yml
```

#### Access

Home Assistant uses `hostNetwork: true` and listens directly on node IP port 8123.

```bash
# Find node running HA
kubectl get pod -n homeassistant -o wide

# Port-forward from remote
ssh -fN -L 8123:<node-ip>:8123 ansible@raspi5

# Access: http://localhost:8123
```

#### Upgrade

Bump `chart_version` in `cluster/values/home-assistant.yaml`, then re-run playbook.

---

### n8n

#### Deploy/Redeploy

```bash
ansible-playbook infra/playbooks/52_n8n.yml
```

#### Secrets

Secrets are provisioned via `59_app_services.yml`:

```bash
ansible-playbook infra/playbooks/59_app_services.yml
```

#### Restart

```bash
kubectl rollout restart deployment/n8n -n apps
```

#### Upgrade

1. Update the image tag in `cluster/apps/n8n/deployment.yaml` to the new pinned version
2. Re-run: `ansible-playbook infra/playbooks/52_n8n.yml`
3. Confirm: `kubectl -n apps rollout status deployment/n8n --timeout=10m`

n8n's TypeORM migrations against its SQLite database are forward-only in practice — back up the
`n8n-data` PVC per the n8n backup steps in the [Backup & rollback](#backup--rollback-for-image-updates-open-webui-litellm-n8n-postgresql-cloudflared)
runbook below before upgrading, and never point an older image at a database a newer image has
already migrated.

> **Note:** n8n 2.36.8's `/rest/settings` reports `sso.oidc.loginEnabled: false` /
> `enterprise.oidc: false` even though env-managed OIDC (`N8N_SSO_MANAGED_BY_ENV`,
> `N8N_SSO_OIDC_*`) is applied and the n8n log shows "OIDC login is enabled — applying OIDC SSO
> env vars" — the OIDC login button appears to be gated by an unlicensed enterprise feature flag.
> This was not verified end-to-end; verify with an actual login attempt before relying on it.

---

### LiteLLM

#### Deploy/Redeploy

Secrets must be bootstrapped first:

```bash
# Verify SOPS vars
sops infra/inventory/group_vars/all.sops.yml

# Create secrets
ansible-playbook infra/playbooks/59_app_services.yml

# Deploy manifests
ansible-playbook infra/playbooks/53_litellm.yml

# Update Cloudflare Tunnel
ansible-playbook infra/playbooks/40_platform.yml
```

#### Verify

```bash
kubectl get pods -n apps -l app=litellm
kubectl get secret litellm-secrets -n apps

# Full smoke test (requires LITELLM_MASTER_KEY)
LITELLM_BASE_URL=https://ai.furchert.ch LITELLM_MASTER_KEY=sk-... \
  ./scripts/smoke-test-litellm.sh
```

#### Upgrade

1. Update image tag in `cluster/apps/litellm/deployment.yaml` to new pinned version
2. Check [LiteLLM release notes](https://github.com/BerriAI/litellm/releases) — avoid known malicious versions (e.g., 1.82.7, 1.82.8)
3. Re-run: `ansible-playbook infra/playbooks/53_litellm.yml`
4. Confirm: `kubectl rollout status deployment/litellm -n apps`

> **Why step 4 matters:** the playbook's own rollout-wait task ("LiteLLM Rollout warten") polls
> `status.availableReplicas == spec.replicas`, which is already true from the *old* pod under the
> Deployment's default `RollingUpdate` strategy — it does not gate on the new pod actually coming
> up. The playbook can report success while the old image is still serving. Always confirm the
> new image landed with `kubectl -n apps rollout status deploy/litellm --timeout=10m` rather than
> trusting the playbook's "changed" result alone.

---

### Backup & rollback for image updates (Open WebUI, LiteLLM, n8n, PostgreSQL, cloudflared)

All 8 platform images (the 5 in this runbook, plus postgres-exporter, mosquitto, and
mosquitto-exporter) are pinned by tag **and digest** (`repo:tag@sha256:...`, #57) — see
CONTRIBUTING.md "Digest-Pinned Platform Images" for how to re-resolve the digest as part
of any bump. Of the 3 not named in this runbook's title, postgres-exporter and
mosquitto-exporter have no backup step here (no migration-forward-only concern like
Postgres/n8n/open-webui/litellm) — just re-resolve their digest per that procedure when
bumping. mosquitto does have a backup subsection below (nice-to-have, not a hard
prerequisite — see "mosquitto (persistence DB, nice-to-have)").

Use this runbook whenever bumping a pinned image tag for one of these five components. Rule:
**Open WebUI's alembic, LiteLLM's prisma, and n8n's TypeORM migrations are forward-only in
practice.** Never point an older image at a database/PVC a newer image has already migrated —
restore the pre-upgrade backup first, then roll the image back.

Run these blocks with `set -euo pipefail`; a zero-byte backup file means the exec failed.

#### Backup directory convention

```bash
mkdir -p -m 700 ~/homelab-backups/$(date +%F)
chmod 700 ~/homelab-backups ~/homelab-backups/$(date +%F)  # -m only applies to dirs mkdir creates, not pre-existing ones
```

These dumps can contain credentials/PII — keep them local-only (never commit, never upload) and
delete the directory once the new version has run cleanly through a burn-in period.

#### Open WebUI (SQLite DB + vector DB + uploads)

Known regressions on Open WebUI v0.11.x (unfixed in any released tag, 2026-08-28): toggling a
model's enable/disable switch in Admin > Models permanently deletes it (open-webui#29036 et al.)
— manage models in LiteLLM instead; Workspace > Knowledge page hangs (open-webui#29104) — use
chat/REST for RAG checks.

Quiesce before backing up the PVC — a live pod can still be writing to SQLite/`vector_db` mid-copy:

```bash
kubectl -n apps scale deploy/open-webui --replicas=0
kubectl -n apps wait --for=delete pod -l app=open-webui --timeout=120s
kubectl -n apps run open-webui-backup-helper --image=busybox:1.37.0 --restart=Never \
  --override-type=merge \
  --overrides='{"spec":{"containers":[{"name":"helper","image":"busybox:1.37.0","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"open-webui-data"}}]}}'
kubectl -n apps wait --for=condition=Ready pod/open-webui-backup-helper --timeout=60s
kubectl -n apps exec open-webui-backup-helper -c helper -- tar czf - -C /data . > ~/homelab-backups/$(date +%F)/open-webui-data.tgz
tar tzf ~/homelab-backups/$(date +%F)/open-webui-data.tgz | head -3
kubectl -n apps delete pod open-webui-backup-helper
```

Re-run the rollout (`ansible-playbook infra/playbooks/54_club_assistant.yml` after bumping the
image tag) to scale the Deployment back up with the new image — do not `scale --replicas=1`
manually onto the old image.

> **Gotcha:** never run `ansible-playbook infra/playbooks/54_club_assistant.yml --check` while
> Open WebUI is scaled to 0. The playbook's rollout-wait task ("Open WebUI Rollout warten") polls
> `status.availableReplicas == spec.replicas` with `retries: 30` / `delay: 10` (a 300s budget).
> `--check` mode never actually applies the Deployment back to `replicas: 1`, so the condition
> never becomes true and the play stalls through the full 300s retry budget before failing.
> Observed 2026-08-29: a `--check` run against a scaled-to-0 Deployment stalled through that
> budget as part of an observed ~12 min Open WebUI downtime window; `kubectl apply -f
> cluster/apps/open-webui/{pvc,deployment,service}.yaml` recovered it directly, and the playbook
> re-run afterwards reported `changed=0` (idempotent). For a scaled-to-0 restore or upgrade,
> apply the manifests directly with `kubectl apply` first, then run `54_club_assistant.yml`
> afterwards for idempotency — never use `--check` as the first step while replicas=0.

Optional no-downtime pre-copy of `webui.db` only, useful if you want a snapshot *before* scaling
to 0 (e.g. to diff schema before/after):

```bash
POD=$(kubectl -n apps get pod -l app=open-webui -o jsonpath='{.items[0].metadata.name}')
kubectl -n apps exec "$POD" -- python3 -c \
  "import sqlite3; s=sqlite3.connect('/app/backend/data/webui.db'); d=sqlite3.connect('/app/backend/data/webui.db.bak'); s.backup(d); d.close()"
kubectl -n apps cp "apps/$POD:/app/backend/data/webui.db.bak" ~/homelab-backups/$(date +%F)/open-webui-webui.db.bak
kubectl -n apps exec "$POD" -- rm -f /app/backend/data/webui.db.bak
ls -lh ~/homelab-backups/$(date +%F)/open-webui-webui.db.bak
```

This pre-copy covers `webui.db` only, not `vector_db`/`uploads` — it does not replace the quiesced
`open-webui-data.tgz` backup above. If you restore from it alone, it must be copied back as
`/app/backend/data/webui.db` specifically, with any `webui.db-wal` / `webui.db-shm` files next to
it removed first.

#### LiteLLM (Postgres `litellm` database)

```bash
kubectl -n apps exec postgresql-0 -c postgresql -- \
  pg_dump -U postgres -Fc litellm > ~/homelab-backups/$(date +%F)/litellm.dump
pg_restore -l ~/homelab-backups/$(date +%F)/litellm.dump | head -5
```

Since PR-2 (2026-08-29), the LiteLLM container image is `litellm-non_root` and runs as uid 65534
instead of root — this does not change the backup/restore procedure above in any way.

#### n8n (workflow/credential export + full PVC)

```bash
POD=$(kubectl -n apps get pod -l app=n8n -o jsonpath='{.items[0].metadata.name}')
kubectl -n apps exec "$POD" -- n8n export:workflow --backup --output=/home/node/.n8n/backups/pre-upgrade/
kubectl -n apps exec "$POD" -- n8n export:credentials --backup --output=/home/node/.n8n/backups/pre-upgrade/
# Restorable only with the same N8N_ENCRYPTION_KEY (Secret n8n-secrets) — do not rotate it
# between backup and restore.
# never add --decrypted here — that writes plaintext credential secrets to disk
kubectl -n apps exec "$POD" -- ls -lh /home/node/.n8n/backups/pre-upgrade/

kubectl -n apps scale deploy/n8n --replicas=0
kubectl -n apps wait --for=delete pod -l app=n8n --timeout=120s
kubectl -n apps run n8n-backup-helper --image=busybox:1.37.0 --restart=Never \
  --override-type=merge \
  --overrides='{"spec":{"containers":[{"name":"helper","image":"busybox:1.37.0","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"n8n-data"}}]}}'
kubectl -n apps wait --for=condition=Ready pod/n8n-backup-helper --timeout=60s
kubectl -n apps exec n8n-backup-helper -c helper -- tar czf - -C /data . > ~/homelab-backups/$(date +%F)/n8n-data.tgz
tar tzf ~/homelab-backups/$(date +%F)/n8n-data.tgz | head -3
kubectl -n apps delete pod n8n-backup-helper
kubectl -n apps scale deploy/n8n --replicas=1
```

#### PostgreSQL (all databases, before an image bump)

```bash
kubectl -n apps exec postgresql-0 -c postgresql -- pg_dumpall -U postgres > ~/homelab-backups/$(date +%F)/pg-all.sql
grep -c '^CREATE DATABASE' ~/homelab-backups/$(date +%F)/pg-all.sql
kubectl -n apps exec postgresql-0 -c postgresql -- pg_dump -U postgres -Fc club_assistant > ~/homelab-backups/$(date +%F)/club_assistant.dump
pg_restore -l ~/homelab-backups/$(date +%F)/club_assistant.dump | head -5
```

#### Longhorn volume snapshot (optional, whole-PVC, faster restore)

```bash
kubectl apply -f - <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: pre-upgrade-<component>
  namespace: longhorn-system
spec:
  volume: <pvc-volume-name>   # kubectl -n apps get pvc <name> -o jsonpath='{.spec.volumeName}'
  createSnapshot: true
EOF
```

Revert: scale the workload to 0 replicas, then use the Longhorn UI
(`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`) to revert the volume.

#### cloudflared

Stateless — no backup needed. Rollback is an image-tag revert only (see below).

#### mosquitto (persistence DB, nice-to-have)

```bash
MPOD=$(kubectl -n apps get pod -l app=mosquitto -o jsonpath='{.items[0].metadata.name}')
# Force a persistence save first (mosquitto writes mosquitto.db only periodically / on close)
kubectl -n apps exec "$MPOD" -- kill -USR1 1 && sleep 2
kubectl -n apps cp "apps/$MPOD:/mosquitto/data/mosquitto.db" ~/homelab-backups/$(date +%F)/mosquitto.db
ls -l ~/homelab-backups/$(date +%F)/mosquitto.db
```

Persistence format is identical across the pinned tags (`MOSQ_DB_VERSION` unchanged), so this
backup is a nice-to-have, not a hard prerequisite. Rollback is a plain image-tag revert
(`git revert` the mosquitto commit + re-run `ansible-playbook infra/playbooks/50_apps_infra.yml`)
— no data restore step is needed.

A mosquitto restart briefly drops device-service's MQTT connection. After any mosquitto rollout
(forward or rollback), confirm it reconnects:

```bash
kubectl -n apps logs deploy/device-service --since=5m | grep -i mqtt
```

If no reconnect shows up within about 2 minutes, force it: `kubectl -n apps rollout restart
deploy/device-service`, then re-check the logs.

#### Restore paths

- **Image-only revert** (no DB touched): `kubectl -n apps set image deployment/<name> <name>=<old-image>`,
  or revert the tag in git (`cluster/apps/<app>/deployment.yaml`, `cluster/values/cloudflared.yaml`,
  `infra/playbooks/50_apps_infra.yml`) with `git revert` and re-run the matching playbook.
- **Open WebUI restore**: scale to 0, start the same helper pod as the backup step above (PVC
  `open-webui-data`, `--override-type=merge`), then **clear the volume before extracting** so
  files written after the backup are removed:
  ```bash
  kubectl -n apps scale deploy/open-webui --replicas=0
  kubectl -n apps run open-webui-backup-helper --image=busybox:1.37.0 --restart=Never \
    --override-type=merge \
    --overrides='{"spec":{"containers":[{"name":"helper","image":"busybox:1.37.0","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"open-webui-data"}}]}}'
  kubectl -n apps wait --for=condition=Ready pod/open-webui-backup-helper --timeout=60s
  kubectl -n apps exec open-webui-backup-helper -c helper -- sh -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; true'
  kubectl -n apps cp ~/homelab-backups/<date>/open-webui-data.tgz open-webui-backup-helper:/tmp/open-webui-data.tgz -c helper
  kubectl -n apps exec open-webui-backup-helper -c helper -- tar xzf /tmp/open-webui-data.tgz -C /data
  kubectl -n apps delete pod open-webui-backup-helper
  kubectl -n apps scale deploy/open-webui --replicas=1
  ```
  (equivalently: `find /data -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +` instead
  of the glob). If only the no-downtime `webui.db` pre-copy was taken (no `open-webui-data.tgz`),
  it must be copied back as `/app/backend/data/webui.db` specifically through a live pod
  (`kubectl cp`, not the helper's `/data` mount), with any `webui.db-wal` / `webui.db-shm` files
  removed first. The full-PVC Longhorn snapshot (see above) is the alternative when a full
  quiesced restore is preferred over `tar`.
- **n8n restore**: scale to 0, start a helper pod mounting `n8n-data` (same `--override-type=merge`
  shape as the backup helper above), `kubectl cp` the backup back in, `kubectl exec
  n8n-backup-helper -c helper -- tar xzf /tmp/n8n-data.tgz -C /data`, delete the helper, scale back
  to 1.
- **LiteLLM**: stop the workload and recreate the database before restoring — do not `pg_restore`
  over an already-migrated schema:
  ```bash
  kubectl -n apps scale deploy/litellm --replicas=0
  kubectl -n apps wait --for=delete pod -l app=litellm --timeout=120s
  # fallback if the wait times out (a stuck connection can block DROP DATABASE):
  kubectl -n apps exec -it postgresql-0 -c postgresql -- psql -U postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='litellm';"
  kubectl -n apps exec -it postgresql-0 -c postgresql -- psql -U postgres -c "DROP DATABASE litellm;"
  kubectl -n apps exec -it postgresql-0 -c postgresql -- psql -U postgres -c "CREATE DATABASE litellm OWNER litellm;"
  kubectl -n apps cp ~/homelab-backups/<date>/litellm.dump postgresql-0:/tmp/litellm.dump -c postgresql
  kubectl -n apps exec postgresql-0 -c postgresql -- pg_restore -U postgres -d litellm --no-owner --role=litellm /tmp/litellm.dump
  kubectl -n apps scale deploy/litellm --replicas=1
  ```
- **PostgreSQL image revert** — pick the path that matches how far the upgrade progressed:
  - (a) **Tag revert only**, safe while `ALTER EXTENSION vector UPDATE;` has **not** yet been run
    against `club_assistant` (the underlying PG minor bump is on-disk compatible either way).
  - (b) **After** `ALTER EXTENSION vector UPDATE;` has run: revert the image tag first, then
    restore `club_assistant` under the older image:
    ```bash
    kubectl -n apps exec -it postgresql-0 -c postgresql -- psql -U postgres -c "DROP DATABASE club_assistant;"
    kubectl -n apps exec -it postgresql-0 -c postgresql -- psql -U postgres -c "CREATE DATABASE club_assistant OWNER club_assistant;"
    kubectl -n apps cp ~/homelab-backups/<date>/club_assistant-pre-<date>.dump postgresql-0:/tmp/club_assistant.dump -c postgresql
    kubectl -n apps exec postgresql-0 -c postgresql -- pg_restore -U postgres -d club_assistant --no-owner --role=club_assistant /tmp/club_assistant.dump
    kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -d club_assistant -c "SELECT extversion FROM pg_extension WHERE extname='vector';"
    ```
    Verify `extversion` matches the older image's bundled pgvector build before starting the
    workloads back up.
  - (c) **Full-PVC alternative**: scale the `postgresql` StatefulSet to 0 and revert the
    pre-upgrade Longhorn snapshot of `data-postgresql-0` (see the Longhorn snapshot subsection
    above), then scale back up under the older image.

---

### Flux CD (GitOps)

#### Status

```bash
flux check
flux get sources git -n flux-system
flux get kustomizations -n flux-system
flux get image repositories -n flux-system
flux get image policy -n flux-system
flux get image update -n flux-system
```

#### Force Reconciliation

```bash
flux reconcile kustomization device-service -n flux-system --with-source
flux reconcile kustomization auth-service -n flux-system --with-source
```

#### Emergency Pin/Unpin

```bash
# Stop automatic updates
flux suspend image update <app> -n flux-system

# Resume automatic updates
flux resume image update <app> -n flux-system
```

#### Troubleshooting

```bash
# View reconciliation logs
flux logs -n flux-system --kind=Kustomization --name=device-service

# Check pod image tag
kubectl get pods -n apps -l app=device-service \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

Common issues:
- SSH deploy key missing/revoked → check `flux get sources git` for auth errors
- GHCR package is private → add `ghcr-auth` secret
- Tag filter mismatch → verify tags match `^main-[0-9]{8}T[0-9]{6}$`

---

### Backup (Restic)

#### Status

```bash
# Last run (systemd journal on raspi5)
ssh raspi5 "journalctl -t homelab-backup --since '24 hours ago'"

# List snapshots
ssh raspi5 "sudo restic snapshots \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"

# Integrity check
ssh raspi5 "sudo restic check \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"
```

#### Manual Backup

```bash
ssh raspi5 "sudo /usr/local/bin/homelab-backup.sh"
```

#### Restore Test (Non-Destructive)

```bash
# List snapshots
ssh raspi5 "sudo restic snapshots \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"

# Restore to /tmp/restore-test
ssh raspi5 "sudo restic restore latest \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /tmp/restore-test"

# Verify k3s etcd snapshots
ssh raspi5 "ls -lh /tmp/restore-test/var/lib/rancher/k3s/server/db/snapshots/"

# Cleanup
ssh raspi5 "sudo rm -rf /tmp/restore-test"
```

#### Full Restore (Disaster Recovery)

Only when k3s is stopped and node is freshly provisioned:

```bash
# Stop k3s
ssh raspi5 "sudo systemctl stop k3s"

# Restore from specific snapshot
ssh raspi5 "sudo restic restore <snapshot-id> \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /"

# Start k3s
ssh raspi5 "sudo systemctl start k3s"
```

---

## Node Operations

### Drain and Reboot

```bash
# Drain node (move workloads to other nodes)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# Reboot via Ansible
ansible <node> -m reboot --become

# Uncordon node (allow scheduling again)
kubectl uncordon <node>
```

### MacBook Watchdog

MacBook Air workers (mba1, mba2) run a kernel watchdog (`softdog`) that auto-reboots on kernel freeze/panic.

```bash
# Verify watchdog health
ssh ansible@<mba-ip> "systemctl is-active watchdog && lsmod | grep softdog"

# Temporarily disable for maintenance
ansible-playbook infra/playbooks/10_base.yml -l <node> -e "mac_tweaks_watchdog_enabled=false"

# Re-enable
ansible-playbook infra/playbooks/10_base.yml -l <node>

# Check unexpected reboots
ssh ansible@<mba-ip> "sudo journalctl -b -1 --no-pager | tail -50"
ssh ansible@<mba-ip> "sudo last -x reboot | head -5"
```

---

## Troubleshooting Guide

### Common Issues by Symptom

#### "Connection refused" to kubectl

```bash
# Verify KUBECONFIG is set
ls -la ~/.kube/homelab.yaml

export KUBECONFIG=~/.kube/homelab.yaml

# Check k3s API server
kubectl get nodes

# If k3s is down, check on raspi5:
ssh ansible@raspi5 "sudo systemctl status k3s"
```

#### Pods stuck in CrashLoopBackOff

```bash
kubectl get pods -A -o wide  # Find the problematic pod
kubectl logs -n <ns> <pod> --previous
kubectl describe pod -n <ns> <pod>
```

#### Node Not Ready

```bash
kubectl describe node <node>

# Check k3s on the node:
ssh ansible@<node> "sudo systemctl status k3s"

# Check kubelet:
ssh ansible@<node> "sudo systemctl status k3s-agent"
```

#### Longhorn volumes degraded

```bash
kubectl get volumes -n longhorn-system

# Check Longhorn UI:
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open: http://localhost:8080
```

#### Cloudflare Tunnel not routing

```bash
# Check cloudflared logs
kubectl -n platform logs -l app=cloudflared --tail=100

# Verify ingress config
kubectl -n platform get cm cloudflared-config -o yaml

# Restart tunnel pod
kubectl -n platform rollout restart deployment/cloudflared-cloudflare-tunnel-remote
```

#### cert-manager certificates not issuing

```bash
kubectl get cert -A
kubectl describe cert <name> -n <namespace>

# Check ClusterIssuer status
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod

# Verify Cloudflare API token
kubectl get secret cloudflare-api-token -n platform -o yaml
```

#### SSH access denied

```bash
# Verify SSH service on node
ssh ansible@<node> "sudo systemctl status ssh"

# Check UFW firewall
ssh ansible@<node> "sudo ufw status"

# Check SSH hardening
ssh ansible@<node> "sudo cat /etc/ssh/sshd_config.d/hardening.conf"
```

---

## Emergency Procedures

### Full Cluster Reset

1. **Backup etcd snapshots** from raspi5:
   ```bash
   scp ansible@raspi5:/var/lib/rancher/k3s/server/db/snapshots/* ./backup-$(date +%Y%m%d)/
   ```

2. **Wipe k3s from all nodes**:
   ```bash
   ansible all -m command -a "sudo k3s-uninstall.sh" --become
   ansible all -m command -a "sudo rm -rf /var/lib/rancher /etc/rancher" --become
   ```

3. **Re-deploy from scratch** following the [Deployment Order](#deployment-order-step-by-step) above

---

## Regular Maintenance Checklist

| Task | Frequency | Command |
|------|-----------|---------|
| Verify all pods Running | Daily | `kubectl get pods -A` |
| Check node resource usage | Daily | `kubectl top nodes` |
| Verify Longhorn volume health | Daily | `kubectl get volumes -n longhorn-system` |
| Check backup status | Daily | `ssh raspi5 "journalctl -t homelab-backup --since '24 hours ago'"` |
| Verify Flux reconciliation | Daily | `flux check` |
| Restart degraded Longhorn volumes | Weekly | Check Longhorn UI for degraded volumes |
| Verify Longhorn recurring snapshot job fired | Weekly | `kubectl -n longhorn-system get recurringjobs.longhorn.io daily-snapshot` + `kubectl -n longhorn-system get snapshots.longhorn.io` (see "Recurring Snapshots (#63)" above) |
| Test backup restore | Monthly | Non-destructive restore test (see above) |
| Update Python packages | Monthly | `pip install --upgrade ansible ansible-lint` |
| Review k3s security advisories | Monthly | Check [k3s releases](https://github.com/k3s-io/k3s/releases) |
| Check Ansible collection versions | Monthly | `ansible-galaxy collection list` vs Galaxy API — see CONTRIBUTING.md "Ansible Collection Updates (Manual)" |
| Triage Helm chart freshness issues | Weekly (automated) / as opened | Handle any open GitHub issue labeled `helm-freshness` — see CONTRIBUTING.md "Helm Chart Version Tracking" |

---

## Quick Reference: All Playbooks

| Playbook | Purpose | Runtime | Idempotent |
|----------|---------|---------|------------|
| `00_bootstrap.yml` | Initial node setup (Python, ansible user, SSH key) | 2-5 min | Yes (after first run) |
| `10_base.yml` | Base packages, hardening, UFW, fail2ban, watchdog | 3-5 min | Yes |
| `20_k3s.yml` | k3s installation and configuration | 5-10 min | Yes |
| `30_longhorn.yml` | Longhorn storage system, default StorageClass, and daily recurring snapshot job | 3-5 min | Yes |
| `40_platform.yml` | cert-manager, Cloudflare Tunnel, Traefik | 3-5 min | Yes |
| `41_monitoring.yml` | kube-prometheus-stack (long Helm wait) | 10-15 min | Yes |
| `50_apps_infra.yml` | PostgreSQL 17, InfluxDB 2, Mosquitto 2 | 5-8 min | Yes |
| `51_homeassistant.yml` | Home Assistant | 3-5 min | Yes |
| `52_n8n.yml` | n8n deployment | 2-3 min | Yes |
| `53_litellm.yml` | LiteLLM deployment | 3-5 min | Yes |
| `54_club_assistant.yml` | Open WebUI (Club Assistant) deployment + DB provisioning | 3–5 min | Yes |
| `59_app_services.yml` | App secrets and bootstrap | 2-3 min | Yes |

---

## Related Documentation

| Need | File |
|------|------|
| Deploy YOUR apps on this platform | [APP-DEPLOYMENT.md](APP-DEPLOYMENT.md) |
| Platform interfaces and contracts | [INTERFACES.md](INTERFACES.md) |
| Platform overview, features, URLs | [README.md](README.md) |
| Work on this infrastructure repo | [CONTRIBUTING.md](CONTRIBUTING.md) |
