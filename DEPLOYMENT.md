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
- [ ] helm-diff plugin installed, pinned: `helm plugin install https://github.com/databus23/helm-diff --version v3.15.13`. Without it, `kubernetes.core.helm` warns and falls back to a values comparison. That fallback compares the release only with the values file, so the InfluxDB task in `50_apps_infra.yml` (values file plus inline SOPS values) reports `changed` on every run (homelab#66).
- [ ] `sops` installed
- [ ] `age` installed
- [ ] `flux` installed
- [ ] age key at `~/.config/age/homelab.key` (NOT in repo)

### Secrets Check

- [ ] `infra/inventory/group_vars/all.sops.yml` exists and is decrypted
- [ ] All required variables set (see INTERFACES.md § 7 "Required SOPS Variables")
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
# Enable Flux GitOps for auth-service, device-service, furchert-ch and data-service
# (data-service first needs its deploy key + DB/Secret — see "data-service (Flux, NM-0 onboarding)")
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
| `monitoring` | prometheus-*, grafana-*, alertmanager-*, kube-state-metrics-*, node-exporter-*, coroot-node-agent-* (only on gated nodes — see "coroot-node-agent (NM-2)") | Running |
| `apps` | postgresql-0, influxdb2-0, mosquitto-*, auth-service-*, device-service-*, furchert-ch-*, data-service-*, n8n-*, litellm-*, open-webui-* | Running |
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

#### k3s datastore (kine/SQLite) maintenance

k3s's embedded datastore is [kine](https://github.com/k3s-io/kine) on SQLite
(`/var/lib/rancher/k3s/server/db/state.db`, control-plane node only — raspi5). kine's online
compactor runs every 5 minutes, with a 5 second per-batch `DELETE` timeout and a 1,000-row batch
size (`compactInterval`, `compactTimeout`, `compactBatchSize` in
`pkg/logstructured/sqllog/sql.go`, kine v0.13.9 — none of these are tunable via k3s flags). On a
large enough backlog, a batch can exceed the 5 second timeout; Go's `database/sql` rolls that
transaction back, and the compactor stalls permanently instead of retrying — the datastore keeps
growing and query latency keeps degrading until someone intervenes by hand. This happened on
raspi5 on 2026-09-23 (homelab#129): compaction had silently stalled for ~5 days, `state.db` grew
to 5.02 GB / 1.49M rows, and the cluster degraded. Details, full timeline and root-cause analysis
are in the issue; this section is the reusable runbook that came out of it.

##### Symptoms

- `journalctl -u k3s` full of `Slow SQL` lines (kine, queries >1s) — hundreds per hour instead of
  the normal 30-90/hour baseline.
- `kubectl get --raw /readyz` (or `/readyz?verbose`) reports `[-]etcd failed` /
  `etcd-readiness failed` — the storage health check is exceeding the apiserver's default 2s
  `--etcd-healthcheck-timeout`/`--etcd-readycheck-timeout`.
- `raspi5` load average climbing into the double digits with `k3s-server` pinned near 300% CPU
  and 0% iowait — SQLite lock contention, not disk-bound.
- `flux-system` controllers and Longhorn CSI sidecars in `CrashLoopBackOff` from failed
  leader-election lease renewals (HTTP 504 on lease `PUT`s).
- If the apiserver etcd health-check timeout has already been raised (drop-in below) and the
  embedded cloud-controller-manager still restarts every few minutes with `error building
  controller context: failed to wait for apiserver being healthy` / `cloud-controller-manager
  panic` in the journal, `/healthz` itself (not just `/readyz`) is now failing too — the backlog
  is far enough behind that the raised timeout isn't enough on its own; go straight to offline
  compaction below.

##### Read-only diagnostics (safe any time — k3s keeps running)

```bash
ssh raspi5
```

```bash
# state.db row count and compaction lag — mode=ro, does not lock the live datastore
python3 -c "
import sqlite3
c = sqlite3.connect('file:/var/lib/rancher/k3s/server/db/state.db?mode=ro', uri=True, timeout=30)
print('rows', c.execute('SELECT COUNT(*) FROM kine').fetchone()[0])
print('max_id', c.execute('SELECT MAX(id) FROM kine').fetchone()[0])
print('compact_rev', c.execute(\"SELECT MAX(prev_revision) FROM kine WHERE name='compact_rev_key'\").fetchone()[0])
"

# datastore + WAL file sizes on disk
sudo ls -la /var/lib/rancher/k3s/server/db/

# Slow SQL rate in the last hour — compare against the ~30-90/hour baseline
journalctl -u k3s --since '1 hour ago' --no-pager | grep -c 'Slow SQL'

# has the online compactor made progress recently? silence across several 5-min windows
# means it has stalled
journalctl -u k3s --since '30 min ago' --no-pager | grep -E 'COMPACT compacted|Compact failed'

# k3s restart count and current state
systemctl show k3s -p ActiveState,NRestarts

# apiserver health directly
sudo k3s kubectl get --raw /healthz --request-timeout=10s
sudo k3s kubectl get --raw /readyz?verbose --request-timeout=10s
```

##### Temporary mitigation: apiserver etcd health-check timeout

If `/readyz`'s etcd check is failing purely because kine queries are momentarily slower than the
apiserver's default 2s health-check timeouts, a drop-in raising both to 20s buys time for the
online compactor to catch up (or for offline compaction to be scheduled) without the embedded
cloud-controller-manager panicking and restart-looping on a failed `/healthz`:

`/etc/rancher/k3s/config.yaml.d/90-incident-129-etcd-healthcheck.yaml`:
```yaml
kube-apiserver-arg:
  - "etcd-healthcheck-timeout=20s"
  - "etcd-readycheck-timeout=20s"
```

```bash
ssh raspi5 "sudo systemctl restart k3s --no-block"
```

**This drop-in is not in this repo and is not applied by any playbook.** It was created by hand
on raspi5 during the 2026-09-23 incident (mitigation 2, 17:09 CEST) and is still in place as of
this writing. Whether to codify it into `infra/roles/k3s` (as a template shipped to every server
node) or remove it now that compaction has caught up is an open decision tracked in
homelab#129 — do not add it to the k3s role from this section alone.

##### Offline compaction

When the online compactor cannot catch up on its own — stalled for days, or the backlog is large
enough that every 5-minute window's worth of batches still can't clear the 5s-timeout budget —
compact offline with k3s stopped, using `scripts/kine-offline-compact.sh` and
`scripts/kine-offline-compact.py`:

```bash
scp scripts/kine-offline-compact.py scripts/kine-offline-compact.sh raspi5:/tmp/
ssh raspi5
sudo /tmp/kine-offline-compact.sh --dry-run   # read-only preview first — k3s stays up
sudo /tmp/kine-offline-compact.sh             # full run: stop / backup / compact / start,
                                               # confirms before each stage
```

`kine-offline-compact.sh` stops k3s, checkpoints the WAL, takes a `cp -a` backup of `state.db`,
runs `kine-offline-compact.py` — the same `DELETE`/`UPDATE` kine's own compactor runs
(`pkg/drivers/sqlite/sqlite.go` `CompactSQL` + `pkg/drivers/generic/generic.go`
`UpdateCompactSQL`/`SetCompactRevision`), just in 50,000-row batches instead of kine's
1,000-row/5s-timeout online batches — followed by `VACUUM`, then starts k3s back up and waits for
`/healthz`. This is deliberately a from-scratch reimplementation of kine's compaction SQL
(verified against the kine v0.13.9 source, see the script's own header comment for the exact
file/field references and the verification-query semantics), not a call into kine itself —
kine only compacts through its own running process, which is exactly what's stopped here.

**API downtime:** the Kubernetes API is unavailable for the whole stop-to-start window.
Containers keep running throughout (`k3s.service` ships with `KillMode=process`) and public
endpoints (Traefik, Cloudflare Tunnel) stay up — only `kubectl`, controllers, and Flux
reconciliation are affected.

**Measured on 2026-09-23** (raspi5, 21:54-22:16 CEST): `state.db` 5.02 GB / 1,488,774 rows →
29.5 MB / 2,334 rows. The compaction step itself took 11 minutes (661s, 30 batches); total API
downtime was 22 minutes including the WAL checkpoint, backup copy, `VACUUM`, and the
restart/healthz wait. Post-run `PRAGMA integrity_check` was clean and all 4 nodes came back
`Ready`.

##### Rollback

The backup taken in the "backup" stage (`state.db.bak-<timestamp>`, written next to the live
`state.db`) is the only way back — the compaction step's `DELETE`s are not otherwise reversible.
If post-compaction verification looks wrong, or the cluster doesn't come back healthy, restore it
with k3s stopped:

```bash
ssh raspi5
sudo systemctl stop k3s
sudo cp -a /var/lib/rancher/k3s/server/db/state.db.bak-<timestamp> \
           /var/lib/rancher/k3s/server/db/state.db
sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal \
           /var/lib/rancher/k3s/server/db/state.db-shm
sudo systemctl start k3s --no-block
```

Keep the backup for at least 24 hours of stable operation after a successful run, then remove it
(`sudo rm /var/lib/rancher/k3s/server/db/state.db.bak-<timestamp>`) — like every kine/etcd
datastore copy, it contains every cluster Secret in plaintext.

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

Longhorn writes permanently to `/var/lib/longhorn` (root SD card on Pis). Since #64, the restic
repository — which lives on the same SD card — also ingests a ~710 MB k3s datastore copy every
day (deduplicated by restic; retention 7 daily / 4 weekly / 6 monthly), adding to the root-disk
pressure this section already tracks. `scripts/backup-app-data.sh` adds a transient consumer on
top: `influx backup` stages a full copy of the InfluxDB data (164 KB today — Longhorn's
`actualSize` of ~240 MB counts allocated replica blocks, not data) under `/tmp` inside the
`influxdb2` pod — the node's root disk — before it is streamed out and removed again.

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
takes a snapshot of every Longhorn volume in the `default` group once a day:

- **Schedule:** `0 2 * * *` (02:00 **node-local time** daily — one hour ahead of the existing
  03:00 restic backup cron so the two don't overlap; there is no functional dependency between
  them). Both run in the node's system timezone (`base_timezone: Europe/Zurich`, DST-aware), not
  UTC: Longhorn v1.7.2 doesn't set `spec.timeZone` on the `CronJob` it generates, so it follows
  k3s's embedded controller-manager, which inherits the host's local timezone — the same
  mechanism the restic cron (a plain crontab entry, also node-local) relies on.
- **Retention:** 7 snapshots per volume (Longhorn prunes older ones automatically).
- **Concurrency:** 1 (snapshots run one volume at a time).
- **Coverage:** `groups: [default]` — Longhorn applies a `default`-group job to every volume
  that has no more specific recurring-job/group assignment of its own. As of 2026-09-13 that
  covers 6 stateful volumes — the 5 `apps` volumes (`postgresql`, `influxdb2`, `mosquitto`,
  `n8n`, `open-webui`) plus the `monitoring` volume `grafana` — with no per-volume labeling
  required, and will automatically cover any future stateful volume the same way unless it's
  later opted into something more specific. The Prometheus TSDB volume opts out into the
  `metrics` group instead — see "Excluded volumes: the metrics group (#101)" below.

**This is a local snapshot, not an off-cluster backup:** snapshots live on the same physical
disks/replicas as the primary data (see the SD-card root-disk risk noted in
`cluster/values/longhorn.yaml`'s header comment), so this protects against logical mistakes
(bad config change, accidental deletion of *data within* a surviving volume) but not node/disk
hardware failure or a cluster-wide incident. It also does **not** protect against deleting the
PVC or Longhorn Volume itself — Longhorn's volume controller deletes a volume's associated
snapshots as part of tearing the volume down, so once the volume is gone, so are its local
snapshots; only a genuinely off-cluster copy can recover from that. That copy is made by hand
with `scripts/backup-app-data.sh` — see "App-data backups to the operator's Mac (#64)" below.
There is no Longhorn `BackupTarget`; the snapshots described here are local to the cluster's own
disks by design.

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

#### Excluded volumes: the metrics group (#101)

The Prometheus TSDB PVC
(`prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0`,
namespace `monitoring`, 20 Gi, retention 14 d) is excluded from `daily-snapshot`: its TSDB
rewrites blocks constantly, so the snapshot chain reached 46 G (7 snapshots = 40.7 G) and filled
raspi4's 58 G SD card, causing DiskPressure on 2026-09-11 — metrics are a 14-day cache, no
snapshot protection needed.

- **Mechanism:** `infra/playbooks/41_monitoring.yml` labels the PVC
  `recurring-job.longhorn.io/source=enabled` and `recurring-job-group.longhorn.io/metrics=enabled`.
  Longhorn syncs a PVC's recurring-job labels to its Volume, overriding the auto-added
  `recurring-job-group.longhorn.io/default` label (added only when a volume has no recurring-job
  label at all). When introducing a new group, apply `30_longhorn.yml` (creates the group's
  `RecurringJob`) before `41_monitoring.yml` (adds the labels) — labelling first leaves the
  volume in a group with no job behind it: still out of `default`, but nothing purges it and
  Longhorn never cleans up the dangling label.
- **Cleanup job:** group `metrics` carries one `RecurringJob`, `metrics-snapshot-cleanup`
  (`infra/playbooks/30_longhorn.yml`, task `snapshot-cleanup`, cron `0 4 * * *` node-local, retain
  0, concurrency 1) — purges removed/system snapshots (e.g. replica rebuilds) and keeps the
  group's labels backed by a real job. 04:00 is clear of the 02:00 snapshot window and the 03:00
  restic cron on raspi5.
- **Excluding another volume:** label its PVC the same way —
  `kubectl -n <ns> label pvc/<name> recurring-job.longhorn.io/source=enabled recurring-job-group.longhorn.io/metrics=enabled`
  — or add an equivalent task to the owning playbook. Longhorn syncs the Volume within about a
  minute; verify with
  `kubectl -n longhorn-system get volumes.longhorn.io <volume-name> -o jsonpath='{.metadata.labels}'`
  (`<volume-name>` is the PV name, not the PVC name — resolve it via the `jsonpath='{.spec.volumeName}'`
  recipe above; expect `recurring-job-group.longhorn.io/metrics: enabled`, no `default`).
  - Leaving `default` only stops *new* snapshots — it does not remove ones already taken
    (`retain` no longer applies once a volume is out of the group, and `snapshot-cleanup` only
    purges removed/system snapshots). Delete the leftover `daily-sn-*` Snapshot CRs: list them
    with
    `kubectl -n longhorn-system get snapshots.longhorn.io -o json | jq -r '.items[] | select(.spec.volume=="<volume-name>") | .metadata.name'`,
    delete each with `kubectl -n longhorn-system delete snapshots.longhorn.io <name>`. Before
    deleting, check the volume's health (`kubectl -n longhorn-system get volumes.longhorn.io
    <volume-name> -o jsonpath='{.status.robustness}'`, expect `healthy`) and free disk space on
    its replica nodes — a purge needs temporary space and can stall on a nearly full disk. Then
    wait for the engine's purge to finish before checking size:
    `kubectl -n longhorn-system get engines.longhorn.io -l longhornvolume=<volume-name> -o jsonpath='{.items[0].status.purgeStatus}'`
    — after a successful purge `actualSize` decreases substantially but can stay above the
    nominal size (the volume head keeps every block the filesystem ever wrote until a filesystem
    trim). This is how the Prometheus volume's pre-#101 chain (≈ 40 G) was removed, once.
- **Verify:**
  ```bash
  kubectl -n longhorn-system get recurringjobs.longhorn.io        # daily-snapshot + metrics-snapshot-cleanup
  kubectl -n monitoring get pvc <name> --show-labels
  kubectl -n longhorn-system get snapshots.longhorn.io -o json | jq '[.items[] | select(.spec.volume=="<volume-name>")] | length'
  ```
- **Warnings:**
  - Removing the labeling task from `41_monitoring.yml` does NOT remove the labels — clear them
    explicitly (`kubectl -n monitoring label pvc/<name> recurring-job-group.longhorn.io/metrics- recurring-job.longhorn.io/source-`).
  - Deleting the `metrics-snapshot-cleanup` CR strips the labels from PVC and Volume, silently
    returning the volume to `default`; recover by re-running `30_longhorn.yml` and
    `41_monitoring.yml`.
  - Re-run `41_monitoring.yml` after any recreation of the Prometheus PVC (restore,
    `volumeClaimTemplate` change) — labels don't survive it.
  - `--check` of `41_monitoring.yml` on a fresh cluster stops at the PVC wait for about 10
    minutes (60 × 10 s) before failing (expected, not a hang — the PVC only exists after the
    real Helm deploy).

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

**Node-level playbooks off-LAN (SSH jump config).** The forward above only serves playbooks whose
tasks run on localhost. Node-level playbooks (`10_base`, `20_k3s`, `30_longhorn`) SSH to the
nodes' LAN IPs and fail off-LAN with `UNREACHABLE`. Route them through the Cloudflare Access SSH
host with an SSH config that lives only in the operator's `~/.ssh` (not in this repo), e.g.
`~/.ssh/homelab-offlan.conf`:

```
Host 192.168.1.61
  HostName ssh.furchert.ch
  User ansible
  IdentityFile ~/.ssh/homelab
  ProxyCommand cloudflared access ssh --hostname %h
Host 192.168.1.*
  User ansible
  IdentityFile ~/.ssh/homelab
  StrictHostKeyChecking yes
  ProxyCommand ssh -i ~/.ssh/homelab -o ProxyCommand="cloudflared access ssh --hostname ssh.furchert.ch" -W %h:%p ansible@ssh.furchert.ch
```

```bash
cloudflared access login https://ssh.furchert.ch   # prerequisite: a valid Access login
ANSIBLE_SSH_ARGS="-F $HOME/.ssh/homelab-offlan.conf -o ControlMaster=auto -o ControlPersist=60s" \
  ansible-playbook infra/playbooks/10_base.yml --tags netmon_node
```

- raspi5 (`192.168.1.61`) has a direct entry because a jump through raspi5 to its own LAN IP
  timed out once. The other nodes jump through raspi5.
- `ANSIBLE_SSH_ARGS` replaces Ansible's default SSH arguments, so the `ControlMaster`/`ControlPersist`
  flags are passed again explicitly.
- `StrictHostKeyChecking yes` accepts only host keys already in `~/.ssh/known_hosts`. On-LAN Ansible runs record the nodes' LAN IPs there, and earlier `cloudflared` SSH use records `ssh.furchert.ch`. Add a missing key on the LAN first (`ssh ansible@<LAN IP>` once, then compare the fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the node). Never accept a first key over the tunnel.
- Keep the file private: `chmod 600 ~/.ssh/homelab-offlan.conf`.
- Verified on all four nodes on 2026-09-24 (with `accept-new` and existing known_hosts entries).

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
- `serviceMonitor/monitoring/data-service` → apps (job `data-service`, `/actuator/prometheus` — see "data-service NM-1: Cloudflare keys, scrape and alerts")
- `serviceMonitor/monitoring/coroot-node-agent` → monitoring (one target per gated node; none while the gate is closed)

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

**Backup alerting (#92):** three backup mechanisms exist and none of them alerted before this
change. The rules live in `cluster/values/kube-prometheus-stack.yaml` under
`additionalPrometheusRulesMap.homelab-backups` and reach Discord through the existing single
Alertmanager route. All four are `severity: warning`.

| Alert | Fires when | `for` |
|-------|-----------|-------|
| `ResticBackupFailed` | `homelab_backup_exit_code > 0` — the last run of `homelab-backup.sh` on raspi5 exited non-zero | 15m |
| `ResticBackupStale` | no successful restic run for more than 26 h, **or** the metric is absent entirely | 2h |
| `LonghornRecurringJobNotSucceeding` | a CronJob in `longhorn-system` that is older than 26 h has no successful run in the last 26 h (or never had one) | 1h |
| `LonghornRecurringJobMissing` | the `daily-snapshot` or `metrics-snapshot-cleanup` CronJob has disappeared | 1h |

**A failed Longhorn recurring-job run is deliberately *not* covered by a new rule** — the chart's
own `KubeJobFailed` (`kube_job_failed{namespace=~".*"} > 0`, `for: 15m`, warning) already fires for
`longhorn-system` and routes to the same receiver. A second rule would mean two Discord messages
for every failed run. Do not switch `KubeJobFailed` off via `defaultRules.disabled` without
replacing that coverage.

**Why the Longhorn rule is anchored on `kube_cronjob_created`:** kube-state-metrics only emits
`kube_cronjob_status_last_successful_time` once `.status.lastSuccessfulTime` is set, so a job that
has *never* succeeded has no series at all and a plain staleness comparison could never fire for
it. The rule therefore selects CronJobs created more than 26 h ago and subtracts those with a
recent success (`unless`), which also gives a newly created job a 26 h grace period. It is
namespace-wide, so a new Longhorn recurring job is covered without editing the rule.
26 h = the 24 h schedule plus DST slack (both crons are node-local, so the spring/autumn gaps are
23 h and 25 h) plus one evaluation cycle.

**restic metrics path:** `homelab-backup.sh` (`infra/roles/storage/tasks/main.yml`) writes
`homelab-backup.prom` into `/var/lib/node_exporter/textfile_collector` on every exit — success or
failure — via a temp file plus `mv`, so a scrape never sees a partial file. node-exporter reads
that directory read-only (`--collector.textfile.directory`, configured in
`cluster/values/kube-prometheus-stack.yaml`). The path is a contract between those two files and
`storage_textfile_collector_dir` in `infra/roles/storage/defaults/main.yml`; change them together
or the metric disappears and `ResticBackupStale` fires. The directory is created on **every** node
(by Ansible and by the DaemonSet's `hostPath: DirectoryOrCreate`), because node-exporter raises
`node_textfile_scrape_error=1` — the chart's `NodeTextFileCollectorScrapeError` alert — wherever
the configured directory is missing. A failed run carries the previous last-success timestamp
forward instead of erasing it; `0` means "never succeeded".

**Known blind spots:**
- A Longhorn recurring job that *silently skips* a detached volume still exits 0 and counts as a
  success (`filterVolumesForJob` logs a warning only). The weekly manual snapshot check in the
  maintenance checklist stays for that reason.
- The **Mac-side app-data dumps** (`scripts/backup-app-data.sh`) are not covered. The Mac is not a
  cluster node, so an automatic signal would need a new component (Pushgateway or an n8n check).
  It remains a manual monthly check — see the maintenance checklist.
- A lock collision (a manual run while the 03:00 cron holds the lock) exits before any metric is
  written, on purpose: the run holding the lock owns the metrics. A permanently stuck lock surfaces
  as `ResticBackupStale` after about 26 h.

**Rollout order (matters):** the `ResticBackupStale` rule has an `absent()` branch, and
`homelab-backup.sh` only writes its metric file when it runs. Apply in this order:

1. `ansible-playbook infra/playbooks/10_base.yml` — **all nodes**. Creates the textfile directory
   fleet-wide and installs the metric-writing script. node-exporter is not reading the directory
   yet at this point.
2. `ssh raspi5 "sudo /usr/local/bin/homelab-backup.sh"` — one manual run, so the `.prom` file
   exists before anything scrapes it.
3. `ansible-playbook infra/playbooks/41_monitoring.yml` — loads the rules and rolls the
   node-exporter DaemonSet on all 4 nodes.

In that order `absent()` is never true and no alert fires during the rollout. Running step 3
before step 2 leaves a gap that lasts until the next 03:00 cron — up to about 24 hours — during
which `ResticBackupStale` fires (correctly, in the sense that there is genuinely no evidence of a
successful backup). `for: 2h` softens that window but does not close it.

**Verify after a rollout:**

```bash
# the metric file on raspi5
ssh raspi5 "cat /var/lib/node_exporter/textfile_collector/homelab-backup.prom"

# no node reports a textfile scrape error (expect 4x 0)
# Prometheus: node_textfile_scrape_error

# the rules are loaded
kubectl -n monitoring get prometheusrule kube-prometheus-stack-homelab-backups
```

**`CPUThrottlingHigh` review (#68, following the 2026-08-28 auth-service/device-service CPU-limit
changes to 1000m):** 24h throttled-CFS-period ratios — `postgres-exporter` (in the `postgresql-0`
pod) **0.67**, the only container above the 25% alert threshold, at a `limits.cpu: 100m` against
~0.0016 cores average usage (classic scrape-burst-vs-tiny-quota pattern); `auth-service` 0.009 and
`device-service` 0.007 at their new 1000m limits — both already fine, no further tuning needed.
Decision: raised `postgres-exporter`'s `limits.cpu` to `250m` in `infra/playbooks/50_apps_infra.yml`
(`requests` unchanged); kept the alert itself (severity `info`, already excluded from paging by
`InfoInhibitor`) rather than tuning its expression — it was correctly identifying a genuinely
undersized CPU quota, not a false positive.

### coroot-node-agent (NM-2)

eBPF egress/east-west visibility for the network-monitoring Epic (#114). Contract:
`docs/060-network-monitoring.md` §6; issue #118. The agent is an **approved privileged workload**
in `monitoring` (`privileged: true`, `hostPID: true`, host mounts `/sys/fs/cgroup` read-only,
`/sys/kernel/tracing`, `/sys/kernel/debug`), metrics-only: it pushes nothing out of the cluster.

| Piece | Where |
|-------|-------|
| DaemonSet, headless Service, ServiceMonitor, NetworkPolicy (ingress only from Prometheus on TCP 80) | `cluster/monitoring/coroot-node-agent/`, applied by `41_monitoring.yml` (no Helm chart; the chart is stale) |
| Alert rules `NetmonNewExternalDestination`, `CorootNodeAgentDown` | `cluster/values/kube-prometheus-stack.yaml` → `additionalPrometheusRulesMap.homelab-netmon-egress` |
| Image | `ghcr.io/coroot/coroot-node-agent:1.35.10@sha256:…` (index digest in the manifest comment; bumped by hand) |
| Spike gate | node label `homelab.furchert.ch/coroot-node-agent=enabled`, managed by `41_monitoring.yml` from `coroot_node_agent_nodes` (default `[raspi5, mba1]` since the 2026-09-24 spike) |

**The gate.** The DaemonSet only schedules on labelled nodes. `41_monitoring.yml` labels exactly
the nodes in `coroot_node_agent_nodes` and **removes** the label from every other node, so the
play variable is the source of truth: nodes missing from the list lose the label on the next run.
Since the 2026-09-24 spike the default is `[raspi5, mba1]`. With an empty list
(`-e '{"coroot_node_agent_nodes": []}'`) the DaemonSet runs 0 pods and neither rule fires.

**Memory options (researched 2026-09-24 against the v1.35.10 source; none applied).** The startup
peak comes from TLS uprobe setup. For every new process the agent opens its executable, or its
libssl, and loads the full ELF symbol table (`ebpftracer/tls.go`, `elf.go`) to find Go TLS, Rust
TLS and OpenSSL functions. Large Go binaries such as k3s itself (`/system.slice/k3s*.service`) are
the likely main cost, which is not measured per binary. Upstream docs and the README list no flags for this, and the only relevant
flags are in `flags/flags*.go`:

| Option | Effect | Keeps `ip_to_fqdn`? | Verdict |
|---|---|---|---|
| `--disable-l7-tracing` | Skips all TLS uprobes and ELF parsing, and all L7 events | **No**: `ip_to_fqdn` comes from DNS L7 events | Not usable |
| `--container-denylist=<regex>` (e.g. `/system.slice/k3s.*`) | The agent ignores matching cgroups entirely: no ELF scan, but also no egress metrics for them | Yes, for the others | Possible if the owner accepts losing k3s/containerd egress (image pulls, Helm/Git fetches). Measure the effect first |
| `--instrumentation-delay` (default `30s`) | Delays TLS attach after a process starts | Yes | Spreads the work but does not shrink the peak. No benefit |
| Env `GOMEMLIMIT` (e.g. `600MiB`) | Go runtime soft limit, so the GC collects harder before the cgroup limit | Yes | Possible, but the risk is GC thrash if live heap during the scan really needs more. Would need its own measurement |
| `--max-fqdns-per-container` (default 50), `--min-container-age` (default `30s`) | Cardinality limits, not memory | Yes | Not relevant to the peak |
| `--go-heap-profiler`, Java/async-profiler flags | Only active with a profiles endpoint, which is not set | Yes | Already inert |

No flag is both clearly safe and memory-reducing, so this PR only sizes the resources.

**Kernel prerequisites** (read-only checks 2026-09-23, docs/060 §6.3): all four nodes have
`CONFIG_BPF_SYSCALL=y`, `CONFIG_BPF_JIT=y`, tracefs and debugfs mounted, and lockdown `none`.
The Pis (6.8.0-raspi) have BTF; mba1 (6.12.79-1-t2-noble) and mba2 (6.19.10-2-t2-noble) do not
(`CONFIG_DEBUG_INFO_NONE=y`). coroot-node-agent ships precompiled programs, so BTF is not
required; the spike on mba1 is what proves that.

**Residual risk: unauthenticated pprof.** The agent registers Go's `/debug/pprof/*` on the same
`:80` listener as `/metrics`, and v1.35.10 has no flag to turn it off. The NetworkPolicy admits
only Prometheus from the pod network, but Kubernetes always admits traffic from the pod's own node.
Host processes and hostNetwork pods on an agent node can therefore still fetch profiles and heap
dumps, or burn CPU with `/debug/pprof/profile?seconds=N`. That includes Home Assistant, which has
`hostNetwork: true` and no node pin. Before the all-node rollout the owner decides between:
- accepting this for the homelab, since those sources already share the node;
- a `/metrics`-only reverse-proxy sidecar with the agent bound to `127.0.0.1`, which adds a new pinned image and needs approval;
- an upstream request for a disable flag.

#### Spike runbook (needs the owner's go — docs/060 §12 Q4)

1. **Baseline** (Prometheus port-forward, see "Access" above): record `prometheus_tsdb_head_series`
   (108 985 on 2026-09-23) and note which nodes host furchert-ch, a flux controller and litellm
   (`kubectl get pods -A -o wide`). Criterion 3 needs those flows on the spiked nodes.
2. **Open the gate on raspi5 only:**
   ```bash
   ansible-playbook infra/playbooks/41_monitoring.yml -e '{"coroot_node_agent_nodes": ["raspi5"]}'
   ```
   Lightweight alternative without the Helm upgrade (the rules then arrive with the next 41 run):
   ```bash
   kubectl apply -k cluster/monitoring/coroot-node-agent
   kubectl label node raspi5 homelab.furchert.ch/coroot-node-agent=enabled
   ```
3. **Smoke check** (first 10 min):
   ```bash
   kubectl -n monitoring get pods -l app.kubernetes.io/name=coroot-node-agent -o wide
   kubectl -n monitoring logs ds/coroot-node-agent | head -50   # expect "using /run/k3s/containerd/containerd.sock", no BPF load errors
   # on the spiked node itself:
   sudo journalctl -k --since "-15 min" | grep -iE "bpf|verifier" || echo none
   ```
   Prometheus → Targets must show `serviceMonitor/monitoring/coroot-node-agent/0` UP. raspi5 is
   the only control-plane node (kine incident #129): abort (step 7) if `kubectl get --raw /readyz`
   turns slow or the node's load climbs noticeably.
4. **Measure for ≥ 24 h** and record the numbers in the NM-2 worklog (criteria from docs/060 §6.3):

   | # | PromQL | Pass |
   |---|--------|------|
   | 2 | `kube_pod_container_status_restarts_total{namespace="monitoring", container="coroot-node-agent"}` and `kube_pod_container_status_last_terminated_reason{container="coroot-node-agent", reason="OOMKilled"}` | 0 restarts, no OOMKilled |
   | 3 | `group by (container_id, actual_destination) (container_net_tcp_successful_connects_total)` and `ip_to_fqdn` | ≥ 3 known flows with a non-empty `actual_destination`; external IPs have an FQDN |
   | 4 | `scrape_samples_post_metric_relabeling{job="coroot-node-agent"}` | < 5 000 per agent |
   | 5 | CPU: `avg_over_time(rate(container_cpu_usage_seconds_total{namespace="monitoring", container="coroot-node-agent"}[5m])[24h:5m])`, `quantile_over_time(0.95, rate(container_cpu_usage_seconds_total{namespace="monitoring", container="coroot-node-agent"}[5m])[24h:5m])`. Steady memory (the p95 over 24 h ignores the startup spike, which lasts minutes): `quantile_over_time(0.95, container_memory_rss{namespace="monitoring", container="coroot-node-agent"}[24h])`, `quantile_over_time(0.95, container_memory_working_set_bytes{namespace="monitoring", container="coroot-node-agent"}[24h])`. Startup peak, checked separately: `max_over_time(container_memory_working_set_bytes{namespace="monitoring", container="coroot-node-agent"}[24h])` against the limit `kube_pod_container_resource_limits{namespace="monitoring", container="coroot-node-agent", resource="memory"}` | avg < 100m, p95 < 250m; RSS p95 < 150 MiB, working-set p95 < 450 MiB; startup peak < memory limit (and no OOMKilled, row 2) |
   | 6 | `prometheus_tsdb_head_series` | < +10 % over the baseline |
   | 7 | `count by (container_id) (container_net_tcp_active_connections)` | record the `container_id` format (expected `/k8s/<ns>/<pod>/<container>`) |
   | — | `prometheus_rule_group_last_duration_seconds{rule_group=~".*homelab-netmon-egress.*"}` | < 1 s (the group runs every 5 min) |

   `scrape_samples_scraped{job="coroot-node-agent"}` shows the pre-relabel size, for information only;
   `sampleLimit` (10 000) is counted after the keep-list.
5. **Add mba1** (no BTF): repeat steps 2–4 with `-e '{"coroot_node_agent_nodes": ["raspi5", "mba1"]}'`
   (or `kubectl label node mba1 …`). Every criterion must hold on both nodes.

   **Result (2026-09-24, from 11:52):** raspi5 and mba1 are now the playbook default.

   | Measure | raspi5 | mba1 |
   |---|---|---|
   | First start at a 384Mi limit | OOMKilled, working-set peak 410 MiB | OOMKilled, peak 702 MiB |
   | Restarts at 768Mi (temporary `kubectl set resources`), 2 h+ | 0 | 0 |
   | Series after relabeling | 161 | 771 |
   | CPU | 0.02 cores | 0.05 cores |
   | Working set steady (2 h band) | 320 MiB (313–327) | 399 MiB (370–420) |
   | RSS steady | 69 MiB | 105 MiB |

   eBPF works on mba1's t2 kernel. No alerts fired, and 285 connect series plus 12 `ip_to_fqdn`
   series flow. The working set is mostly reclaimable page cache from reading container binaries.
   The manifest now requests 256Mi and limits at 1Gi, which leaves margin above the 702 MiB startup
   peak. The next `41_monitoring.yml` run replaces the temporary 768Mi `kubectl set resources` drift.
6. **Record and roll out.** Update docs/060 §3.3/§4.6 with the observed `container_id` format and
   metric labels. Extend the rollout one node at a time, each with the owner's go, a PR adding the
   node to `coroot_node_agent_nodes` in `41_monitoring.yml`, a `41_monitoring.yml` run, and steps 3–4:
   first **mba2**, whose t2 kernel (6.19) differs from mba1's (6.12), then **raspi4**, which has
   only 4 GB RAM and about 2 GB available.
7. **Rollback.**
   - *Stop the agent, keep everything else:* run `41_monitoring.yml` with
     `-e '{"coroot_node_agent_nodes": []}'` (the gate closes and the pods terminate), or
     `kubectl label node --all homelab.furchert.ch/coroot-node-agent-`. The label is restored on the next
     run without the override.
     No alert fires in this state.
   - *Remove it entirely:* revert the NM-2 PR and run `41_monitoring.yml` (removes the rule group),
     then `kubectl delete -k cluster/monitoring/coroot-node-agent` from a checkout that still has the
     directory, and remove the node labels as above. Deleting the DaemonSet while the rules are still
     loaded fires `CorootNodeAgentDown` after 10 min.
   - *If criteria 1–3 fail on the Macs:* keep the agent on the Pis only and use the conntrack
     fallback (docs/060 §6.6) for mba1/mba2; if they fail on the Pis too, use the full fallback.

**Alerts.** `NetmonNewExternalDestination` (`info`) fires for 15 min when a workload opens a TCP
connection to an external `ip:port` not seen in the previous 24 h. It groups by `workload`
(the pod-name hash stripped from `container_id`) so Flux rollouts do not re-report known
destinations. Because of the chart's `InfoInhibitor` it is normally visible in Alertmanager/Prometheus
without reaching Discord; raising it to `warning` is a tuning decision after the spike (expect noise
from CDN-rotating destinations). `CorootNodeAgentDown` (`warning`, 10 min) fires when the DaemonSet
is missing (also while kube-state-metrics is down) or fewer agents are scraped successfully than are available; crash loops, stuck rollouts
and failed scrapes are also covered by the chart's `KubePodCrashLooping`, `KubeDaemonSetRolloutStuck`
and `TargetDown`.

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

### data-service (Flux, NM-0 onboarding)

NM-0 onboarding completed 2026-09-23 (homelab#126, homelab-data-service#18, homelab-auth-service#95).

data-service is Flux-managed like auth-service/device-service (`cluster/apps/data-service/`), and uses its own Postgres DB `data_service` (role `data_service`, schema `netmon` created by its Flyway) plus the Secret `data-service-secrets`, both from `59_app_services.yml`. Contract: `docs/060-network-monitoring.md` §9; ownership: ADR 0002 (parent `docs/adr/0002-network-telemetry-ownership.md`). No public tunnel route — do not add it to `cf_ingress_body`.

#### Order (first rollout)

1. `homelab-data-service` NM-0 PR merged: `k8s/` exists on `main` and CI has pushed a first image `ghcr.io/doemefu/homelab-data-service:main-<YYYYMMDDTHHMMSS>`.
2. Owner prerequisites below (deploy key, GHCR visibility, ruleset check, SOPS variable).
3. The infra PR with `cluster/apps/data-service/` + the playbook-59 tasks is merged.
4. Run playbook 59 right after the merge (creates DB, role and Secret).
5. Flux reconciles (`apps` Kustomization, interval 10 min) or force it. A pod that starts before step 4 sits in `CreateContainerConfigError` and recovers by itself once the Secret exists.

#### Owner prerequisites

```bash
# (a) SOPS variable (NM-0) — value e.g. from: openssl rand -hex 24
sops infra/inventory/group_vars/all.sops.yml     # add: data_service_db_password: "<value>"

# (b) Flux deploy key with WRITE access (image-automation pushes tag bumps to main).
#     flux generates the key pair in-cluster; only the PUBLIC key leaves the cluster.
flux create secret git data-service-flux-auth -n flux-system \
  --url=ssh://git@github.com/doemefu/homelab-data-service \
  --ssh-key-algorithm=ed25519
kubectl -n flux-system get secret data-service-flux-auth \
  -o jsonpath='{.data.identity\.pub}' | base64 -d > /tmp/flux-data-service.pub
gh repo deploy-key add /tmp/flux-data-service.pub -R doemefu/homelab-data-service \
  --title flux-data-service --allow-write
rm /tmp/flux-data-service.pub

# (c) GHCR visibility: new packages default to private. Siblings are public and their
#     ImageRepository has no secretRef — make this one public after the first push:
#     https://github.com/users/doemefu/packages/container/homelab-data-service/settings
#     → Danger Zone → Change visibility → Public.
#     Alternative: keep it private. That needs TWO credentials, because ghcr-auth in
#     flux-system only lets Flux scan tags — it gives the Pod in apps nothing to pull with:
#       1. ghcr-auth in flux-system (see the comment in cluster/apps/data-service/imagerepo.yaml)
#          and uncomment its secretRef;
#       2. a docker-registry Secret in apps (same command with -n apps, e.g. name ghcr-pull)
#          plus `imagePullSecrets: [{name: ghcr-pull}]` in homelab-data-service's
#          k8s/deployment.yaml (app repo change). Without 2 the rollout ends in ImagePullBackOff.

# (d) Branch ruleset: the Flux push to main must not be blocked. Mirror the
#     device-service ruleset (rules deletion, non_fast_forward, copilot_code_review,
#     code_scanning, code_quality; bypass = Admin role; NO pull_request rule).
gh api repos/doemefu/homelab-data-service/rulesets --jq '.[] | "\(.id) \(.name) \(.enforcement)"'
#     If a ruleset requires pull requests, add the deploy key as a bypass actor
#     (actor_type "DeployKey") or drop that rule.
```

#### Apply and verify

```bash
# Playbook 59 (after the infra PR merge); a second run must report changed=0
ansible-playbook infra/playbooks/59_app_services.yml

kubectl -n apps get secret data-service-secrets
kubectl -n apps exec postgresql-0 -- psql -U postgres -tc \
  "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname='data_service'"

flux reconcile kustomization apps -n flux-system --with-source
flux get sources git data-service -n flux-system
flux get image repository data-service -n flux-system
flux get kustomizations data-service -n flux-system
kubectl -n apps get pods -l app=data-service
```

**Troubleshooting:** while the k3s datastore is slow (incident #129), playbook 59's Secret task can fail with HTTP 500 `resource quota evaluation timed out`. Nothing is half-applied in that case — rerun the playbook once the control plane is healthy again (`kubectl get --raw=/readyz` returns `ok` quickly).

Backups need no change: `scripts/backup-app-data.sh` reads the database list at runtime, so `data_service` is dumped automatically.

### data-service NM-1: Cloudflare keys, scrape and alerts

NM-1 (#116) adds the Cloudflare GraphQL Analytics credentials to `data-service-secrets`, a ServiceMonitor for data-service and the `homelab-netmon` alert rules. Contract: `docs/060-network-monitoring.md` §4.1, §4.2, §7.1, §9.

| Piece | Where | Names |
|-------|-------|-------|
| SOPS variables (owner) | `infra/inventory/group_vars/all.sops.yml` | `data_service_cloudflare_analytics_token` (zone `furchert.ch`, Analytics:Read), `data_service_cloudflare_zone_id` |
| Secret keys | `59_app_services.yml` → `apps/data-service-secrets` | `cloudflare-api-token`, `cloudflare-zone-id` (read by data-service as `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ZONE_ID`) |
| Scrape | `41_monitoring.yml` → `monitoring/data-service` ServiceMonitor | port `http`, `/actuator/prometheus`, 30 s, job `data-service` |
| Alerts | `cluster/values/kube-prometheus-stack.yaml` → PrometheusRule `monitoring/kube-prometheus-stack-homelab-netmon` | `NetmonCollectorStale`, `NetmonDataServiceDown` |

#### Rollout order (NM-1)

The PRs merge in this order: **homelab#116 → homelab-data-service#14 → furchert-ch#61**.

1. Merge this infra PR, then run playbook 59 **twice**. The first run adds the two keys to the Secret. The second run must report no change for the Secret task (the other data-service tasks keep their NM-0 behaviour).
2. Restart data-service so the running pod picks up the new env vars (`optional: true` secretKeyRefs are resolved only at pod start). Skip this when data-service#14's image rollout follows right away — that rollout restarts the pod anyway.
3. Run playbook 41. It applies the ServiceMonitor and loads the rules in one run, so the `absent()` branch of `NetmonDataServiceDown` never sees a scrape gap. data-service is already running since NM-0, so this step can happen before data-service#14.
4. Merge data-service#14 (collectors), then furchert-ch#61 (UI).

```bash
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml   # second run: no change for the Secret task
kubectl -n apps get secret data-service-secrets -o json | jq '.data | keys'
# expect: cloudflare-api-token, cloudflare-zone-id, db-password, db-username
kubectl -n apps rollout restart deploy/data-service     # only if no data-service image rollout follows
ansible-playbook infra/playbooks/41_monitoring.yml
```

#### Verify the scrape and the rules

```bash
kubectl -n monitoring get servicemonitor data-service
kubectl -n monitoring get prometheusrule kube-prometheus-stack-homelab-netmon
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=up{job="data-service"}' | jq '.data.result'
# expect value "1"
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=netmon_collector_last_success_timestamp_seconds' | jq '.data.result[] | {c: .metric.collector, v: .value[1]}'
curl -s 'http://localhost:9090/api/v1/rules' | jq '.data.groups[] | select(.name=="homelab-netmon") | .rules[].name'
```

#### Alert runbook

**`NetmonCollectorStale`** (warning, `for: 10m`) fires per `collector` label. It fires when the collector's last success is older than its threshold. It also fires when the gauge is NaN, meaning the collector never succeeded, and the Pod is older than the threshold. Pod age comes from kube-state-metrics (`kube_pod_start_time`), so a container restart inside the same Pod does not reset the grace period. The `threshold` label shows the class:

| Threshold | Collectors | Cadence (§4.1) |
|-----------|------------|----------------|
| `26h` | `blocklists`, `retention` | daily |
| `3h` | `egress` | hourly |
| `90m` | `lan`, `reputation` | 15 min / 30 min |
| `15m` | every other collector: `cloudflare-requests`, `cloudflare-firewall`, `login-events`, and any collector not listed | 5 min / 1 min |

1. Check `GET /api/netmon/status` through furchert-ch `/dashboard/network`, or the data-service logs (`kubectl -n apps logs deploy/data-service`). `lastError` and `consecutiveFailures` name the cause. data-service never logs tokens.
2. `credentials` on a Cloudflare collector means the token has expired or was revoked. Create a new token (zone `furchert.ch`, Analytics:Read), update `data_service_cloudflare_analytics_token` in SOPS, run playbook 59 and restart data-service.
3. A collector added in data-service without its own class falls into the `15m` class. If its cadence is slower, add a class to the rules in `cluster/values/kube-prometheus-stack.yaml`.
4. A collector that is disabled (`netmon.collectors.<name>.enabled=false`) must not export the gauge. If one stays NaN forever, that is a data-service bug, not an outage.

**`NetmonDataServiceDown`** (warning, `for: 10m`) fires when Prometheus cannot scrape data-service, or has no target for it at all. Check `kubectl -n apps get pods -l app=data-service`, `flux get kustomizations data-service -n flux-system` and `kubectl -n monitoring get servicemonitor data-service`. The alert also fires during a planned scale-to-0 or Flux suspend, so silence it in Alertmanager for planned downtime.

### NM-4: login-event secrets (auth-service → data-service)

NM-4 (#134) adds the secrets for the login-event pipeline: auth-service records form logins in an outbox, and data-service pulls them with its own client (`data-service`, scope `login-events:read`). Contract: `docs/060-network-monitoring.md` §7.6, §9.

| Piece | Where | Names |
|-------|-------|-------|
| SOPS variables (owner, optional) | `infra/inventory/group_vars/all.sops.yml` | `auth_service_data_service_client_secret` (plain, e.g. `openssl rand -hex 32`), `auth_service_login_event_hmac_key` (at least 32 characters, e.g. `openssl rand -base64 48`) |
| auth-service keys | `59_app_services.yml` → `apps/homelab-auth-secrets` | `data-service-client-secret` (`{noop}<value>`, env `DATA_SERVICE_CLIENT_SECRET`), `login-event-hmac-key` (env `LOGIN_EVENT_HMAC_KEY`) |
| data-service key | `59_app_services.yml` → `apps/data-service-secrets` | `auth-client-secret` (plain `<value>`, env `AUTH_CLIENT_SECRET`) |

Both variables are optional. With neither, playbook 59 skips the three keys and prints a note. With only one, a key shorter than 32 characters, or a client secret that already starts with `{` (such as `{noop}`), the playbook fails. auth-service wires both env vars with `optional: true`, so it starts without them, keeps login-event capture off, answers 503 on `/api/v1/login-events` and logs one WARN. The auth-service PR (homelab-auth-service#94) can therefore merge before the keys exist.

#### Enable order (NM-4)

1. Owner: add both SOPS variables (`sops infra/inventory/group_vars/all.sops.yml`).
2. Run playbook 59 **twice**. The first run adds the keys. The second run must report no change for the Secret tasks.
3. Restart auth-service so the pod reads the new env vars. On startup it seeds the `data-service` client and logs `Login-event outbox enabled`.
4. Merge the data-service PR (homelab-data-service#17), then restart data-service if its image rollout does not follow right away (`AUTH_CLIENT_SECRET` is read at pod start).
5. Merge the furchert-ch PR (furchert-ch#64).

```bash
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml   # second run: no change for the Secret tasks
kubectl -n apps get secret homelab-auth-secrets -o json | jq '.data | keys'
# expect data-service-client-secret and login-event-hmac-key next to the existing keys
kubectl -n apps get secret data-service-secrets -o json | jq '.data | keys'
# expect auth-client-secret next to the existing keys
kubectl -n apps rollout restart deploy/auth-service
kubectl -n apps rollout status deploy/auth-service
kubectl -n apps logs deploy/auth-service | grep -i 'login-event'
# expect "Login-event outbox enabled (consumer client 'data-service')"; a WARN "disabled" names the missing variable
```

**Turning NM-4 off.** Removing the two SOPS variables does not remove the keys: playbook 59 then skips the NM-4 tasks, and its other Secret tasks patch the Secrets without deleting unknown keys. Remove the keys by hand, then restart both services:

```bash
kubectl -n apps patch secret homelab-auth-secrets --type=json \
  -p='[{"op":"remove","path":"/data/data-service-client-secret"},{"op":"remove","path":"/data/login-event-hmac-key"}]'
kubectl -n apps patch secret data-service-secrets --type=json \
  -p='[{"op":"remove","path":"/data/auth-client-secret"}]'
kubectl -n apps rollout restart deploy/auth-service deploy/data-service
```

auth-service then logs the "disabled" WARN and answers 503. The seeded `data-service` row in `oauth2_registered_client` stays until it is deleted there.

**Rotation.** `auth_service_login_event_hmac_key`: rotating it breaks HMAC continuity for login events already stored in data-service, so avoid it. `auth_service_data_service_client_secret`: auth-service seeds a client only once and never updates it, so a new SOPS value plus playbook 59 is not enough. Also update the `data-service` row in `oauth2_registered_client` (see homelab-auth-service `INTERFACES.md` §6), then restart auth-service and data-service.

---

### Network monitoring: node LAN metrics (NM-3)

Role `netmon_node` (`10_base.yml`, tag `netmon_node`, all nodes) installs the apt package `conntrack`, the Python 3 stdlib script `/usr/local/sbin/homelab-netmon-collect` and `homelab-netmon.service` (oneshot, root) + `homelab-netmon.timer` (every minute at :05). Each run writes `/var/lib/node_exporter/textfile_collector/homelab_netmon.prom` atomically; node-exporter exposes it on `:9100`, Prometheus keeps it 14 d as transport, and data-service snapshots it into `netmon` (docs/060 §4.6). Contract (names, labels, bucket semantics, cardinality cap): `docs/060-network-monitoring.md` §5.

| Metric | Meaning |
|--------|---------|
| `homelab_lan_connections{node,dport,src_ip,state}` | current conntrack TCP entries to ports 1883, 22, 8123, 6443, 10250 (the node's own outbound flows excluded) |
| `homelab_ufw_blocks_bucket{node,src_ip,dport,proto}` | `[UFW BLOCK]` kernel log lines in the last completed 15-min bucket — a lower bound, UFW logging is rate-limited |
| `homelab_sshd_auth_bucket{node,src_ip,outcome}` | sshd `accepted` / `failed` / `invalid_user` in the same bucket (disjoint; `failed` is a lower bound); usernames are never emitted |
| `homelab_netmon_bucket_end_timestamp_seconds{node}` | end (exclusive) of the bucket the two `*_bucket` gauges describe |
| `homelab_netmon_last_success_timestamp_seconds{node}` | last successful run → alert `NetmonNodeScriptStale` (> 10 min, warning) |
| `homelab_netmon_truncated_series{node,metric}` | series folded into `src_ip="other"` by the cap `netmon_node_max_series` (200) → alert `NetmonSeriesTruncated` (info) |

**Dependency: homelab PR #109.** node-exporter's `--collector.textfile.directory` + hostPath (kube-prometheus-stack values) come from #109; merge #109 first. The textfile directory itself is created by this role and by #109's storage role with identical attributes, so the file is written even before #109 — it is just not scraped yet. Conntrack data is IPv4 only. The alert rules sit in `additionalPrometheusRulesMap.homelab-netmon-node` and need `41_monitoring.yml`.

#### Rollout

```bash
# 1. After #109 (storage role + 41_monitoring.yml) and this PR are merged.
#    One node first; --diff is safe (no secrets in these templates).
#    Off-LAN: prefix each command with ANSIBLE_SSH_ARGS=… (see "Off-LAN kubectl / Ansible Access").
ansible-playbook infra/playbooks/10_base.yml -l raspi5 --tags netmon_node --check --diff
ansible-playbook infra/playbooks/10_base.yml -l raspi5 --tags netmon_node
ansible-playbook infra/playbooks/10_base.yml --tags netmon_node          # all nodes
ansible-playbook infra/playbooks/10_base.yml --tags netmon_node          # 2nd run: changed=0

# 2. Alert rules (homelab-netmon-node PrometheusRule)
ansible-playbook infra/playbooks/41_monitoring.yml
```

#### Verify

```bash
ssh ansible@<node-ip> "systemctl list-timers homelab-netmon.timer --all"
ssh ansible@<node-ip> "sudo systemd-analyze verify /etc/systemd/system/homelab-netmon.service"
ssh ansible@<node-ip> "sudo systemctl start homelab-netmon.service; systemctl status homelab-netmon.service --no-pager | head -5"
ssh ansible@<node-ip> "cat /var/lib/node_exporter/textfile_collector/homelab_netmon.prom"
curl -s http://<node-ip>:9100/metrics | grep '^homelab_'          # from the LAN (UFW allows 9100)
curl -s http://<node-ip>:9100/metrics | grep '^node_textfile_scrape_error'   # expect 0
# sshd really logs under unit "ssh" (docs/060 §12 unverified item)
ssh ansible@<node-ip> "sudo journalctl -u ssh --since -1h -o cat | grep -c -E '^(Accepted|Failed|Invalid user)'"
kubectl -n monitoring get prometheusrule | grep homelab-netmon-node
```

Series per node must stay under the cap (`count by (node) ({__name__=~"homelab_(lan_connections|ufw_blocks_bucket|sshd_auth_bucket)"})`). Tunnelled SSH (`ssh.furchert.ch`) shows up with the cloudflared pod or node IP as source, not the real client.

#### Troubleshooting

- **`NetmonNodeScriptStale`**: `journalctl -u homelab-netmon -n 20` on the node. `CalledProcessError` = conntrack, ip or journalctl failed; `FileNotFoundError` = textfile directory missing (re-run `10_base.yml --tags netmon_node`).
- **Metric has `exported_node` instead of `node`**: would mean the node-exporter ServiceMonitor stopped honouring labels (`honorLabels: true` in chart 69.3.1); data-service's queries rely on `node`.
- **Unit tests** (stdlib only, run before changing the script): `python3 -m unittest discover -s infra/roles/netmon_node/tests -v`.
- **`nf_conntrack_acct`** stays at the kernel default; `netmon_node_conntrack_acct: true` is reserved for the NM-2 fallback (docs/060 §5.5/§6.6).

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

`scripts/backup-app-data.sh` runs every component procedure below in one go and uses its own
directory convention (`backups/<YYYY-MM-DD_HHMMSS>/`, retained automatically) — see
"App-data backups to the operator's Mac (#64)" at the end of this section. Use the
per-component blocks below for targeted, one-off backups and for every restore.

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
- **InfluxDB restore** (`influxdb2-backup.tgz` from an app-data run): copy the archive into the
  pod, unpack it and restore in place:
  ```bash
  kubectl -n apps cp ~/informatik/homelab/backups/<run>/influxdb2-backup.tgz influxdb2-0:/tmp/influxdb2-backup.tgz
  kubectl -n apps exec influxdb2-0 -- sh -c 'rm -rf /tmp/influx-backup && tar xzf /tmp/influxdb2-backup.tgz -C /tmp'
  kubectl -n apps exec influxdb2-0 -- sh -c 'influx restore /tmp/influx-backup --full --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN"'
  # only one bucket, leaving the token/user store untouched:
  # kubectl -n apps exec influxdb2-0 -- sh -c 'influx restore /tmp/influx-backup --bucket iot-bucket --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN"'
  kubectl -n apps exec influxdb2-0 -- rm -rf /tmp/influx-backup /tmp/influxdb2-backup.tgz
  ```
  `--full` replaces the token and user store too, so afterwards re-check that the admin token
  device-service uses still works (restart it and watch its logs); prefer `--bucket` when only
  measurement data has to come back.
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

#### App-data backups to the operator's Mac (#64)

`scripts/backup-app-data.sh` runs every per-component procedure above in one pass and writes the
result to the operator's Mac, outside the cluster. It is the homelab's off-cluster copy of the
application data; the per-component blocks above remain the reference for targeted one-off
backups and for every restore.

**What it produces** — one directory per run:

| Component | Artifacts | Consistency |
|-----------|-----------|-------------|
| `postgresql` | `pg-dumpall.sql.gz` plus one `pg-<db>.dump` per database — the list comes from the server at run time (today: `homelabdb`, `n8n`, `litellm`, `club_assistant`) | application-consistent (`pg_dumpall --clean --if-exists`, `pg_dump -Fc`) |
| `influxdb2` | `influxdb2-backup.tgz` | application-consistent (`influx backup`); the run fails if a shard directory on disk has no matching shard archive |
| `n8n` | `n8n-workflows.json`, `n8n-credentials.json`, `n8n-data.tgz` | exports application-consistent; PVC archive crash-consistent unless `--quiesce` |
| `open-webui` | `open-webui-data.tgz` | crash-consistent unless `--quiesce` |
| `mosquitto` | `mosquitto.db` | flushed with `kill -USR1` before copying |
| `grafana` | `grafana-data.tgz` | crash-consistent |

Plus `MANIFEST.txt` (run metadata and one row per artifact) and `SHA256SUMS`.

`n8n-credentials.json` is exported **encrypted** (never `--decrypted`): restoring it requires the
same `N8N_ENCRYPTION_KEY` from the `n8n-secrets` Secret (SOPS). Do not rotate that key between
backup and restore.

**How to run** — from this repo on the Mac:

```bash
./scripts/backup-app-data.sh --help                # all options
./scripts/backup-app-data.sh --dry-run             # resolve + print, change nothing
./scripts/backup-app-data.sh                       # every component
./scripts/backup-app-data.sh --quiesce             # scale n8n + open-webui to 0 while tarring
./scripts/backup-app-data.sh --only postgresql --only influxdb2
./scripts/backup-app-data.sh --context tunnel --only postgresql   # off-LAN, small components
```

Run it **on the LAN**. `n8n-data.tgz` and `open-webui-data.tgz` are hundreds of megabytes to a
few gigabytes streamed through `kubectl exec`; pushing that through the Cloudflare Tunnel
port-forward has timed out before (see "Off-LAN kubectl / Ansible Access"). Off-LAN, combine
`--context tunnel` with `--only` for the small components.

`--quiesce` scales `open-webui` and `n8n` to 0 replicas for the duration of their PVC archive and
always scales them back to the previous replica count — on success, on failure and on Ctrl-C.
Both store SQLite databases, so without it those two archives are only crash-consistent.

**Where it lands:** `~/informatik/homelab/backups/<YYYY-MM-DD_HHMMSS>/` (override
with `--dest`). That folder is the parent workspace directory, outside every git repo — the
dumps contain credentials and PII and must never be committed or uploaded. Run directories are
created mode 700 and artifacts mode 600. `--retain N` (default 5) deletes the oldest run
directories after a successful run; it only ever considers directories whose name matches
`YYYY-MM-DD_HHMMSS` **and** that contain `SHA256SUMS`, so anything else in the folder (for
example `backups/restic/`) is never touched, and pruning is skipped entirely when the run had a
failure. A run that was interrupted (Ctrl-C, crash, aborted stream) is renamed to
`<run>.incomplete` instead of being deleted; those are never counted or pruned — check and
remove them by hand.

**What this does not do:**

- **Not off-site.** The Mac sits in the same flat as the cluster — a fire, flood or burglary
  takes both.
- **It does not replace Longhorn's snapshots.** The `daily-snapshot` RecurringJob (02:00, retain
  7, see "Recurring Snapshots (#63)") stays the fast whole-volume rollback path, but it is local
  to the cluster's own disks.
- **There is no Longhorn `BackupTarget`.** Longhorn 1.7.2 mounts NFS backupstores as NFSv4 only
  (its vendored `backupstore/nfs/nfs.go` mounts with fstype `nfs4`, minor versions 4.2/4.1/4.0)
  and macOS ships no NFSv4 server; no cloud target is wanted (owner decision, 2026-09-08). These
  dumps are the off-cluster copy instead.
- **Kubernetes objects are not dumped here.** restic on raspi5 covers `/etc/rancher/k3s`, the
  server token and a consistent copy of the k3s SQLite datastore — see "Backup (Restic)".

**Verification.** The script verifies every artifact itself (gzip/tar readability, the `PGDMP`
magic for custom-format dumps, non-empty size), deletes anything that fails verification, and
exits non-zero if any component failed. The first real run is also its acceptance test: check
`ls -l "$RUN"` for plausible sizes and open `n8n-workflows.json` to confirm the export really
contains every workflow. To re-check an existing run directory:

```bash
RUN=~/informatik/homelab/backups/<YYYY-MM-DD_HHMMSS>
cat "$RUN/MANIFEST.txt"                        # every row must read OK
(cd "$RUN" && shasum -a 256 -c SHA256SUMS)     # every line must read OK
gzip -t "$RUN/pg-dumpall.sql.gz"
tar -tzf "$RUN/n8n-data.tgz" >/dev/null
```

**First run 2026-09-08.** The first full run took ~7 minutes on the LAN (21:58:09–22:04:53 CEST,
exit 0, no `--quiesce`) and produced 12 artifacts totalling ≈ 2.2 GB, all `OK` in `MANIFEST.txt`
and 13/13 in `shasum -a 256 -c SHA256SUMS`. A small `influxdb2-backup.tgz` (7.8 KB) is normal
while `iot-bucket` is nearly empty; the script fails if a shard on disk is missing from the
backup, and `influx backup`'s "Shard N removed during backup" warnings for precreated,
still-empty shard groups are benign (metadata only, no data lost).

**Restore test (a) — PostgreSQL into a throwaway database on the live server:**

```bash
RUN=~/informatik/homelab/backups/<YYYY-MM-DD_HHMMSS>

# 1) The dump is a readable custom-format archive
kubectl -n apps cp "$RUN/pg-homelabdb.dump" postgresql-0:/tmp/restore-test.dump -c postgresql
kubectl -n apps exec postgresql-0 -c postgresql -- pg_restore --list /tmp/restore-test.dump | head -10

# 2) Restore it next to the live database — never over it
kubectl -n apps exec postgresql-0 -c postgresql -- createdb -U postgres restore_test
kubectl -n apps exec postgresql-0 -c postgresql -- \
  pg_restore -U postgres -d restore_test --no-owner /tmp/restore-test.dump

# 3) Compare the table counts with the live database — they must be identical
LIVE=$(kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -t -A -d homelabdb \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")
RESTORED=$(kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -t -A -d restore_test \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")
[ -n "$LIVE" ] && [ -n "$RESTORED" ] || { echo "count missing (kubectl failed?): live=$LIVE restored=$RESTORED"; exit 1; }
[ "$LIVE" = "$RESTORED" ] || { echo "MISMATCH: live=$LIVE restored=$RESTORED"; exit 1; }

# 4) Cleanup — MANDATORY
kubectl -n apps exec postgresql-0 -c postgresql -- dropdb -U postgres restore_test
kubectl -n apps exec postgresql-0 -c postgresql -- rm -f /tmp/restore-test.dump
```

**Restore test (b) — one PVC archive into a scratch volume** (Grafana is the smallest):

```bash
RUN=~/informatik/homelab/backups/<YYYY-MM-DD_HHMMSS>

# 1) The archive is readable and holds the expected file
tar -tzf "$RUN/grafana-data.tgz" | grep -x './grafana.db'

# 2) Reference hash, taken from the archive itself. Comparing against the LIVE pod is not a
#    valid gate here: grafana.db is written continuously, so it legitimately differs from any
#    backup taken earlier. The archive is the source of truth for "did the restore land
#    intact"; test (a) above is the live-versus-restored comparison.
SOURCE=$(tar -xzOf "$RUN/grafana-data.tgz" ./grafana.db | shasum -a 256 | awk '{print $1}')

# 3) Scratch PVC plus a helper pod, and extract the archive into it
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restore-test
  namespace: monitoring
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF
kubectl -n monitoring run restore-test-helper --image=busybox:1.37.0 --restart=Never \
  --override-type=merge --pod-running-timeout=120s \
  --overrides='{"spec":{"containers":[{"name":"helper","image":"busybox:1.37.0","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"restore-test"}}]}}'
kubectl -n monitoring wait --for=condition=Ready pod/restore-test-helper --timeout=120s
kubectl -n monitoring exec -i restore-test-helper -c helper -- tar xzf - -C /data < "$RUN/grafana-data.tgz"

# 4) Release the volume BEFORE the check pod starts. The scratch PVC is ReadWriteOnce: while
#    restore-test-helper still holds it, restore-check cannot mount it (it may also land on a
#    different node) and would hang until its timeout.
kubectl -n monitoring delete pod restore-test-helper --wait=true

# 5) Hash the same file from the restored volume. The checksum must live inside the container
#    overrides (command + args): kubectl run treats anything after `--` as extra arguments to
#    the image's entrypoint, so a bare `-- sha256sum ...` is silently dropped. Do not capture
#    the hash with `--rm -i`: `kubectl run -i` can lose the output of a container that exits
#    within a second (the attach loses the race; seen on 2026-09-08, empty hash on the first
#    invocation while the node still pulled the image). Letting the pod run to completion and
#    reading its logs is deterministic.
kubectl -n monitoring run restore-check --image=busybox:1.37.0 --restart=Never \
  --pod-running-timeout=120s \
  --overrides='{"spec":{"containers":[{"name":"restore-check","image":"busybox:1.37.0","command":["sh","-c"],"args":["sha256sum /data/grafana.db"],"volumeMounts":[{"name":"v","mountPath":"/data"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"restore-test"}}]}}'
kubectl -n monitoring wait --for=jsonpath='{.status.phase}'=Succeeded pod/restore-check --timeout=120s
RESTORED=$(kubectl -n monitoring logs restore-check | tail -1 | awk '{print $1}')
kubectl -n monitoring delete pod restore-check --wait=false

# 6) Compare — non-zero exit on a missing hash (kubectl failed) or a mismatch
[ -n "$SOURCE" ] && [ -n "$RESTORED" ] || { echo "hash missing (kubectl failed?): source=$SOURCE restored=$RESTORED"; exit 1; }
[ "$SOURCE" = "$RESTORED" ] || { echo "MISMATCH: source=$SOURCE restored=$RESTORED"; exit 1; }

# 7) Cleanup — MANDATORY, the scratch PVC is a full Longhorn volume
kubectl -n monitoring delete pod restore-test-helper restore-check --ignore-not-found
kubectl -n monitoring delete pvc restore-test
```

**Restore test log** — records the hashes/counts from both tests so a mismatch stays auditable
after the fact:

| Date | Run directory | Test | Values (source / restored) | Result |
|------|---------------|------|----------------------------|--------|
| 2026-09-08 | 2026-09-08_215809 | (a) PostgreSQL homelabdb → restore_test | tables public: 8 / 8 | PASS |
| 2026-09-08 | 2026-09-08_215809 | (b) grafana-data.tgz → scratch PVC | sha256 319b6602…896cb / 319b6602…896cb (full hash in the worklog) | PASS |
| 2026-09-09 | restic snapshot `c8d10fe4` (raspi5) | (c) restic `restore latest` → `/var/lib/backup/restore-test` | `k3s-state.db` 710176768 B, `PRAGMA integrity_check` = ok, 2520 kine rows; `server/token` sha256 identical to live | PASS |

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
flux reconcile kustomization data-service -n flux-system --with-source
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

# Prometheus metrics written by the last run (#92) — exit code, duration, last success
ssh raspi5 "cat /var/lib/node_exporter/textfile_collector/homelab-backup.prom"
# In Prometheus: homelab_backup_exit_code / homelab_backup_last_success_timestamp_seconds
# Alerts: ResticBackupFailed, ResticBackupStale — see "Backup alerting (#92)" above

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

Restic now covers `/etc/rancher/k3s` (kubeconfig + certs), `/var/lib/rancher/k3s/server/token`,
and a consistent copy of the k3s SQLite (kine) datastore (`k3s-state.db`, produced each run by
`homelab-backup.sh` via sqlite3's online backup API — see `infra/roles/storage/tasks/main.yml`).
Restore into `/var/lib/backup/restore-test` (mode `0700`, root-only) — **the restored
`k3s-state.db` contains every cluster Secret in plaintext**, so treat the restore target like a
secret itself and always run the cleanup step below.

```bash
# List snapshots
ssh raspi5 "sudo restic snapshots \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"

# Restore to /var/lib/backup/restore-test (root-only)
ssh raspi5 "sudo mkdir -p -m 0700 /var/lib/backup/restore-test"
ssh raspi5 "sudo restic restore latest \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /var/lib/backup/restore-test"

# Verify the restored k3s config + token are present
ssh raspi5 "ls -lh /var/lib/backup/restore-test/etc/rancher/k3s/"
ssh raspi5 "ls -lh /var/lib/backup/restore-test/var/lib/rancher/k3s/server/token"

# Integrity check on the restored SQLite datastore copy
ssh raspi5 "sudo python3 -c \"import sqlite3; print(sqlite3.connect('/var/lib/backup/restore-test/var/lib/backup/k3s-state.db').execute('PRAGMA integrity_check').fetchone())\""

# Cleanup — MANDATORY, do not leave a plaintext copy of every cluster Secret on disk
ssh raspi5 "sudo rm -rf /var/lib/backup/restore-test"
```

#### Full Restore (Disaster Recovery)

Only when k3s is stopped and node is freshly provisioned:

```bash
# Stop k3s
ssh raspi5 "sudo systemctl stop k3s"

# Restore from a specific snapshot
ssh raspi5 "sudo restic restore <snapshot-id> \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /"

# Restic restores the datastore copy to its backed-up path, not the live datastore location —
# put it back, and drop any stale WAL/SHM files so k3s starts from a clean checkpoint
ssh raspi5 "sudo cp /var/lib/backup/k3s-state.db /var/lib/rancher/k3s/server/db/state.db"
ssh raspi5 "sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal /var/lib/rancher/k3s/server/db/state.db-shm"

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

1. **Backup the k3s datastore** from raspi5 — k3s runs the embedded SQLite (kine) datastore, not
   etcd, so there is no `db/snapshots/` directory to copy; use the restic restore instead (see
   "Backup (Restic)" → "Restore Test (Non-Destructive)" above) to pull a recent
   `/etc/rancher/k3s`, `server/token`, and `k3s-state.db` onto your workstation before wiping
   the node.

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
| Check backup status | Daily | Primarily automatic since #92 — `ResticBackupFailed` / `ResticBackupStale` / `LonghornRecurringJob*` alert to Discord. Manual cross-check: `ssh raspi5 "journalctl -t homelab-backup --since '24 hours ago'"` + `ssh raspi5 "journalctl -t homelab-backup -p err --since '24 hours ago'"` |
| Verify Flux reconciliation | Daily | `flux check` |
| Restart degraded Longhorn volumes | Weekly | Check Longhorn UI for degraded volumes |
| Verify Longhorn recurring snapshot jobs fired | Weekly | `kubectl -n longhorn-system get recurringjobs.longhorn.io daily-snapshot metrics-snapshot-cleanup` + `kubectl -n longhorn-system get snapshots.longhorn.io` (see "Recurring Snapshots (#63)" and "Excluded volumes: the metrics group (#101)" above) |
| Run the app-data backup script | Monthly and before every image bump | `./scripts/backup-app-data.sh` on the Mac (see "App-data backups to the operator's Mac (#64)" above) |
| Test backup restore | Monthly | App-data restore tests (see "App-data backups to the operator's Mac (#64)") + restic non-destructive restore test (see "Backup (Restic)") |
| Check restic repository size | Monthly | `ssh raspi5 "sudo du -sh /var/lib/backup/restic-repo"` |
| Check app-data dump freshness | Monthly | `ls -lt ~/informatik/homelab/backups/` on the Mac — **not alerted** (the Mac is not a cluster node, see "Backup alerting (#92)") |
| Update Python packages | Monthly | `pip install --upgrade ansible ansible-lint` |
| Review k3s security advisories | Monthly | Check [k3s releases](https://github.com/k3s-io/k3s/releases) |
| Check Ansible collection versions | Monthly | `ansible-galaxy collection list` vs Galaxy API — see CONTRIBUTING.md "Ansible Collection Updates (Manual)" |
| Triage Helm chart freshness issues | Weekly (automated) / as opened | Handle any open GitHub issue labeled `helm-freshness` — see CONTRIBUTING.md "Helm Chart Version Tracking" |

---

## Quick Reference: All Playbooks

| Playbook | Purpose | Runtime | Idempotent |
|----------|---------|---------|------------|
| `00_bootstrap.yml` | Initial node setup (Python, ansible user, SSH key) | 2-5 min | Yes (after first run) |
| `10_base.yml` | Base packages, hardening, UFW, fail2ban, watchdog, netmon node metrics (`--tags netmon_node`) | 3-5 min | Yes |
| `20_k3s.yml` | k3s installation and configuration | 5-10 min | Yes |
| `30_longhorn.yml` | Longhorn storage system, default StorageClass, and daily recurring snapshot job | 3-5 min | Yes |
| `40_platform.yml` | cert-manager, Cloudflare Tunnel, Traefik | 3-5 min | Yes |
| `41_monitoring.yml` | kube-prometheus-stack (long Helm wait) | 10-15 min | Yes |
| `50_apps_infra.yml` | PostgreSQL 17, InfluxDB 2, Mosquitto 2 | 5-8 min | Yes |
| `51_homeassistant.yml` | Home Assistant | 3-5 min | Yes |
| `52_n8n.yml` | n8n deployment | 2-3 min | Yes |
| `53_litellm.yml` | LiteLLM deployment | 3-5 min | Yes |
| `54_club_assistant.yml` | Open WebUI (Club Assistant) deployment + DB provisioning | 3–5 min | Yes |
| `59_app_services.yml` | App secrets, per-app DBs (litellm, data_service) and bootstrap | 2-3 min | Yes |

---

## Related Documentation

| Need | File |
|------|------|
| Deploy YOUR apps on this platform | [APP-DEPLOYMENT.md](APP-DEPLOYMENT.md) |
| Platform interfaces and contracts | [INTERFACES.md](INTERFACES.md) |
| Platform overview, features, URLs | [README.md](README.md) |
| Work on this infrastructure repo | [CONTRIBUTING.md](CONTRIBUTING.md) |
