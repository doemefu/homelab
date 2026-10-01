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
# Enable Flux GitOps for auth-service, device-service, furchert-ch, data-service and mcp-hub
# (data-service first needs its deploy key + DB/Secret — see "data-service (Flux, NM-0 onboarding)";
#  mcp-hub its deploy key + Secret — see "mcp-hub (Flux, #170 onboarding)")
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
| `apps` | postgresql-0, influxdb2-0, mosquitto-*, auth-service-*, device-service-*, furchert-ch-*, data-service-*, mcp-hub-*, n8n-*, litellm-*, open-webui-* | Running |
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

##### Apiserver etcd health-check timeout

`/readyz`'s etcd check can fail purely because kine queries are momentarily slower than the
apiserver's built-in 2s health-check timeouts, without anything else being broken — and once it
fails, the embedded cloud-controller-manager panics and restart-loops on a failed `/healthz` (see
"Symptoms" above), which makes an already-degraded cluster worse. Since 2026-09-24 (owner
decision on homelab#129), both timeouts are raised to 20s permanently by the `k3s` role, not by a
manual drop-in: `infra/roles/k3s/templates/k3s-server.service.j2`'s `ExecStart` sets
`--kube-apiserver-arg=etcd-healthcheck-timeout={{ k3s_apiserver_etcd_healthcheck_timeout }}` and
the matching `etcd-readycheck-timeout` flag (both default `20s`,
`infra/roles/k3s/defaults/main.yml`), applied only to the control-plane node (the
`k3s-server.service.j2` template is only rendered for the `k3s_server` group). This buys the
online compactor — or an offline compaction run — time before the CCM starts restart-looping,
without anyone having to apply the incident's manual mitigation by hand first.

The 2026-09-23 incident applied this as a hand-written config-file drop-in at
`/etc/rancher/k3s/config.yaml.d/90-incident-129-etcd-healthcheck.yaml` first (mitigation 2, 17:09
CEST); `infra/roles/k3s/tasks/server.yml` now removes that file on every run — redundant once the
same timeouts are on the systemd unit's command line — as part of converging the node to the
templated config.

**Owner step:** apply the role with playbook 20, limited to the control-plane node:

```bash
# on the LAN
ansible-playbook infra/playbooks/20_k3s.yml --limit raspi5

# off-LAN — see "Off-LAN kubectl / Ansible Access" for the SSH jump config prerequisite
ANSIBLE_SSH_ARGS="-F $HOME/.ssh/homelab-offlan.conf -o ControlMaster=auto -o ControlPersist=60s" \
  ansible-playbook infra/playbooks/20_k3s.yml --limit raspi5
```

The first run restarts k3s on raspi5 (~30-60s control-plane blip while the apiserver picks up the
new flags; containers and public endpoints are unaffected — `k3s.service` ships with
`KillMode=process`). Subsequent runs are idempotent: the drop-in is already gone and the
templated unit is already up to date, so neither task reports `changed` and k3s is not restarted
again.

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
- **Filesystem trim job (#106):** group `metrics` carries a second `RecurringJob`,
  `metrics-filesystem-trim` (`infra/playbooks/30_longhorn.yml`, task `filesystem-trim`, cron
  `0 5 * * *` node-local, retain 0, concurrency 1). It exists because an excluded volume keeps a
  frozen base forever: Longhorn never deletes a volume's *newest* snapshot, it only marks it
  removed and merges it once a newer snapshot appears — and with no snapshot job on the volume,
  no newer snapshot ever appears. After the #101 cleanup the Prometheus volume went from 21.3 G
  back to 22.0 G within a day, on its way to ~40 G (2 x the 20 Gi volume). A trim reclaims the
  blocks the filesystem no longer uses, both in the volume head **and** in the continuous chain
  of already-removed snapshots below it, so the frozen base shrinks too; valid (not removed)
  snapshots are immutable and are never trimmed, which is why the `default`-group volumes keep
  their chains. 05:00 is simply clear of the 02:00, 03:00 and 04:00 windows — the cleanup job
  is not a precondition for the trim. The job ends with a snapshot purge, which is a no-op
  unless a replica rebuild left a system snapshot behind.
  - Prerequisites: a trimmable filesystem (ext4 or XFS — the `longhorn` StorageClass formats
    ext4, check with `kubectl get sc longhorn -o jsonpath='{.parameters.fsType}'`) and the volume
    **attached and mounted**. The workload keeps running; no `discard` mount option is needed.
  - Every failure mode is silent: a detached volume (workload scaled to 0, node down) is skipped
    with a log warning only, and a trim does nothing while a replica is rebuilding. The line
    `Finished recurring filesystem trim` in the job pod's log is the only proof that a run did
    something — see the weekly maintenance checklist.
  - ⚠️ Do **not** enable the global setting `remove-snapshots-during-filesystem-trim` to "help"
    this job. It is unnecessary here (the leftover snapshot is already marked removed) and it is
    cluster-wide: it would mark the newest snapshot of *every* volume as removed during a trim,
    including the app volumes that rely on `daily-snapshot` for rollback.
  - ext4 remembers which blocks it has already discarded. A snapshot that is marked removed
    *after* a trim may therefore keep its blocks until the filesystem is remounted — restart the
    Prometheus pod and let the next trim run if a removed snapshot refuses to shrink.
  - Cost: the trim runs as `fstrim` in the host mount namespace with a one-hour timeout. The first
    run discards the whole accumulated free space at once and loads the replica nodes noticeably;
    steady-state runs discard only one day of churn.
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
    trim — for `metrics`-group volumes that is what `metrics-filesystem-trim` does nightly). This
    is how the Prometheus volume's pre-#101 chain (≈ 40 G) was removed, once.
- **Verify:**
  ```bash
  kubectl -n longhorn-system get recurringjobs.longhorn.io        # daily-snapshot + metrics-snapshot-cleanup + metrics-filesystem-trim
  kubectl -n monitoring get pvc <name> --show-labels
  kubectl -n longhorn-system get snapshots.longhorn.io -o json | jq '[.items[] | select(.spec.volume=="<volume-name>")] | length'

  # Did the nightly trim actually run? (a skipped volume logs a warning and nothing else)
  kubectl -n longhorn-system get pods --sort-by=.metadata.creationTimestamp | grep metrics-filesystem-trim
  kubectl -n longhorn-system logs <that pod> | grep 'Finished recurring filesystem trim'

  # Volume attached and running the expected engine image (a detached volume is skipped silently)
  kubectl -n longhorn-system get volumes.longhorn.io <volume-name> -o jsonpath='{.status.state}{"  "}{.status.currentImage}'

  # Did it free anything? Compare before and after a run; actualSize should approach "Used".
  kubectl -n longhorn-system get volumes.longhorn.io <volume-name> -o jsonpath='{.status.actualSize}'
  kubectl -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- df -h /prometheus

  # On-disk proof on each replica node — this is the number that filled raspi4's SD card
  ssh raspi5 'sudo du -sh /var/lib/longhorn/replicas/<volume-name>-*'
  ssh mba1   'sudo du -sh /var/lib/longhorn/replicas/<volume-name>-*'
  ```
- **Warnings:**
  - Removing the labeling task from `41_monitoring.yml` does NOT remove the labels — clear them
    explicitly (`kubectl -n monitoring label pvc/<name> recurring-job-group.longhorn.io/metrics- recurring-job.longhorn.io/source-`).
  - Deleting the *last* `RecurringJob` of the group strips the labels from PVC and Volume,
    silently returning the volume to `default`; recover by re-running `30_longhorn.yml` and
    `41_monitoring.yml`. With both `metrics-snapshot-cleanup` and `metrics-filesystem-trim` in
    place, deleting one of the two is safe — deleting both is not.
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

Worked example: `mcp.furchert.ch` in "mcp-hub (Flux, #170 onboarding)".

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
  IdentitiesOnly yes
  ProxyCommand cloudflared access ssh --hostname %h
```

Always pair `~/.ssh/homelab` with `IdentitiesOnly yes` (`-o IdentitiesOnly=yes` on the command line). Otherwise ssh-agent offers its other keys first, the server's `MaxAuthTries` runs out before `~/.ssh/homelab` is tried, and the connection fails with `Received disconnect … Too many authentication failures`.

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

Recommended shortcut: add this block to `~/.ssh/config`, so the plain forms
`ssh ssh.furchert.ch '…'` and `ssh -N -L 6443:localhost:6443 ssh.furchert.ch` work:

```sshconfig
Host ssh.furchert.ch
  User ansible
  IdentityFile ~/.ssh/homelab
  IdentitiesOnly yes
  ProxyCommand cloudflared access ssh --hostname %h
```

1. Open the forward in its own terminal and leave it running (`-N` = no remote shell, just
   hold the tunnel open):

   ```bash
   ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes \
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
  IdentitiesOnly yes
  ProxyCommand cloudflared access ssh --hostname %h
Host 192.168.1.*
  User ansible
  IdentityFile ~/.ssh/homelab
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  ProxyCommand ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname ssh.furchert.ch" -W %h:%p ansible@ssh.furchert.ch
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
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps get pods'

# apply exactly one manifest from the local checkout (used for PR #73 on 2026-09-03):
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
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
| Spike gate | node label `homelab.furchert.ch/coroot-node-agent=enabled`, managed by `41_monitoring.yml` from `coroot_node_agent_nodes` (default: all four nodes `[raspi5, mba1, mba2, raspi4]` since 2026-09-25) |

**The gate.** The DaemonSet only schedules on labelled nodes. `41_monitoring.yml` labels exactly
the nodes in `coroot_node_agent_nodes` and **removes** the label from every other node, so the
play variable is the source of truth: nodes missing from the list lose the label on the next run.
The default covers all four nodes, `[raspi5, mba1, mba2, raspi4]`, since 2026-09-25. raspi5 and
mba1 ran the spike, mba2 joined on 2026-09-24, and raspi4 joined on 2026-09-25. With an empty list
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
`hostNetwork: true` and no node pin. **The owner accepted this residual risk on 2026-09-24 (#118).**
It is homelab-only, and the agent has no external exposure. Revisit it if either alternative
becomes available:
- a `/metrics`-only reverse-proxy sidecar with the agent bound to `127.0.0.1`, which adds a new pinned image and needs approval;
- an upstream flag that disables pprof.

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

   **Result (2026-09-24, from 11:52):** raspi5 and mba1 were the playbook default after the spike; mba2 joined later (step 6).

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

   **mba2 joined on 2026-09-24** (t2 kernel 6.19.10, no BTF), with the owner's go on #118. It
   followed the raspi5 and mba1 measurements of the 1Gi run: requests 256Mi and limits 1Gi,
   2026-09-24 15:09–17:15 CEST (2 h). These are a later run than the 768Mi spike table in step 5
   (320 / 399 MiB, band up to 420, peak 702 MiB), not a contradiction of it:

   | Measure (1Gi run, 2 h) | raspi5 | mba1 |
   |---|---|---|
   | Working set, steady | 318 MiB | 350 MiB |
   | RSS, steady | 68 MiB | 98 MiB |
   | Startup peak, under the 1Gi limit | 479 MiB | 544 MiB |
   | Restarts | 0 | 0 |

   Criterion 2's 24 h restart window (docs/060 §6.3) started 2026-09-24 11:52 CEST and ends
   2026-09-25 11:52 CEST; the result is recorded at the 12:07 checkpoint (0 restarts so far on all
   three nodes).

   Expect a startup peak of about 500–700 MiB on mba2's t2 kernel, and watch for OOMKilled during
   the first 5 minutes.

   **raspi4 joined on 2026-09-25**, after 12 h of mba2 observation. The gate now covers all four
   nodes. The plan's further 24 h of mba2 observation was shortened to 12 h on the lead's
   recommendation (mba2 flat at 332 MiB steady / 349 MiB peak, 0 restarts). The owner decision is
   Dominic's merge of PR #167 (2026-09-25). Evidence from the 2026-09-25 morning check:

   | Node | Max working set (12 h window 19:13–07:13 CEST, excludes the startup peak) | Other |
   |---|---|---|
   | mba2 | 349 MiB | steady 332 MiB, RSS 63 MiB, 0 restarts, no OOMKilled |
   | raspi5 | 442 MiB | — |
   | mba1 | 390 MiB | — |

   Memory headroom on raspi4 is the tightest in the cluster. It has 3 785 Mi allocatable, of which
   1 736 Mi (about 46 %) is used, leaving about 2 GB free. That is enough for the agent's 256Mi request and
   an expected startup peak of about 400–500 MiB on the arm64 Pi (raspi5 measured 479 MiB), under
   the 1Gi limit. Watch raspi4's pod for OOMKilled during the first 5 minutes.
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
2. Restart data-service so the running pod picks up the new env vars (`optional: true` secretKeyRefs are resolved only at pod start). Delete the pod rather than using `rollout restart`, which Flux undoes (see the note under "Enable order (NM-4)"). Skip this when data-service#14's image rollout follows right away — that rollout restarts the pod anyway.
3. Run playbook 41. It applies the ServiceMonitor and loads the rules in one run, so the `absent()` branch of `NetmonDataServiceDown` never sees a scrape gap. data-service is already running since NM-0, so this step can happen before data-service#14.
4. Merge data-service#14 (collectors), then furchert-ch#61 (UI).

```bash
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml   # second run: no change for the Secret task
kubectl -n apps get secret data-service-secrets -o json | jq '.data | keys'
# expect: cloudflare-api-token, cloudflare-zone-id, db-password, db-username
kubectl -n apps delete pod -l app=data-service         # only if no data-service image rollout follows
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

> **Restart Flux-managed pods with `kubectl delete pod`, not `rollout restart`.** This applies to every Deployment that a Flux Kustomization reconciles: auth-service, data-service, device-service and furchert-ch. It does not apply to Helm- or playbook-managed workloads. Flux's next server-side apply (interval 10 min) strips the `restartedAt` annotation that `rollout restart` sets. The new ReplicaSet can then be scaled back to 0 before its pod is Ready, while `rollout status` still reports success. Deleting the pod makes the ReplicaSet recreate it from the current template. A single-replica service is down for about 30 to 60 s. Check the pod age and the startup log, not `rollout status` alone.

1. Owner: add both SOPS variables (`sops infra/inventory/group_vars/all.sops.yml`).
2. Run playbook 59 **twice**. The first run adds the keys. The second run must report no change for the Secret tasks.
3. Restart auth-service by deleting its pod (see the note above), so the new pod reads the new env vars. On startup it seeds the `data-service` client and logs `Login-event outbox enabled`.
4. Merge the data-service PR (homelab-data-service#17), then restart data-service if its image rollout does not follow right away (`AUTH_CLIENT_SECRET` is read at pod start).
5. Merge the furchert-ch PR (furchert-ch#64).

```bash
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml   # second run: no change for the Secret tasks
kubectl -n apps get secret homelab-auth-secrets -o json | jq '.data | keys'
# expect data-service-client-secret and login-event-hmac-key next to the existing keys
kubectl -n apps get secret data-service-secrets -o json | jq '.data | keys'
# expect auth-client-secret next to the existing keys
kubectl -n apps delete pod -l app=auth-service
kubectl -n apps rollout status deploy/auth-service
kubectl -n apps get pods -l app=auth-service          # the pod age must be new
kubectl -n apps logs deploy/auth-service | grep -i 'login-event'
# expect "Login-event outbox enabled (consumer client 'data-service')"; a WARN "disabled" names the missing variable
```

**Turning NM-4 off.** Removing the two SOPS variables does not remove the keys: playbook 59 then skips the NM-4 tasks, and its other Secret tasks patch the Secrets without deleting unknown keys. Remove the keys by hand, then restart both services:

```bash
kubectl -n apps patch secret homelab-auth-secrets --type=json \
  -p='[{"op":"remove","path":"/data/data-service-client-secret"},{"op":"remove","path":"/data/login-event-hmac-key"}]'
kubectl -n apps patch secret data-service-secrets --type=json \
  -p='[{"op":"remove","path":"/data/auth-client-secret"}]'
kubectl -n apps delete pod -l app=auth-service
kubectl -n apps delete pod -l app=data-service
```

auth-service then logs the "disabled" WARN and answers 503. The seeded `data-service` row in `oauth2_registered_client` stays until it is deleted there.

**After an auth-service DB restore.** Outbox ids can restart below data-service's cursor, so new login events would be skipped. With the owner's go, reset the cursor. The replay is absorbed by `event_id`:

```bash
kubectl -n apps exec postgresql-0 -- psql -U postgres -d data_service \
  -c "UPDATE netmon.collector_state SET cursor = NULL WHERE collector = 'login-events'"
```

**Rotation.** `auth_service_login_event_hmac_key`: rotating it breaks HMAC continuity for login events already stored in data-service, so avoid it. `auth_service_data_service_client_secret`: auth-service seeds a client only once and never updates it, so a new SOPS value plus playbook 59 is not enough. Also update the `data-service` row in `oauth2_registered_client` (see homelab-auth-service `INTERFACES.md` §6), then restart auth-service and data-service.

### NM-1 follow-up: AbuseIPDB key (optional)

The `reputation` collector in data-service checks suspicious public IPs against AbuseIPDB (`docs/060-network-monitoring.md` §4.5). It stays off until the key exists. With the key, it runs every 30 min at :00 and :30. It checks at most 10 IPs per run and 200 per UTC day, which is well under the free plan's 1 000 checks per day.

| Piece | Where | Names |
|-------|-------|-------|
| SOPS variable (owner, optional) | `infra/inventory/group_vars/all.sops.yml` | `data_service_abuseipdb_key` |
| data-service key | `59_app_services.yml` → `apps/data-service-secrets` | `abuseipdb-api-key` (env `ABUSEIPDB_API_KEY`) |

Without the variable, playbook 59 skips the key and prints a note. If the variable is set but empty, the playbook fails.

#### Enable order

1. Owner: create a free account at abuseipdb.com, then create an API key (Account → API).
2. Owner: `sops infra/inventory/group_vars/all.sops.yml` and add `data_service_abuseipdb_key: "<key>"`.
3. Commit the encrypted file on a branch, open a PR and merge it.
4. Run playbook 59 **twice**. The first run adds the key. The second run must report no change for the Secret tasks.
5. Restart data-service by deleting its pod (see the Flux note in "Enable order (NM-4)"). `ABUSEIPDB_API_KEY` is read at pod start, and `rollout restart` is reverted by Flux.

```bash
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml   # second run: no change for the Secret tasks
kubectl -n apps get secret data-service-secrets -o json | jq '.data | keys'
# expect abuseipdb-api-key next to the existing keys
kubectl -n apps delete pod -l app=data-service
kubectl -n apps get pods -l app=data-service          # the pod age must be new
```

#### Verify

After the next :00 or :30 run:
- The Prometheus series `netmon_collector_last_success_timestamp_seconds{collector="reputation"}` exists. data-service registers it only when the key is set, so it is NaN until the first success.
- `GET /api/netmon/status` lists `reputation` with `enabled: true` and without a `credentials` error. You can see this in furchert-ch `/dashboard/network`.

A run with no candidate IPs also counts as a success. A `credentials` error means AbuseIPDB rejected the key.

**Turning it off.** Removing the SOPS variable does not remove the key, because playbook 59 then only skips it. Remove the key by hand and restart data-service:

```bash
kubectl -n apps patch secret data-service-secrets --type=json \
  -p='[{"op":"remove","path":"/data/abuseipdb-api-key"}]'
kubectl -n apps delete pod -l app=data-service
```

The new pod exports no `reputation` gauge, so `NetmonCollectorStale` does not fire for it.

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

### mcp-hub (Flux, #170 onboarding)

`mcp-hub` gives Claude (claude.ai custom connector) read-only access to mail and calendars through one endpoint, reachable at `https://mcp.furchert.ch/mcp` once the tunnel route (second PR of #177) is applied. It is Flux-managed like data-service (`cluster/apps/mcp-hub/`), reads its account registry, provider credentials and subject allowlist from the Secret `mcp-hub-secrets` (mounted as files, created by `59_app_services.yml`), and validates access tokens that auth-service issues to the client `claude-mcp-hub`. Contract: `docs/080-mcp-hub.md` (§4.6 incident procedure, §4.7 edge, §7.1 variables); authorization decision: [`docs/adr/0003-mcp-hub-authorization.md`](docs/adr/0003-mcp-hub-authorization.md). Run every command from the repository root. Every step that changes the cluster, Cloudflare or SOPS is an owner action.

#### Order (first rollout, spec 080 §11.1 WP7)

The go-live has two stages. **Stage a** uses the first hub image, which offers only `list_accounts`: it proves the login, the token, the kill switch and the incident drill in production, with no provider credential in the cluster: the `icloud` registry entry is switched off (`enabled: false`) and `mcp_hub_credentials: {}`, so `icloud` shows `disabled` (`unknown` is reserved for enabled accounts whose adapter or check has not run yet). **Stage b** follows once the mail and calendar tools have shipped: it switches the `icloud` entry on and adds its credentials (step 13). Rolling back at any stage: once auth-service has seeded the `claude-mcp-hub` client (step 5), a revert of the auth-service change, an older auth-service image or a removed or renamed client entry is allowed only after "Disable and remove the `claude-mcp-hub` client" ("mcp-hub incident runbook").

1. `homelab-mcp-hub` bootstrap merged: `k8s/` exists on `main`, CI pushed a first image `ghcr.io/doemefu/homelab-mcp-hub:main-…`.
2. Owner prerequisites (a)–(f) below — the SOPS values **before** step 3.
3. The platform PR of this repository merged (Flux bundle, playbook tasks, this runbook) — only after the auth-service change (homelab-auth-service#107) and the device-service gate tests (homelab-device-service#88) are merged with their gates green, so the client is never seeded before the barrier is in place (spec 080 D54); local checkout on `main` (step (g)).
4. Playbook 59, twice (step (h)).
5. auth-service with the `claude-mcp-hub` client deployed, then its pod deleted so it reads the new keys and seeds the client (step (i)).
6. Flux reconciles mcp-hub; the pod is Ready (step (j)). Until image automation has committed the first real tag, the pod shows `ImagePullBackOff` on the never-built placeholder tag — expected, see "Troubleshooting" below.
7. Pre-go-live allowlist check (step (k)).
8. Edge rate-limit rule (below, "Cloudflare rules") — before the first production login.
9. The tunnel-route PR of this repository merged (the last merge of the rollout), then playbook 40 + DNS record (step (l)); zone checks; unauthenticated check (step (m)).
10. Stage a: deployed-image check (step (o)) — both services run images built after their gate-test merges; then add the connector in claude.ai; the first login shows the consent page with both scopes; ask Claude to list the accounts (`icloud` shows `disabled`).
11. WAF allow rule (below), then one more `list_accounts` call.
12. Incident drill ("mcp-hub incident runbook").
13. Stage b (after the hub release with the mail and calendar tools is running): in the same SOPS edit set `enabled: true` on the `icloud` entry of `mcp_hub_accounts` and add `icloud-username` and `icloud-app-password` to `mcp_hub_credentials` (step (f)), run playbook 59 (step (h)), then restart the hub (step (n)) — the registry changed, and the hub reads it only at start-up. No route or rule change. `list_accounts` shows `icloud` as `ok` after the first background status check, about 30 s after the restart (`unknown` before it), no longer `disabled`. Ask for tomorrow's events and for unread iCloud mail.

A pod that starts before step 4 waits in `ContainerCreating` (Secret volume missing) and starts by itself once the Secret exists.

**Which Secret changes need a hub restart.** The kubelet refreshes every key of `mcp-hub-secrets` in the running pod within about 1–2 min, but the hub uses them differently:

| Key | Read by the hub | After a change |
|-----|-----------------|----------------|
| `accounts.json` (registry) | once, at start-up | **delete the hub pod** (step (n)) — every registry change: stage b, a new account (`gmail` #172, `outlook` #171, `uzh` #173), `enabled` on or off |
| `allowed-subjects` | re-read at least every 60 s | nothing (kill switch L2 adds a pod delete only to be faster) |
| credential keys (`icloud-username`, …) | when a provider connection opens; presence checked per `list_accounts` call | nothing, as long as the key names in `accounts.json` stay the same; a renamed or new key is a registry change |

#### Owner prerequisites

```bash
# (a) Flux deploy key with WRITE access (image automation pushes tag bumps to main).
flux create secret git mcp-hub-flux-auth -n flux-system \
  --url=ssh://git@github.com/doemefu/homelab-mcp-hub \
  --ssh-key-algorithm=ed25519
kubectl -n flux-system get secret mcp-hub-flux-auth \
  -o jsonpath='{.data.identity\.pub}' | base64 -d > /tmp/flux-mcp-hub.pub
gh repo deploy-key add /tmp/flux-mcp-hub.pub -R doemefu/homelab-mcp-hub \
  --title flux-mcp-hub --allow-write
rm /tmp/flux-mcp-hub.pub

# (b) GHCR visibility: make the package public after the first push (the image holds no secrets):
#     https://github.com/users/doemefu/packages/container/homelab-mcp-hub/settings
#     -> Danger Zone -> Change visibility -> Public.
gh api /users/doemefu/packages/container/homelab-mcp-hub --jq '.visibility'   # expect: public

# (c) Branch ruleset on the hub repository (same as auth-service, whose main receives Flux image-update
#     commits with this combination): pull request required, no force push, no deletion, automatic
#     Copilot review, bypass = admin role only, no deploy-key bypass actor. Show it:
gh api repos/doemefu/homelab-mcp-hub/rulesets --jq '.[].id' | while read -r id; do gh api "repos/doemefu/homelab-mcp-hub/rulesets/$id" --jq '{name, enforcement, bypass: [.bypass_actors[] | "\(.actor_type):\(.actor_id)"], rules: [.rules[].type]}'; done
# expect exactly one ruleset: name "main", enforcement "active", bypass only a RepositoryRole entry (admin),
#     rules deletion, non_fast_forward, pull_request and the Copilot review rule.
#     The proof that Flux can push is the first Flux image-update commit on the hub's main — checked in step (j).
#     Required status checks and the CodeQL rule are added by you after the first build on main.

# (d) Client secret for claude-mcp-hub (32 random bytes, hex). The plaintext is shown ONCE: store it in
#     the password manager now; it is needed only when adding the connector in claude.ai. SOPS gets only
#     the bcrypt hash (cost 10).
MCP_HUB_CLIENT_SECRET="$(openssl rand -hex 32)"
printf '%s\n' "$MCP_HUB_CLIENT_SECRET"
MCP_HUB_CLIENT_SECRET_BCRYPT="{bcrypt}$(printf '%s' "$MCP_HUB_CLIENT_SECRET" | htpasswd -niBC 10 claude-mcp-hub | cut -d: -f2- | tr -d '\n')"
printf '%s\n' "$MCP_HUB_CLIENT_SECRET_BCRYPT"   # -> auth_service_claude_mcp_hub_client_secret (in single quotes)
unset MCP_HUB_CLIENT_SECRET MCP_HUB_CLIENT_SECRET_BCRYPT

# (e) Your auth-service username exactly as stored (letter case matters for both allowlists):
kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -tAc \
  "SELECT username FROM users WHERE role = 'ADMIN' AND status = 'ACTIVE' ORDER BY username"

# (f) SOPS: add the variables below, then save (sops re-encrypts on save).
sops infra/inventory/group_vars/all.sops.yml
```

The playbooks read the working tree, so an uncommitted SOPS edit works for steps (h)–(n). Commit the re-encrypted file as `chore(sops): …` and bring it to `main` through a pull request, as for earlier SOPS changes; do not leave the commit unpushed on local `main`, or the `git pull --ff-only` of steps (g) and (l) stops.

Variables for step (f). Set all three `mcp_hub_*` variables together (with none, playbook 59 skips the hub; with only some, it fails):

| Variable | Value |
|----------|-------|
| `mcp_hub_accounts` | the registry below (no addresses, only key names). Stage a: `enabled: false` (as shown). Stage b: `enabled: true` |
| `mcp_hub_credentials` | stage a: `{}` (the entry is off, `list_accounts` shows `icloud` as `disabled`). Stage b: `icloud-username` = the Apple mail name, `icloud-app-password` = an app-specific password created in the Apple Account settings (two-factor authentication required) |
| `mcp_hub_allowed_subjects` | a list with the username from (e), for example written as a one-element YAML list; `[]` = nobody |
| `auth_service_claude_mcp_hub_client_secret` | the `{bcrypt}…` line printed by (d), in single quotes |
| `auth_service_claude_mcp_hub_allowed_users` | the username from (e) |

```yaml
mcp_hub_accounts:
  version: 1
  accounts:
    - id: icloud
      label: iCloud
      provider: icloud
      enabled: false        # stage a; set to true in stage b together with the credentials
      capabilities: {mail: true, calendar: true}
      mail: {protocol: imap, host: imap.mail.me.com, port: 993, username_ref: icloud-username, password_ref: icloud-app-password, inbox: INBOX}
      calendar: {protocol: caldav, url: "https://caldav.icloud.com/", username_ref: icloud-username, password_ref: icloud-app-password, include_calendars: all}
```

Later stories add their entries and credential keys (`gmail` #172, `outlook` #171, `uzh` #173) — see `docs/080-mcp-hub.md` §8.2.

##### Alternative without the editor (`sops set`)

The same stage-a values can be written without opening the editor; this path also generates the client secret of step (d), so use it instead of (d) and (f), not in addition. In the editor, an unquoted `{bcrypt}…` value is read as a YAML flow mapping and the save fails; `sops set` avoids that because every value is given as JSON. `sops set` rejects a top-level JSON array, so the one-element allowlist is written through the index form `["mcp_hub_allowed_subjects"][0]`; `--value-stdin` keeps the values out of the process list. The registry is the YAML example above as JSON.

```bash
F=infra/inventory/group_vars/all.sops.yml
sops set --value-stdin "$F" '["mcp_hub_accounts"]' <<'JSON'
{"version":1,"accounts":[{"id":"icloud","label":"iCloud","provider":"icloud","enabled":false,
 "capabilities":{"mail":true,"calendar":true},
 "mail":{"protocol":"imap","host":"imap.mail.me.com","port":993,"username_ref":"icloud-username","password_ref":"icloud-app-password","inbox":"INBOX"},
 "calendar":{"protocol":"caldav","url":"https://caldav.icloud.com/","username_ref":"icloud-username","password_ref":"icloud-app-password","include_calendars":"all"}}]}
JSON
printf '{}' | sops set --value-stdin "$F" '["mcp_hub_credentials"]'
U="$(kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -tAc "SELECT username FROM users WHERE role = 'ADMIN' AND status = 'ACTIVE' ORDER BY username")"
printf '%s\n' "$U"
printf '%s' "$U" | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_allowed_subjects"][0]'
printf '%s' "$U" | jq -Rs . | sops set --value-stdin "$F" '["auth_service_claude_mcp_hub_allowed_users"]'
S="$(openssl rand -hex 32)"
printf '%s\n' "$S"
H="{bcrypt}$(printf '%s' "$S" | htpasswd -niBC 10 claude-mcp-hub | cut -d: -f2- | tr -d '\n')"
printf '%s' "$H" | grep -Ec '^\{bcrypt\}\$2[aby]\$10\$[./A-Za-z0-9]{53}$'
printf '%s' "$H" | jq -Rs . | sops set --value-stdin "$F" '["auth_service_claude_mcp_hub_client_secret"]'
unset S H
```

Paste the commands one at a time (the `sops set … <<'JSON'` command up to the closing `JSON` line counts as one) and check two outputs before going on: the username query must print exactly one line (your username, as in step (e)) — otherwise stop before the two allowlist commands; the `grep -Ec` line must print `1` — otherwise the hash is malformed, stop before it is written. The plaintext secret printed by `printf '%s\n' "$S"` is shown only once: store it in the password manager before `unset S H`.

#### Apply and verify

```bash
# (g) Playbooks run from a checkout that has pulled main (group_vars and the new tasks come from the checkout).
git switch main && git pull --ff-only
grep -n 'mcp-hub-secrets' infra/playbooks/59_app_services.yml   # must print the new task

# (h) Playbook 59; the second run must report no change for the Secret tasks.
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml
kubectl -n apps get secret mcp-hub-secrets --request-timeout=10s -o json | jq '.data | keys'
# expect stage a: accounts.json, allowed-subjects; stage b additionally: icloud-app-password, icloud-username
kubectl -n apps get secret homelab-auth-secrets --request-timeout=10s -o json | jq '.data | keys'
# expect claude-mcp-hub-allowed-users and claude-mcp-hub-client-secret next to the existing keys

# (i) Only after the auth-service release with the claude-mcp-hub client is running:
kubectl -n apps delete pod -l app=auth-service
kubectl -n apps get pods -l app=auth-service --request-timeout=10s   # the pod age must be new
kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -tAc \
  "SELECT client_id, left(client_secret, 12) FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub'"
# expect one row: claude-mcp-hub|{bcrypt}$2y$

# (j) Flux
flux reconcile kustomization apps -n flux-system --with-source
flux get sources git mcp-hub -n flux-system
flux get image repository mcp-hub -n flux-system
flux get image policy mcp-hub -n flux-system
flux get kustomizations mcp-hub -n flux-system
flux get image update mcp-hub -n flux-system        # READY True, last run pushed a commit (a rejected push shows here)
gh api 'repos/doemefu/homelab-mcp-hub/commits?sha=main&per_page=20' --jq '[.[] | select(.commit.author.name == "Flux") | .commit.message][0]'
# expect: chore: update mcp-hub image to ghcr.io/doemefu/homelab-mcp-hub:main-… (proof that the ruleset of (c) lets Flux push).
#   null + a push error in the line above: add the deploy key as a bypass actor (GitHub -> homelab-mcp-hub -> Settings ->
#   Rules -> Rulesets -> main -> Bypass list -> Add bypass -> Deploy keys), then run this step again.
kubectl -n apps get deploy mcp-hub --request-timeout=10s -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# expect a main-… tag other than main-20260928T000000 (the never-built placeholder; ImagePullBackOff until it is replaced)
kubectl -n apps get pods -l app=mcp-hub --request-timeout=10s
kubectl -n apps logs deploy/mcp-hub --tail=50 --request-timeout=10s

# (k) Pre-go-live allowlist check (docs/080 §10.4): both allowlists hold exactly one entry, identical to each
#     other and spelled exactly (letter case) like your username from step (e). Values are read from the
#     Secrets and the users table; nothing is typed in.
HUB_ALLOW="$(kubectl -n apps get secret mcp-hub-secrets --request-timeout=10s -o jsonpath='{.data.allowed-subjects}' | base64 -d)"
AUTH_ALLOW="$(kubectl -n apps get secret homelab-auth-secrets --request-timeout=10s -o jsonpath='{.data.claude-mcp-hub-allowed-users}' | base64 -d | sed 's/^ *//;s/ *$//')"
[ -n "$HUB_ALLOW" ] && [ "$(printf '%s\n' "$HUB_ALLOW" | wc -l | tr -d ' ')" = 1 ] && echo "hub allowlist: one entry" || echo "hub allowlist: NOT exactly one entry"
[ "$HUB_ALLOW" = "$AUTH_ALLOW" ] && echo "allowlists match" || echo "allowlists DIFFER"
kubectl -n apps exec -i postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -tA -v u="$HUB_ALLOW" <<'SQL'
SELECT count(*) FROM users WHERE username = :'u' AND role = 'ADMIN' AND status = 'ACTIVE';
SQL
# expect 1: the entry is a stored active ADMIN username, exact spelling
printf '%s\n' "$HUB_ALLOW"   # must be the line of step (e) that is your username
unset HUB_ALLOW AUTH_ALLOW

# (l) Tunnel route + DNS — after the tunnel-route PR is merged. Pull main again, check the route, run playbook 40.
git switch main && git pull --ff-only
grep -n 'mcp.furchert.ch' infra/playbooks/40_platform.yml
ansible-playbook infra/playbooks/40_platform.yml
kubectl -n platform logs -l app=cloudflared --tail=20 --request-timeout=10s
```

DNS record (Cloudflare dashboard → `furchert.ch` → DNS → Records → Add record): Type `CNAME`, Name `mcp`, Target: the same `….cfargotunnel.com` value as the existing `auth` record, Proxy status **Proxied**, TTL Auto. Do not add the hostname under Zero Trust → Tunnels → Public hostnames: playbook 40 replaces the whole tunnel configuration.

```bash
# (m) Unauthenticated check — BEFORE the WAF allow rule exists (afterwards it is blocked from outside):
curl -sS -i -X POST https://mcp.furchert.ch/mcp | sed -n '1p;/^www-authenticate/Ip'
# expect: HTTP/2 401 and a WWW-Authenticate line with resource_metadata=… and scope="mail:read calendar:read"
curl -sS https://mcp.furchert.ch/.well-known/oauth-protected-resource/mcp
# expect: {"resource":"https://mcp.furchert.ch/mcp","authorization_servers":["https://auth.furchert.ch"],…}
```

```bash
# (n) Hub restart after every change of accounts.json (stage b and every later registry change), after playbook 59:
kubectl -n apps delete pod -l app=mcp-hub
n=0; until [ "$(kubectl -n apps get pods -l app=mcp-hub --request-timeout=10s -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}')" = "true" ] || [ $n -ge 36 ]; do n=$((n+1)); sleep 5; done
kubectl -n apps get pods -l app=mcp-hub --request-timeout=10s
# expect one pod, READY 1/1, a new AGE (the loop gives up after 3 min; if it did, read the log below)
kubectl -n apps logs deploy/mcp-hub --tail=20 --request-timeout=10s
```

```bash
# (o) Deployed-image check before the first login (docs/080 §4.5 "Production evidence", §10.4): the running
#     auth-service and device-service images must be built after the merge of their gate tests.
#     Image tags are main-YYYYMMDDTHHMMSS (UTC build time); merge times come from GitHub (UTC).
AS_TAG="$(kubectl -n apps get deploy auth-service --request-timeout=10s -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*:main-//')"
AS_MERGED="$(gh pr list -R doemefu/homelab-auth-service --head feat/107-mcp-hub-client --state merged --json mergedAt --jq '.[0].mergedAt' | tr -d ':-' | sed 's/Z$//')"
DS_TAG="$(kubectl -n apps get deploy device-service --request-timeout=10s -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*:main-//')"
DS_MERGED="$(gh pr list -R doemefu/homelab-device-service --head test/88-reject-hub-tokens --state merged --json mergedAt --jq '.[0].mergedAt' | tr -d ':-' | sed 's/Z$//')"
printf 'auth-service   image %s  merged %s\n' "$AS_TAG" "$AS_MERGED"
printf 'device-service image %s  merged %s\n' "$DS_TAG" "$DS_MERGED"
[[ -n "$AS_MERGED" && "$AS_TAG" > "$AS_MERGED" ]] && echo "auth-service: OK" || echo "auth-service: NOT newer than the #107 merge - stop"
[[ -n "$DS_MERGED" && "$DS_TAG" > "$DS_MERGED" ]] && echo "device-service: OK" || echo "device-service: NOT newer than the #88 merge - stop"
kubectl -n apps get pods -l app=auth-service --request-timeout=10s -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
kubectl -n apps get pods -l app=device-service --request-timeout=10s -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
# expect: both "OK" lines, and the running pods show the same images as the Deployments
unset AS_TAG AS_MERGED DS_TAG DS_MERGED
```

**Abort paths during the go-live** (docs/080 §11.1; after an abort the stage-a state is safe: `icloud` is disabled and no provider credential is in the cluster; every step is an owner action):

- **Hub not Ready after the Flux bundle is applied** (step (j)): stop. The tunnel route is not merged yet, so nothing is exposed. Read `kubectl -n apps get pods -l app=mcp-hub --request-timeout=10s`, `kubectl -n apps logs deploy/mcp-hub --tail=50 --request-timeout=10s` and `flux get kustomizations mcp-hub -n flux-system`, fix the cause (Troubleshooting below), retry from step (j).
- **Route applied, but a later check fails** (zone settings, the unauthenticated check (m), `invalid_target`, the rate-limit rule blocking the login): take the host off the internet — revert the tunnel-route pull request and run playbook 40 from an updated `main`, or delete the DNS record `mcp` in the Cloudflare dashboard (faster; the tunnel route alone then serves nothing). If a token was already issued, also run L2 step 1 ("mcp-hub incident runbook").

```bash
gh pr list -R doemefu/homelab --head feat/177-mcp-hub-tunnel-route --state merged --json number,mergeCommit --jq '.[0] | "\(.number) \(.mergeCommit.oid)"'
# revert: open a revert pull request of that merge commit (GitHub -> the PR -> "Revert"), merge it with your go, then:
git switch main && git pull --ff-only
grep -c 'mcp.furchert.ch' infra/playbooks/40_platform.yml   # expect 0
ansible-playbook infra/playbooks/40_platform.yml
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://mcp.furchert.ch/mcp   # expect 404 (catch-all) or a DNS error
```

- **First login fails:** if a token was issued (the hub log shows `sub` for the owner), run L2 step 1. A refused login ("access denied" at auth-service) → "Recovery: login refused for `claude-mcp-hub`". Any other failure → take the route off as above until the cause is found.
- **WAF allow rule breaks the connection** (tool calls fail after step 11): dashboard `furchert.ch` → Security → WAF → Custom rules → `mcp-hub: only Anthropic egress` → Disable. The connector works without it; re-check Anthropic's published range before enabling it again.

**Troubleshooting.** `ImagePullBackOff` on `main-20260928T000000` right after the first rollout: expected until image automation has committed the first real tag (step (j): package public (b), write deploy key (a), ruleset (c)). `CrashLoopBackOff` and a `startup_failed` line about the registry in the log: `accounts.json` passed the playbook checks but not the hub's schema (for example an unknown field or missing `capabilities`) — fix `mcp_hub_accounts` in SOPS, run playbook 59, then step (n).

Backups need no change now; `mcp_hub` (a database added with #171) will be dumped by `scripts/backup-app-data.sh` automatically.

#### Cloudflare rules (owner, dashboard; recreate from these settings)

**Edge rate-limit rule on the login service** (docs/080 §4.7, D32) — create before the first production login; remove or relax once homelab-auth-service#104 lands. Dashboard: `furchert.ch` → Security → WAF → Rate limiting rules → Create rule. Action **Block**, never a challenge (Claude cannot solve one); never block the whole Anthropic range.

| Setting | Business plan or higher (preferred) | Free plan (fields limited to Path, period and block fixed at 10 s) |
|---------|--------------------------------|---------------------------------------------------------------------|
| Name | `auth-service: token and login` | `auth-service: token and login` |
| Expression | `(http.host eq "auth.furchert.ch" and http.request.method eq "POST" and (http.request.uri.path eq "/oauth2/token" or http.request.uri.path eq "/login"))` | `(http.request.uri.path eq "/oauth2/token" or http.request.uri.path eq "/login")` |
| Counting | Per IP | Per IP |
| Rate | 30 requests per 1 minute | 5 requests per 10 seconds |
| Block duration | 1 minute | 10 seconds |

Method is a rate-limiting field only from the Business plan on. On a Pro zone use the Business expression without `http.request.method eq "POST" and`, with the same counting, rate and block duration; it then also counts `GET /login`. On a Free zone the rule also counts `GET /login` and `/login` on other hostnames of the zone; normal use (one token request per 10-minute token, one or two login requests per sign-in) stays far below 5 per 10 s.

**WAF allow rule on `mcp.furchert.ch`** (docs/080 §4.7, D31) — after the first successful production connection and the §10.4 checks. First confirm on Anthropic's published IP page (`https://platform.claude.com/docs/en/api/ip-addresses`) that `160.79.104.0/21` is still the only outbound range. Dashboard: Security → WAF → Custom rules → Create rule:

| Setting | Value |
|---------|-------|
| Name | `mcp-hub: only Anthropic egress` |
| Expression | `(http.host eq "mcp.furchert.ch" and not ip.src in {160.79.104.0/21})` |
| Action | Block |

Then ask Claude to list the accounts once more (stage a); the tool call must still work. Not applied to `auth.furchert.ch`.

### mcp-hub incident runbook — cutting access

**Access is always cut on the homelab side.** Removing the connector in claude.ai sends no revocation and is not a lever; the refresh token held by claude.ai stays valid until L4 or L5. The `claude-mcp-hub` allowlist in auth-service is not a lever either: it covers new logins only. Source: `docs/080-mcp-hub.md` §4.6. Every lever below except L1 changes the cluster or the database and needs the owner's go. Off-LAN, run the `kubectl` lines through "One-shot kubectl over SSH" (the off-LAN form of L2 step 1 is given below).

| # | Lever | Effect | Speed |
|---|-------|--------|-------|
| L1 | Cloudflare block rule on `mcp.furchert.ch` | nothing reaches the hub | seconds; works without cluster access |
| L2 | Hub kill switch, two steps | every token gets 401 | ≤ 2 min after step 1 (the new pod starts with the empty list) |
| L3 | Stop the hub | hub down | seconds |
| L4 | Delete the client's authorizations | refresh fails; issued access tokens live ≤ 10 min | immediate for refresh |
| L5 | Rotate the client secret | old secret useless | minutes |
| L6 | Provider side (hub compromise suspected) | layer-2 credentials renewed | minutes to hours |
| — | Disable and remove the `claude-mcp-hub` client (below) — mandatory before any auth-service rollback once the client is seeded | client gone; no token for the hub any more | minutes |

**L1 — Cloudflare block.** Dashboard `furchert.ch` → Security → WAF → Custom rules → Create rule: name `mcp-hub: incident block`, expression `(http.host eq "mcp.furchert.ch")`, action Block, Deploy. One custom-rule slot of the zone's plan is kept free for this rule at all times — do not use it for anything else. Fallback only if the slot was used after all: edit the rule `mcp-hub: only Anthropic egress` and set its expression to `(http.host eq "mcp.furchert.ch")`. Undo: delete the incident rule, or restore the allow rule's expression from "Cloudflare rules".

**L2 — Hub kill switch, two steps.** Step 1 alone is undone by the next playbook-59 run for any service; step 2 makes it persistent. Step 1 is two commands: empty the allowlist, then delete the hub pod, so the new pod starts with the empty list and refuses every token as soon as it is Ready (an empty or missing file means nobody). If the pod delete is forgotten, the running hub still picks up the empty file on its own (kubelet refresh plus the hub's re-read every 60 s), but that can take up to about 3 minutes.

```bash
# Step 1 — immediately (LAN):
kubectl -n apps patch secret mcp-hub-secrets --type merge -p '{"stringData":{"allowed-subjects":""}}'
kubectl -n apps delete pod -l app=mcp-hub
# Step 1 — off-LAN, one shot over SSH (both commands):
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps patch secret mcp-hub-secrets --type merge -p "{\"stringData\":{\"allowed-subjects\":\"\"}}" && sudo k3s kubectl -n apps delete pod -l app=mcp-hub'
# Confirm the new pod is Ready (repeat until one pod shows 1/1) and its file is empty:
kubectl -n apps get pods -l app=mcp-hub --request-timeout=10s
kubectl -n apps exec deploy/mcp-hub --request-timeout=10s -- wc -c /etc/mcp-hub/secrets/allowed-subjects   # expect: 0 …

# Step 2 — then: set  mcp_hub_allowed_subjects: []  in SOPS.
sops infra/inventory/group_vars/all.sops.yml
```

Re-enable: SOPS first (put the username back into `mcp_hub_allowed_subjects`), then `ansible-playbook infra/playbooks/59_app_services.yml`. No restart and no re-login is needed; access returns within about 3 minutes (kubelet refresh plus the 60 s re-read).

**L3 — Stop the hub.** A plain scale is reverted by Flux, so suspend first:

```bash
flux suspend kustomization mcp-hub -n flux-system
kubectl -n apps scale deploy/mcp-hub --replicas=0
# undo: Flux restores the replica count from the hub repository
flux resume kustomization mcp-hub -n flux-system
```

Optional drill for L3: after the suspend, wait at least 10 minutes (one `apps` reconcile), then `flux get kustomizations mcp-hub -n flux-system` must still show `SUSPENDED True`, which proves that the reconcile of the parent `apps` Kustomization does not undo the suspend; if it shows `False`, rely on L1 or L2 instead of L3.

**L4 — Revoke the consents and authorizations of `claude-mcp-hub`** (`registered_client_id` holds the internal id, not the client id). auth-service stores consent in the database, so the consent rows are deleted first, then the authorizations, in one transaction (the block's own `BEGIN;` … `COMMIT;`; with `ON_ERROR_STOP=1` a failing statement aborts before `COMMIT`, so both or neither). The next refresh fails and claude.ai asks for a new login; access tokens already issued expire within 10 minutes. **Check that it worked:** the next login shows the consent page again.

```bash
kubectl -n apps exec -i postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
DELETE FROM oauth2_authorization_consent
 WHERE registered_client_id = (SELECT id FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub');
DELETE FROM oauth2_authorization
 WHERE registered_client_id = (SELECT id FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub');
COMMIT;
SQL
# expect BEGIN, two DELETE lines (first the consents, then the authorizations), COMMIT
```

(The SQL block is the binding L4 revocation block of the auth-service plan (§2 Context), copied verbatim — the amended spec 080 §4.6 L4 statement exactly as the auth-service gate test runs it — homelab-auth-service#107, `McpHubConsentPersistenceGateTest`; do not reword or reflow it.)

Alternative: reset your auth-service password — this revokes all your authorizations, including other relying parties. When you stop using the hub for good, removing the connector is not enough: run L4.

**L5 — Rotate the client secret.** The seeder never updates an existing client, so the database row and SOPS are both changed; otherwise a database restore or a reseed brings the old secret back. Run L4 first.

```bash
MCP_HUB_CLIENT_SECRET="$(openssl rand -hex 32)"
printf '%s\n' "$MCP_HUB_CLIENT_SECRET"      # store in the password manager; needed when re-adding the connector
MCP_HUB_CLIENT_SECRET_BCRYPT="{bcrypt}$(printf '%s' "$MCP_HUB_CLIENT_SECRET" | htpasswd -niBC 10 claude-mcp-hub | cut -d: -f2- | tr -d '\n')"
printf "\\set h '%s'\nUPDATE oauth2_registered_client SET client_secret = :'h' WHERE client_id = 'claude-mcp-hub';\n" "$MCP_HUB_CLIENT_SECRET_BCRYPT" \
  | kubectl -n apps exec -i postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -v ON_ERROR_STOP=1
# expect: UPDATE 1
printf '%s\n' "$MCP_HUB_CLIENT_SECRET_BCRYPT"  # -> SOPS auth_service_claude_mcp_hub_client_secret (single quotes)
unset MCP_HUB_CLIENT_SECRET MCP_HUB_CLIENT_SECRET_BCRYPT
sops infra/inventory/group_vars/all.sops.yml
ansible-playbook infra/playbooks/59_app_services.yml
```

Then remove the connector in claude.ai and add it again with the new secret (authentication settings cannot be edited in place).

**L6 — Provider side** (only if a hub compromise is suspected; every layer-2 credential counts as exposed): revoke the `icloud` app-specific password in the Apple Account settings and the `gmail` app password in the Google Account settings; revoke the app consent and sessions of the Microsoft accounts (`outlook`, and `uzh` if it uses Graph); reset a published calendar address if one is used. Put new values into SOPS and run playbook 59 (same key names: no restart needed); for Microsoft accounts (from #171) run `kubectl -n apps exec -it deploy/mcp-hub -- mcp-hub login outlook` (docs/080 §7.3).

**Recovery: login refused for `claude-mcp-hub`** (auth-service rejects the owner, for example an empty allowlist or a different letter case):

```bash
# 1. Correct auth_service_claude_mcp_hub_allowed_users (username exactly as printed by the query in onboarding step (e)).
sops infra/inventory/group_vars/all.sops.yml
# 2. Playbook 59 (from a checkout on main).
ansible-playbook infra/playbooks/59_app_services.yml
# 3. Restart auth-service so it reads the new value (a rollout restart would be reverted by Flux).
kubectl -n apps delete pod -l app=auth-service
```

Then press "Connect" (or add the connector) again in claude.ai.

**Disable and remove the `claude-mcp-hub` client** (required before any auth-service rollback). Once the client has been seeded in production, reverting the auth-service change that added it, deploying an older auth-service image, or removing or renaming its configuration entry is allowed only **after** the client has been disabled and removed with this procedure: a registered-client row without the code and configuration that shape its tokens keeps claude.ai's refresh token working and issues tokens without the audience binding and the owner-only check. Emptying or removing the client secret alone does **not** disable a client that has already been seeded. Every step needs the owner's go. Before the client was ever seeded (the check query at the end already returns `0`), no step is needed.

Order: (1) cut the hub off with L2 step 1; (2) remove both SOPS variables of the client and run playbook 59; (3) remove the two keys from `homelab-auth-secrets` by hand, one JSON patch per key — playbook 59 only skips them once the variables are gone and never deletes a key; (4) run the client-removal SQL; (5) check that the row is gone; (6) only then merge the auth-service revert or configuration change (in `homelab-auth-service`, not in this repository). The keys are removed **before** the SQL on purpose: auth-service seeds the client only at start-up and only while the secret is set, so a restart of auth-service between the two steps cannot create the client again. `mcp-hub-secrets` and the hub deployment are independent of this procedure; they can stay or be removed separately (L3).

```bash
# 1. L2 step 1 (LAN): empty the hub allowlist and restart the hub.
kubectl -n apps patch secret mcp-hub-secrets --type merge -p '{"stringData":{"allowed-subjects":""}}'
kubectl -n apps delete pod -l app=mcp-hub

# 2. SOPS: delete the lines auth_service_claude_mcp_hub_client_secret and auth_service_claude_mcp_hub_allowed_users
#    (both; with only one of them the play fails). Then playbook 59 from a checkout on main.
sops infra/inventory/group_vars/all.sops.yml
ansible-playbook infra/playbooks/59_app_services.yml
# expect the message "skipping the claude-mcp-hub keys in homelab-auth-secrets"

# 3. Remove each key with its own JSON patch, only if it still exists (the playbook leaves existing keys in place),
#    then list the key names only. jq exit 0 = key present, 1 = already gone, anything else = the Secret could not be read.
for k in claude-mcp-hub-client-secret claude-mcp-hub-allowed-users; do
  kubectl -n apps get secret homelab-auth-secrets --request-timeout=10s -o json | jq -e --arg k "$k" '.data[$k]' >/dev/null
  case $? in
    0) kubectl -n apps patch secret homelab-auth-secrets --type json -p "[{\"op\":\"remove\",\"path\":\"/data/$k\"}]" ;;
    1) echo "$k is already gone - skipped" ;;
    *) echo "could not read homelab-auth-secrets - stop and check cluster access before going on"; break ;;
  esac
done
kubectl -n apps get secret homelab-auth-secrets --request-timeout=10s -o json | jq '.data | keys'
# expect: neither claude-mcp-hub-client-secret nor claude-mcp-hub-allowed-users in the list

# 4. Client-removal SQL (consents, authorizations, registered-client row; one transaction).
kubectl -n apps exec -i postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
DELETE FROM oauth2_authorization_consent
 WHERE registered_client_id = (SELECT id FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub');
DELETE FROM oauth2_authorization
 WHERE registered_client_id = (SELECT id FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub');
DELETE FROM oauth2_registered_client
 WHERE client_id = 'claude-mcp-hub';
COMMIT;
SQL
# expect BEGIN, three DELETE lines (the last one DELETE 1), COMMIT

# 5. Check: the client row is gone.
kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -tAc \
  "SELECT count(*) FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub'"
# expect 0 — only now merge the auth-service revert or configuration change
```

Off-LAN, run steps 1 and 3–5 over SSH; step 2 (SOPS edit and playbook 59) runs as described in "Off-LAN kubectl / Ansible Access":

```bash
# 1. L2 step 1
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps patch secret mcp-hub-secrets --type merge -p "{\"stringData\":{\"allowed-subjects\":\"\"}}" && sudo k3s kubectl -n apps delete pod -l app=mcp-hub'
# 3. Remove each key with its own JSON patch, only if it still exists; then list the key names only (values are not printed)
for k in claude-mcp-hub-client-secret claude-mcp-hub-allowed-users; do
  ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
    'sudo k3s kubectl -n apps get secret homelab-auth-secrets -o json' | jq -e --arg k "$k" '.data[$k]' >/dev/null
  case $? in
    0) ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
         "sudo k3s kubectl -n apps patch secret homelab-auth-secrets --type json -p '[{\"op\":\"remove\",\"path\":\"/data/$k\"}]'" ;;
    1) echo "$k is already gone - skipped" ;;
    *) echo "could not read homelab-auth-secrets - stop and check the SSH access before going on"; break ;;
  esac
done
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps get secret homelab-auth-secrets -o json' | jq '.data | keys'
# 4. Client-removal SQL (same block, read from stdin)
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps exec -i postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -v ON_ERROR_STOP=1' <<'SQL'
BEGIN;
DELETE FROM oauth2_authorization_consent
 WHERE registered_client_id = (SELECT id FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub');
DELETE FROM oauth2_authorization
 WHERE registered_client_id = (SELECT id FROM oauth2_registered_client WHERE client_id = 'claude-mcp-hub');
DELETE FROM oauth2_registered_client
 WHERE client_id = 'claude-mcp-hub';
COMMIT;
SQL
# 5. Check
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -tAc "SELECT count(*) FROM oauth2_registered_client WHERE client_id = '\''claude-mcp-hub'\''"'
```

Step 3 checks each key before its patch and skips a key that is already gone, so a partly removed Secret does not stop the procedure; if the Secret cannot be read, the loop stops with a message instead of skipping. The SQL block is the binding client-removal block of the auth-service plan, copied verbatim (gate test `McpHubConsentPersistenceGateTest`, homelab-auth-service#107); do not reword or reflow it.

**Scoping an incident:** hub log lines carry `sub`, `client_id`, `jti` and the tool name per call (`kubectl -n apps logs deploy/mcp-hub --since=24h --request-timeout=10s`); auth-service logins are in data-service's `netmon.login_events`.

#### Incident drill (after go-live; target ≤ 2 min, owner go)

```bash
date -u +%T                                                   # T0 (the patch)
kubectl -n apps patch secret mcp-hub-secrets --type merge -p '{"stringData":{"allowed-subjects":""}}'
kubectl -n apps delete pod -l app=mcp-hub
n=0; until [ "$(kubectl -n apps exec deploy/mcp-hub --request-timeout=10s -- sh -c 'wc -c < /etc/mcp-hub/secrets/allowed-subjects' 2>/dev/null | tr -d ' ')" = "0" ] || [ $n -ge 36 ]; do n=$((n+1)); sleep 5; done; date -u +%T   # new pod up, file empty (gives up after 3 min)
```

Then ask Claude to list the accounts (stage a; after stage b any tool works) every 15 s until the call fails, and note the time of the first refused call (T1); check the hub log for the rejection (`kubectl -n apps logs deploy/mcp-hub --since=5m --request-timeout=10s`). Record T0, the "file empty" time and T1 separately. Pass: T1 − T0 ≤ 2 min. (Without the pod delete, the worst case is about 150–165 s: kubelet Secret sync up to about 1.5 min plus the hub's 60 s re-read plus the 15 s asking interval — the reason for the pod delete.) If the loop gave up after 3 min, the file is not readable in the pod or the pod did not start: check `kubectl -n apps get pods -l app=mcp-hub --request-timeout=10s` and the log. Restore without touching SOPS (step 2 was not done in the drill): `ansible-playbook infra/playbooks/59_app_services.yml`; within about 3 minutes the next tool call works without a new login. L1 drill (docs/080 §10.4): create the L1 rule `mcp-hub: incident block` in the free custom-rule slot, ask Claude to list the accounts once — the call must be refused — then delete the rule and confirm that the next call works again (the free slot is free again). L4 drill: run L4, then ask Claude again — it must ask for a new login; reconnect, and the consent page must appear again (proof that the consent row was removed).

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

If no reconnect shows up within about 2 minutes, force it: `kubectl -n apps delete pod
-l app=device-service` (Flux undoes `rollout restart`, see "Enable order (NM-4)"), then re-check the logs.

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
flux reconcile kustomization mcp-hub -n flux-system --with-source
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

### MacBook nodes: controlled reboots (#102)

Both MacBook Air workers are power-cycled by their T2 chip at monotonic **432 000 s (5 d) ± 10 s
after every host boot**. The journal of every crashed boot ends with the apple-bce driver tearing
down the T2's virtual USB host controller (`bce_vhci_free_device`), there is no oops, no panic, no
thermal event, and `/sys/fs/pstore/` is empty — the reset is initiated by the firmware, below
Linux. mba2 has done this on an unbroken 5-day cycle since 2026-04-13, mba1 since 2026-07-02.

The mitigation is a schedule, not a fix: keep every boot shorter than five days. Two pieces run on
the nodes.

**1. A daily timer with an uptime guard** (`mac_tweaks` role). `homelab-scheduled-reboot.timer`
fires once a day and runs a script that reboots **only** when `/proc/uptime` is at least
`mac_tweaks_reboot_min_uptime_seconds` (3.5 d), otherwise it logs `no reboot needed` and exits 0.
Worst case is therefore 3.5 d + 1 d = 4.5 d, twelve hours before the deadline, and the schedule
re-derives itself from actual uptime after any unplanned reboot. The script uses
`systemctl --no-block reboot`: only the logind path honours the kubelet's shutdown inhibitor, and
`--no-block` keeps the oneshot unit out of its own shutdown transaction.

| Node | Slot | Why |
|------|------|-----|
| `mba2` | `*-*-* 06:10:00` | after the 05:00 `metrics-filesystem-trim` window |
| `mba1` | `*-*-* 07:40:00` | 90 min after mba2, so a Longhorn rebuild finishes first |

Slots and threshold are role defaults (`infra/roles/mac_tweaks/defaults/main.yml`), so the role
works without inventory edits. Override a single host from the untracked inventory
(`host_vars/<node>.yml`) or with `-e mac_tweaks_reboot_on_calendar="*-*-* 08:00:00"`.

**2. Kubelet graceful node shutdown** (`k3s` role, `mac` group only). The kubelet gets
`shutdownGracePeriod: 60s` / `shutdownGracePeriodCriticalPods: 20s` through
`/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-graceful-shutdown.conf`. k3s passes
`--config-dir` for that directory and merges every `*.conf` at start; the `00-`/`10-`/`20-`
prefixes are k3s' own (it rewrites `00-k3s-defaults.conf` at every start), which is why ours is
`50-`. Do **not** switch this to `--kubelet-arg=config=`: k3s strips that flag and copies the file
in one-way as `10-cli-config.conf`, which a rollback would not revert.

On a **fresh** node the drop-in directory does not exist until k3s-agent has started once, so the
role installs and starts the agent first and only then waits (up to 150 s) for
`00-k3s-defaults.conf`, fails loudly if it never appears, and writes the drop-in.

This only works if logind's inhibitor delay is at least as long as the grace period. Ubuntu caps it
at 30 s (`/usr/lib/systemd/logind.conf.d/unattended-upgrades-logind-maxdelay.conf`), and when the
kubelet cannot raise it, it logs `Failed to start node shutdown manager` **and carries on with the
feature disabled** — a silent degradation. The `mac_tweaks` role therefore ships
`/etc/systemd/logind.conf.d/zz-homelab-kubelet.conf` with `InhibitDelayMaxSec=60`; the `zz-` prefix
wins logind's lexical merge and Ubuntu's file is left untouched.

**Rollout order matters**: `10_base.yml` (logind delay) before `20_k3s.yml` (kubelet), and one node
at a time — mba2 first, mba1 at least 60 minutes later.

```bash
# mba2 first. --diff is safe here.
ansible-playbook infra/playbooks/10_base.yml -l mba2 --tags mac_tweaks --check --diff
ansible-playbook infra/playbooks/10_base.yml -l mba2 --tags mac_tweaks

# 20_k3s.yml: --check only, NEVER --diff. k3s-agent.service.j2 embeds K3S_TOKEN, so a
# diff of that template prints the token to the terminal and into any log.
ansible-playbook infra/playbooks/20_k3s.yml -l mba2 --check
ansible-playbook infra/playbooks/20_k3s.yml -l mba2

# Then repeat both for mba1, >= 60 min later.
```

**Verify** (before the first scheduled fire; safe while uptime is below the threshold):

```bash
ssh ansible@<mba-ip> "systemctl list-timers homelab-scheduled-reboot.timer --all"
ssh ansible@<mba-ip> "sudo systemd-analyze verify /etc/systemd/system/homelab-scheduled-reboot.timer"
ssh ansible@<mba-ip> "systemd-analyze calendar '*-*-* 06:10:00' --iterations=3"

# Functional test — this is not a passive check: below the threshold it prints "no reboot
# needed" and exits 0, but once uptime >= mac_tweaks_reboot_min_uptime_seconds (3.5 d) this
# command IS the reboot. That makes it the recommended, attended end-to-end test: run it
# deliberately once a node's uptime crosses 3.5 d (mba2 first, mba1 >= 60 min later) and
# watch the graceful shutdown end to end — kubectl -n apps logs postgresql-0 --previous |
# tail -5 for "database system is shut down" and journalctl -u k3s-agent -f for the
# shutdown-manager handoff — instead of waiting for the unattended timer slot.
ssh ansible@<mba-ip> "cat /proc/uptime; sudo systemctl start homelab-scheduled-reboot.service && \
  journalctl -u homelab-scheduled-reboot -n 5 --no-pager"

# logind delay: 30 s before the rollout, 60 s after
ssh ansible@<mba-ip> "busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager InhibitDelayMaxUSec"
ssh ansible@<mba-ip> "systemd-analyze cat-config systemd/logind.conf | grep -n -B2 -A2 InhibitDelayMaxSec"

# Inhibitor lock: expect a kubelet "delay" lock for shutdown here. The role's
# flush_handlers restarts systemd-logind mid-role, which drops any held inhibitor locks;
# whether kubelet 1.32 re-acquires one without its own restart is unverified — check this
# explicitly rather than assuming the busctl delay above means a lock is actually held.
ssh ansible@<mba-ip> "systemd-inhibit --list"

# Kubelet: the drop-in is in place and the shutdown manager did NOT give up
ssh ansible@<mba-ip> "sudo ls -l /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/"
ssh ansible@<mba-ip> "sudo journalctl -u k3s-agent -b --no-pager | grep -i 'shutdown manager'"
```

**Mandatory gate — did the scheduled reboot actually complete?** Before treating any given
night as a test of the T2 hypothesis, confirm on the morning after the first expected slot
(e.g. 2026-09-20 at 08:30 CEST or later) that each node picked up a new boot at its slot time:

```bash
ssh ansible@<mba-ip> "sudo journalctl --list-boots"                 # new boot ≈ 06:10 (mba2) / ≈ 07:40 (mba1)
ssh ansible@<mba-ip> "last -x reboot shutdown | head -5"            # a shutdown entry, not a bare crash
ssh ansible@<mba-ip> "systemctl list-timers homelab-scheduled-reboot.timer --all"   # timer activation, not just the service outcome
ssh ansible@<mba-ip> "sudo journalctl -u homelab-scheduled-reboot -b -1 --no-pager"
  # expect: "uptime <n>s >= <min_uptime>s — rebooting before the T2 5-day reset"; read the
  # full unit journal, not just the tail — "no reboot needed" here would itself be unexpected
  # once uptime has passed the 3.5 d threshold, and is a different failure mode from the timer
  # never having activated at all
```

If there is no boot at the expected slot time, no shutdown entry, or no matching "rebooting
before the T2 5-day reset" line, the scheduled reboot did not complete — but that alone does
not prove the timer never fired. Check timer activation (`systemctl list-timers`) and the
service's own journal separately: the timer can activate and the service can still exit
without rebooting (e.g. a stale uptime read) or fail mid-run. Diagnose which of the three
failed (see Troubleshooting) and re-run before drawing any conclusion about the T2 hypothesis.

After the first scheduled reboot, the fuller verification:

```bash
ssh ansible@<mba-ip> "last -x reboot shutdown | head -5"          # a shutdown entry, not a bare crash
ssh ansible@<mba-ip> "uptime -s; journalctl --list-boots | tail -3"
ssh ansible@<mba-ip> "journalctl -u homelab-scheduled-reboot -b -1 --no-pager | tail -3"
ssh ansible@<mba-ip> "sudo journalctl -b -1 -u k3s-agent --no-pager | grep -i shutdown"
kubectl -n apps logs postgresql-0 --previous | tail -5            # "database system is shut down"
kubectl get nodes -o wide
kubectl -n longhorn-system get volumes.longhorn.io                # all robustness=healthy
```

**How to read 2026-09-20/21**

| Observation | Meaning |
|---|---|
| 09-20 ≥ 08:30: new boot ≈ 06:10/07:40, shutdown entry in `last -x`, service journal line present | Scheduled reboot completed — the night is a valid test of the T2 hypothesis. |
| 09-20 ≥ 08:30: no such boot | Scheduled reboot did not complete — the night proves nothing. Check timer activation and the service journal separately before assuming it's a timer bug; fix and re-run. |
| 09-21: `uptime -s` still shows the 09-20 morning boot, no later boot | Hypothesis TRUE (the countdown restarts at host boot) — keep the mitigation as-is. |
| 09-21: a boot ≈ 09-20 21:39 CEST (mba2) / ≈ 22:50 CEST (mba1), previous journal ending at monotonic ≈ 55 700 s / ≈ 54 600 s, no shutdown record | Hypothesis FALSE (phase-locked to the T2, not to host-boot age) — a five-figure end-of-journal instead of ≈ 432 000 s is the cleanest proof; apply the fallback section below or the rollback. |
| 09-21: boot at any other time, or journal ending at a third monotonic value | Unrelated failure — investigate separately, do not attribute it to the T2 cycle. |

**Rollback**, one variable each, both idempotent. Trigger: a node still resets at its 5-day
mark on 2026-09-20 evening even though its scheduled reboot completed that morning (per the
mandatory gate above) — that means the reboot does not reset the T2 countdown, so run this on
2026-09-21, or apply the fallback section below instead; otherwise the timer just adds one
pointless reboot per cycle without preventing the reset:

```bash
ansible-playbook infra/playbooks/10_base.yml -l <node> --tags mac_tweaks -e mac_tweaks_reboot_enabled=false
ansible-playbook infra/playbooks/20_k3s.yml  -l <node> -e k3s_graceful_shutdown_enabled=false
```

**If a warm reboot does not reset the T2 countdown**, the timer cannot prevent the reset — it can
only make sure the node is drained and cleanly stopped when it fires. In that case keep the
plumbing and replace the uptime guard with a phase guard derived from a pinned per-node
reference. Re-pinned from the 2026-09-15 boots — mba2 `2026-09-15 21:39:09`, mba1
`2026-09-15 22:50:46` — +5 d per cycle, drifting +54 s / +62 s (measured boot-to-boot deltas
432 054 s / 432 062 s, 2026-09-10 → 2026-09-15); fire the timer every 15 minutes, and escalate:
move the stateful workloads off the MacBooks and take the root cause upstream to t2linux. That
reference has to be re-pinned every few months. Each crashed boot's journal still ends at
monotonic ≈ 431 940–431 975 s (the reset itself lands ≈ 432 000–432 018 s in), but the
`bce_vhci_free_device` teardown line that used to mark the cut was absent on the 2026-09-15
cycle — do not rely on it as the reset's signature; the monotonic-time window above is the only
signal confirmed so far.

**The `softdog` watchdog was removed** (`mac_tweaks_watchdog_enabled: false`). It never worked on
the t2 kernels — there is no `/dev/watchdog`, `softdog` does not load, and `watchdog.service` sat
in `failed` state on both nodes — and a software watchdog cannot stop a firmware power cut anyway.
Leaving it enabled also made `10_base.yml` fail on the Macs, because the service task runs with
`state: started` and the `modprobe` task is unguarded (a `--check` run passes, a real run does
not). The role's cleanup branch removes `/etc/watchdog.conf` and
`/etc/modules-load.d/watchdog.conf` on the next run.

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
| Verify Longhorn recurring snapshot jobs fired | Weekly | `kubectl -n longhorn-system get recurringjobs.longhorn.io daily-snapshot metrics-snapshot-cleanup metrics-filesystem-trim` + `kubectl -n longhorn-system get snapshots.longhorn.io` (see "Recurring Snapshots (#63)" and "Excluded volumes: the metrics group (#101)" above) |
| Verify the metrics-group trim is still working | Weekly | `kubectl -n longhorn-system get volumes.longhorn.io <prometheus-volume> -o jsonpath='{.status.actualSize}'` (flat, not trending towards 40 G) + `kubectl -n longhorn-system logs <latest metrics-filesystem-trim pod>` showing `Finished recurring filesystem trim` — every failure mode of the trim is silent; alerting is tracked in #92 |
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
| `10_base.yml` | Base packages, hardening, UFW, fail2ban, MacBook scheduled reboot (#102) | 3-5 min | Yes |
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
