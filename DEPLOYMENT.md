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
ansible-playbook infra/playbooks/55_club_mcp.yml

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
| `platform` | cert-manager (3x), cloudflared (2x, on different nodes) | Running |
| `longhorn-system` | longhorn-manager (2x), longhorn-ui (2x), csi-*, engine-image, instance-manager | Running |
| `monitoring` | prometheus-*, grafana-*, alertmanager-*, kube-state-metrics-*, node-exporter-*, coroot-node-agent-* (only on gated nodes — see "coroot-node-agent (NM-2)") | Running |
| `apps` | postgresql-0, influxdb2-0, mosquitto-*, auth-service-*, device-service-*, furchert-ch-*, data-service-*, mcp-hub-*, n8n-*, litellm-*, open-webui-* | Running |
| `homeassistant` | home-assistant-0 | Running |
| `flux-system` | source-controller, kustomize-controller, helm-controller, notification-controller, image-reflector-controller, image-automation-controller | Running |

---

## Component-Specific Operations

### k3s

#### Version Pin

Set in `infra/roles/k3s/defaults/main.yml`, together with the sha256 of both binaries (#158 — the
download task fails if the file does not match):
```yaml
k3s_version: "v1.32.13+k3s1"
k3s_binary_sha256:
  aarch64: "66b5f999..."   # line "k3s-arm64" of the release asset sha256sum-arm64.txt
  x86_64: "4aaf9825..."    # line "k3s" of the release asset sha256sum-amd64.txt
```

On every bump, copy both hashes from the release assets of the new tag (for example
`curl -sSL https://github.com/k3s-io/k3s/releases/download/v1.32.13%2Bk3s1/sha256sum-arm64.txt`)
and update them in the same commit as `k3s_version`. On a minor bump, also raise the Pod Security
Admission `-version` labels (see "Pod Security Admission (#160)").

#### Upgrade Procedure

Patch upgrades within one minor are done in place, without draining: `k3s.service` and
`k3s-agent.service` use `KillMode=process`, so containers keep running while k3s restarts. Draining
would move the single-replica RWO workloads (postgresql-0, influxdb2-0, mosquitto, n8n, open-webui,
Home Assistant) between nodes for no benefit.

1. Read the [k3s release notes](https://github.com/k3s-io/k3s/releases) of every release in between,
   especially the embedded component table (kine, containerd, Traefik chart, CoreDNS) — e.g. the
   Traefik chart 39 shipped with v1.32.13 needed the `ports.web.http.redirections` key in
   `40_platform.yml`.
2. Verify: all nodes Ready, no unhealthy pods, all Longhorn volumes `healthy`, no stale Longhorn engine
   (the check in "Stale engines after an iscsid restart (#362)" prints `ok` everywhere; refresh `STALE`
   engines first), kine small (see
   "Read-only diagnostics" below), no Longhorn snapshot (02:00), restic (03:00) or metrics trim (05:00)
   running in the next hour, and two cloudflared replicas Ready on two different nodes
   (`kubectl -n platform get pods -l pod=cloudflared -o wide`, see "Cloudflare Tunnel → Replicas and
   placement"). That last check is what makes a node restart safe off-LAN: `ssh.furchert.ch` runs
   through cloudflared, and while k3s on a node is down nothing restarts a crashed pod there. Off-LAN,
   use the SSH jump config ("Off-LAN kubectl / Ansible Access") and judge every step on the nodes, not
   through the port-forward: `sudo k3s kubectl …` on raspi5 (the agents have no admin kubeconfig), and
   `systemctl is-active k3s` (raspi5) or `systemctl is-active k3s-agent` (agents) on the node being
   upgraded.
3. Keep the previous binary on every node before touching it:
   `ssh ansible@<ip> 'sudo cp -a /usr/local/bin/k3s /usr/local/bin/k3s-<old-version>'`.
4. raspi5 first, then the agents one at a time (raspi4, mba1, mba2), each with a `--check` run first.
   Use `--check` without `--diff` for this playbook (see "Join token and admin kubeconfig").

```bash
ansible-playbook infra/playbooks/20_k3s.yml --limit raspi5 --check
ansible-playbook infra/playbooks/20_k3s.yml --limit raspi5
kubectl get nodes -o wide          # raspi5 Ready with the new version within ~2 min
# then the same two commands with --limit raspi4, mba1, mba2 — one node at a time, wait for Ready
```

5. When the bundled Traefik chart changes (it does with v1.32.13), apply the Traefik values right after
   raspi5 — until then `helm-install-traefik` fails the new chart's schema check and the old Traefik
   keeps running:
   `ansible-playbook infra/playbooks/40_platform.yml --start-at-task "Traefik HelmChartConfig — HTTP zu HTTPS Redirect + Metrics"`,
   then `kubectl -n kube-system get job helm-install-traefik` (1/1) and `curl -s -o /dev/null -w '%{http_code}' http://192.168.1.61/` (301).
6. While the #102 graceful-shutdown rollout is not live on the Macs, add
   `-e '{"k3s_graceful_shutdown_enabled": false}'` to the mba1/mba2 runs (JSON form — a `key=false` extra
   var is the string `"false"` and breaks the boolean condition).
7. After each apply, confirm the node really runs the new binary (`kubectl get nodes` VERSION equals
   `k3s --version` on the node). A run that dies after a changed task loses its handlers, and a re-run
   no longer sees a change — restart k3s/k3s-agent by hand in that case.
8. After the last node, re-run the NetworkPolicy checks #2, #4 and #5 of "data-service NetworkPolicy
   (#127)" (the upgrade replaces the embedded policy controller).
9. After the last node, and after any apt run in the same window, run the stale-engine check of "Stale
   engines after an iscsid restart (#362)" again. The k3s restart itself does not invalidate Longhorn
   engines; an `iscsid` restart does (needrestart after an apt upgrade, an `open-iscsi` package upgrade).

**Rollback** (per node, the unit flags work with the previous patch release too):

```bash
ssh ansible@<ip> 'sudo systemd-run --unit=k3s-rollback --collect /bin/sh -c \
  "install -m 0755 /usr/local/bin/k3s-<old-version> /usr/local/bin/k3s && systemctl restart k3s --no-block"'
# agents: systemctl restart k3s-agent --no-block
```

Delete the kept binaries after 24 h of stable operation. A rollback of raspi5 also rolls back the
bundled Traefik chart; re-apply the matching HelmChartConfig values from the old `40_platform.yml`.

#### Check Current Version

```bash
ansible all -m command -a "k3s --version"
```

#### Systemd Unit Templates

After major k3s upgrades, verify service templates against current k3s documentation:
- `infra/roles/k3s/templates/k3s-server.service.j2` (control-plane)
- `infra/roles/k3s/templates/k3s-agent.service.j2` (workers)

#### Join token and admin kubeconfig (#156)

- The cluster join token is written to `/etc/rancher/k3s/cluster-token` (root, `0600`) on every node
  and passed with `--token-file`; the systemd units (mode `0644`) no longer contain it. The token-file
  task, both unit templates and the kubeconfig fetch in `20_k3s.yml` run with `no_log`/`diff: false`,
  because the pre-#156 units embedded the token and a `--diff` of that migration would print it.
  Still prefer `--check` without `--diff` for `20_k3s.yml`.
- The admin kubeconfig `/etc/rancher/k3s/k3s.yaml` on raspi5 is `0600` (`--write-kubeconfig-mode`);
  on the node use `sudo k3s kubectl`. The operator's copy `~/.kube/homelab.yaml` is unaffected — the
  playbook still fetches it (now with `become`).

#### API audit log (#158)

The kube-apiserver on raspi5 writes an audit log to `/var/log/k3s-audit/audit.log`; the policy is
`/etc/rancher/k3s/audit-policy.yaml` (template `infra/roles/k3s/templates/audit-policy.yaml.j2`).

- **Content:** level `Metadata` at most — who did what to which object, never request or response
  bodies. Logged: every access to Secrets and service-account tokens except reads by kubelets
  (`system:nodes`); exec/attach/port-forward/proxy (already when the session opens) and
  container log reads; all writes. Dropped: leases, events, token/access reviews, status heartbeats,
  kubelet reads, all other reads, non-resource URLs (health, metrics, discovery).
- **Retention:** the apiserver rotates the file at 20 MB and keeps up to 10 gzip-compressed backups for
  at most 7 days (`k3s_audit_log_maxsize`, `_maxbackup`, `_maxage`), so it stays around 50 MB on the
  SD card. Expected volume is ~20 MB/day (mostly Flux server-side-apply dry-runs); measure it a day
  after rollout (`sudo ls -la /var/log/k3s-audit/`) and adjust `_maxbackup` if 7 days do not fit.
  `--audit-log-mode=batch` keeps the writes out of the request path.
- **Read:** `ssh ansible@192.168.1.61 "sudo tail -n 20 /var/log/k3s-audit/audit.log | jq -c '{user: .user.username, verb, uri: .requestURI, code: .responseStatus.code}'"`
- **Disable** (rollback): `ansible-playbook infra/playbooks/20_k3s.yml --limit raspi5 -e '{"k3s_audit_log_enabled": false}'`
  (restarts k3s on raspi5).

#### Pod Security Admission (#160)

The four namespaces created by the playbooks carry Pod Security Admission labels for the `baseline`
profile in `warn` and `audit` mode. Nothing is enforced yet.

| Namespace | Set by | Labels | Workloads that violate baseline (2026-11-03, offline check of the pinned charts and manifests) |
|---|---|---|---|
| `apps` | `50_apps_infra.yml` | warn + audit `baseline`, `v1.32` | none |
| `platform` | `40_platform.yml` | warn + audit `baseline`, `v1.32` | none |
| `monitoring` | `41_monitoring.yml` | warn + audit `baseline`, `v1.32` | `kube-prometheus-stack-prometheus-node-exporter` (hostNetwork, hostPID, hostPath, hostPort 9100); `coroot-node-agent` (privileged, hostPID, hostPath; approved, NM-2) |
| `homeassistant` | `51_homeassistant.yml` | warn + audit `baseline`, `v1.32` | `home-assistant` (hostNetwork, hostPort 8123; needed for mDNS discovery) |

- **Effect:** admission never rejects a pod. `warn` returns a warning when a workload is created or
  updated, so existing pods are not re-evaluated. `audit` adds a `pod-security.kubernetes.io/audit-violations`
  annotation to that request's audit event (the API audit log above) and counts it in
  `pod_security_evaluations_total{mode="audit"}`.
- **Live check (read-only; also the gate before any `enforce` label):**
  `kubectl label --dry-run=server --overwrite ns <namespace> pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=v1.32`
  lists the running pods that `enforce=baseline` would reject. Audit log over the current and the rotated
  (gzipped) files (about 7 days; the directory is root-only, `jq` runs locally):
  `ssh ansible@192.168.1.61 "sudo sh -c 'gzip -cdf /var/log/k3s-audit/audit*'" | jq -c 'select(.annotations["pod-security.kubernetes.io/audit-violations"]) | {ns: .objectRef.namespace, res: .objectRef.resource, verb, name: .objectRef.name, v: .annotations["pod-security.kubernetes.io/audit-violations"]}'`
  Expected entries: Flux/Helm updates of the known violators (coroot-node-agent, node-exporter, home-assistant).
- **Next steps (#160):** `apps` and `platform` can get `enforce: baseline` after a clean audit
  period. For `monitoring` and `homeassistant`, either set `enforce: privileged` explicitly or move the
  violators out first. `restricted` comes later, per workload. Every new workload in `apps` and
  `platform` has to stay baseline-clean.
- **Version pin:** the `-version` labels pin the policy to `v1.32` in the four namespace tasks. Raise them
  (and the `enforce-version` in the live check) with the next k3s minor upgrade.
- **Rollback:** a revert does not remove labels, because the playbooks patch namespaces with a merge.
  Run `kubectl label ns apps platform monitoring homeassistant pod-security.kubernetes.io/warn- pod-security.kubernetes.io/warn-version- pod-security.kubernetes.io/audit- pod-security.kubernetes.io/audit-version-`.

#### k3s datastore (kine/SQLite) maintenance

k3s's embedded datastore is [kine](https://github.com/k3s-io/kine) on SQLite
(`/var/lib/rancher/k3s/server/db/state.db`, control-plane node only — raspi5). kine's online
compactor runs every 5 minutes, with a 5 second per-batch `DELETE` timeout and a 1,000-row batch
size (`compactInterval`, `compactTimeout`, `compactBatchSize` in
`pkg/logstructured/sqllog/sql.go`, kine v0.13.9 — none of these are tunable via k3s flags; since
k3s v1.32.13 (kine v0.14.12) k3s starts kine with `--compact-interval=0s`, so the kube-apiserver
drives the same compaction through its own `--etcd-compaction-interval`, default 5 min). On a
large enough backlog, a batch can exceed the 5 second timeout; Go's `database/sql` rolls that
transaction back, and (with kine v0.13.9, k3s up to v1.32.2) the compactor stalls permanently instead
of retrying — the datastore keeps
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

##### Early warning: `K3sDatastoreLarge` (#150)

`homelab-netmon-collect` (role `netmon_node`) writes `homelab_k3s_state_db_bytes{node="raspi5"}` —
`state.db` plus `state.db-wal` in bytes — into the node-exporter textfile every minute, on the
control-plane node only (`netmon_node_k3s_state_db` in `infra/inventory/group_vars/k3s_server.yml`).
The warning `K3sDatastoreLarge` (group `homelab-netmon-node`) fires above 500 MB for 30 min.
Healthy after an offline compaction: ≈ 30-90 MB (2026-10-28 00:31: `state.db` 50,892,800 B +
`state.db-wal` 35,988,232 B). A stalled compactor grew it to 2.9 GB in 7 days (2026-09-30), so the
alert gives roughly a day of lead time before the symptoms above. When it fires, run the
read-only diagnostics below and then the offline compaction. SQLite never shrinks a file without
`VACUUM`, so the alert keeps firing even after the online compactor catches up on its own — only
the offline compaction (which ends with `VACUUM`) clears it; silencing it is not a fix.

**Compaction lag (#129).** The same script also writes
`homelab_k3s_kine_compaction_lag_revisions{node="raspi5"}` = `MAX(id)` minus `compact_rev_key`, the
values of the read-only diagnostics below, read with one SQLite statement over a read-only
connection (`mode=ro`, `query_only`, 1 s busy timeout; the unit sees the directory read-only through
`ProtectSystem=strict`). Healthy: about 1-3k (kine keeps 1000 revisions plus 5-10 min of churn
between compactions). The lag passes 50k about 4-6 h into a stall (later once the Flux lease churn
is reduced), and `K3sKineCompactionLagging` fires after it stayed above 50k for 2 h, so about
6-8 h into a stall and well before the file reaches 500 MB.
`K3sKineCompactionLagMissing` fires when the size gauge is reported but the lag is not for 1 h:
`journalctl -u homelab-netmon -n 20` shows `k3s kine lag skipped: <error>`. Expected skips: k3s
stopped cleanly (no `-wal`/`-shm` to open read-only) and a damaged or locked database; the LAN
metrics and the size gauge keep flowing either way.

A missing or unreadable `state.db` skips only this gauge (warning `k3s state db skipped: …` in
`journalctl -u homelab-netmon`); the LAN metrics keep flowing. The missing series fires
`K3sDatastoreSizeMissing` (warning, after 1 h): check the journal line, that raspi5's unit carries
`--k3s-state-db` (`systemctl cat homelab-netmon.service`), and that node-exporter on raspi5 is
scraped.

Rollout (owner; playbook runs need a go). The collector script changes on every node, so roll
`netmon_node` out to all nodes (no `-l`); only raspi5's unit file changes. Run `10_base.yml` before
`41_monitoring.yml`, otherwise `K3sDatastoreSizeMissing` (or, for the #129 lag gauge,
`K3sKineCompactionLagMissing`) fires after 1 h.

```bash
# Off-LAN: prefix with ANSIBLE_SSH_ARGS=… (see "Off-LAN kubectl / Ansible Access").
ansible-playbook infra/playbooks/10_base.yml --tags netmon_node --check --diff
ansible-playbook infra/playbooks/10_base.yml --tags netmon_node
ansible-playbook infra/playbooks/10_base.yml --tags netmon_node    # 2nd run: changed=0
ansible-playbook infra/playbooks/41_monitoring.yml --check --diff
ansible-playbook infra/playbooks/41_monitoring.yml                  # alert rules
```

Verify:

```bash
ssh raspi5 "grep -E 'homelab_k3s_(state_db_bytes|kine_compaction_lag_revisions)' /var/lib/node_exporter/textfile_collector/homelab_netmon.prom"
ssh raspi5 "sudo ls -la /var/lib/rancher/k3s/server/db/"     # state.db + state.db-wal ≈ the gauge
kubectl -n monitoring get prometheusrule -o yaml | grep -cE 'alert: (K3sDatastore(Large|SizeMissing)|K3sKineCompactionLag(ging|Missing))$'  # expect 4
```

Rollback: `git revert` the #150 (or #129 lag) commits, then re-run
`ansible-playbook infra/playbooks/10_base.yml --tags netmon_node` and
`ansible-playbook infra/playbooks/41_monitoring.yml`.

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
# means it has stalled — or that there was nothing to compact: confirm with the compact_rev
# query above (it must move forward between two runs ~10 min apart)
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

`homelab-netmon` keeps running during the offline compaction: its once-a-minute lag read is a
read-only statement of about 0.1 ms, and while k3s is stopped it either reads the current value or
logs `k3s kine lag skipped` (#129). If the script's WAL checkpoint ever reports busy, re-run the
script.
Do not stop `homelab-netmon.timer` for it: that would also stop raspi5's LAN metrics and fire
`NetmonNodeScriptStale`.

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

#### Stale engines after an iscsid restart (#362)

**Cause.** A Longhorn engine (one process per attached volume, inside the instance-manager pod on the
node where the volume is attached) caches the host process id of `iscsid` once, when its iSCSI frontend
starts (go-iscsi-helper `NewNamespaceExecutor("iscsid", "/host/proc")`). Every later frontend operation runs
`nsenter` into that process's namespaces. If `iscsid` restarts on that node, every engine started before
the restart is **stale**: an online expansion hangs at the frontend rescan (`Failed to expand the frontend …
nsenter: cannot open /host/proc/<pid>/ns/mnt`), and a detach logs `Error when shutting down frontend` and may
leave an iSCSI session behind. Normal I/O keeps working. Triggers: needrestart after unattended upgrades (it
restarted `iscsid` weekly on raspi5 until the `longhorn_prereqs` override, see Prevention), an `open-iscsi`
package upgrade, a manual `systemctl restart iscsid`. A k3s restart alone does not change the `iscsid` pid,
and the age of the instance-manager pod is not a usable signal (new engines start under old instance
managers). Upstream: longhorn/longhorn#10544 and longhorn/longhorn#13334, fixed in Longhorn 1.11.3+ (1.11.x),
1.12.1+ or 1.13.0+; nothing for 1.7.x. Incident: homelab#359 (about 6 minutes without PostgreSQL).

**Shell.** Paste the blocks below into a `bash` subshell (type `bash` first; they use arrays, functions and
here-strings). Set the access mode once per subshell:

```bash
SSH_CFG=()                                     # on the LAN
kc() { kubectl --request-timeout=20s "$@"; }   # on the LAN (default KUBECONFIG)
# off the LAN instead (see "Off-LAN kubectl / Ansible Access"; the tunnel forward must be open):
# SSH_CFG=(-F "$HOME/.ssh/homelab-offlan.conf")
# kc() { kubectl --kubeconfig "$HOME/.kube/config" --context tunnel --request-timeout=20s "$@"; }
```

**Check (read-only, all nodes).** Compares every engine process with the newest `iscsid` process on its node.

```bash
for ip in 192.168.1.61 192.168.1.163 192.168.1.66 192.168.1.16; do
  echo "== $ip"
  ssh "${SSH_CFG[@]}" -o ConnectTimeout=30 "ansible@$ip" 'bash -s' <<'EOF'
now=$(date +%s); newest=0
for p in $(pgrep -x iscsid); do
  et=$(ps -o etimes= -p "$p" | tr -d ' '); [ -n "$et" ] || continue
  s=$(( now - et )); [ "$s" -gt "$newest" ] && newest=$s
done
if [ "$newest" -gt 0 ]; then echo "newest iscsid started $(date -d @"$newest" -Is)"
else echo "iscsid is NOT running: every engine below is STALE"; fi
psout=$(ps -eo pid=,etimes=,args=)   # snapshot first, so the loop never lists its own sed
found=0
while read -r pid et args; do
  case " $args " in *longhorn*" controller "*) ;; *) continue ;; esac
  vol=$(printf '%s\n' "$args" | sed -n 's/.* controller \([^ ]*\).*/\1/p'); [ -n "$vol" ] || continue
  found=1; st=$(( now - et ))
  if [ "$newest" -eq 0 ] || [ "$st" -lt "$newest" ]; then v=STALE; else v=ok; fi
  echo "engine $vol pid $pid started $(date -d @"$st" -Is) $v"
done <<< "$psout"
[ "$found" -eq 1 ] || echo "no engine on this node"
EOF
done
# map the volume names to PVCs
kc get pv -o custom-columns=PV:.metadata.name,NS:.spec.claimRef.namespace,PVC:.spec.claimRef.name
```

Reading: `ok` everywhere = nothing to do. `STALE` = refresh that volume's engine (below) before any PVC
expansion, Longhorn upgrade, node maintenance or planned detach. A node with replicas only prints
`no engine on this node` (replica processes never use `nsenter`). The single-volume variant is precheck P7
in "Growing the PostgreSQL volume". To find what restarted `iscsid` on a node:
`sudo journalctl -u iscsid --since -30d | grep -E 'Stopping|Starting'` and
`sudo zgrep -h 'Restarting services' /var/log/unattended-upgrades/unattended-upgrades-dpkg.log*`.

**While anything is STALE:** no PVC expansion, no Longhorn upgrade, no node maintenance, no manual detach,
no `iscsid` restart. Normal operation continues.

**Refresh one stale engine (MUTATION, owner).** Scale the workload to 0 so that the volume really detaches,
then back to 1: the next attach starts a fresh engine. A plain pod delete is not enough (the volume can stay
attached on the same node with the same engine). One workload at a time, the next one only after the
previous one is verified. Window: not 01:30–03:30 or 04:30–05:30 (snapshots, restic, metrics trim) and not
06:00–09:00 (unattended upgrades, and the replica rebuilds after the scheduled mba morning reboots once
homelab#367 is live); no playbook running;
all volumes `healthy` (`kc -n longhorn-system get volumes.longhorn.io`).

| Workload | `NS` / `W` | `SEL` (pod selector) | `PVC` | What sets the replicas back |
|---|---|---|---|---|
| open-webui | `apps` / `deploy/open-webui` | `app=open-webui` | `open-webui-data` | playbook 54 |
| n8n (check that no execution is running: Recreate kills it) | `apps` / `deploy/n8n` | `app=n8n` | `n8n-data` | playbook 52 |
| influxdb2 | `apps` / `sts/influxdb2` | `app.kubernetes.io/instance=influxdb2` | `influxdb2` | Helm via playbook 50 |
| mosquitto | `apps` / `deploy/mosquitto` | `app=mosquitto` | `mosquitto-data` | playbook 50 |
| postgresql (every DB client restarts; see "Growing the PostgreSQL volume", P7m) | `apps` / `sts/postgresql` | `app=postgresql` | `data-postgresql-0` | playbook 50 |
| grafana | `monitoring` / `deploy/kube-prometheus-stack-grafana` | `app.kubernetes.io/name=grafana` | `kube-prometheus-stack-grafana` | Helm via playbook 41 |
| prometheus: scale the Prometheus object, not the StatefulSet (the operator reverts a direct scale): `kc -n monitoring patch prometheus kube-prometheus-stack-prometheus --type merge -p '{"spec":{"replicas":0}}'` instead of the scale lines, later `1` | `monitoring` / `sts/prometheus-kube-prometheus-stack-prometheus` (status only) | `prometheus=kube-prometheus-stack-prometheus` | `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` | operator, playbook 41 |
| a Flux-managed app with a PVC (none today) | – | – | – | Flux (10 min): `flux suspend kustomization apps` first, `flux resume kustomization apps` after |

Home Assistant has no Longhorn volume (no Longhorn PV for it in the PV list of 2026-11-09), so it has no engine.

```bash
NS=apps; W=deploy/open-webui; SEL=app=open-webui; PVC=open-webui-data   # one row of the table
VOL=$(kc -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
OLD=$(kc -n longhorn-system get volumes.longhorn.io "$VOL" -o jsonpath='{.status.currentNodeID}')
OLD_IP=$(kc get node "$OLD" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
IM=$(kc -n longhorn-system get engines.longhorn.io -l longhornvolume="$VOL" -o jsonpath='{.items[0].status.instanceManagerName}')
echo "$VOL on $OLD ($OLD_IP), instance manager $IM"
kc -n "$NS" scale "$W" --replicas=0
kc -n "$NS" wait --for=delete pod -l "$SEL" --timeout=180s || true
s=unknown
for i in $(seq 60); do
  s=$(kc -n longhorn-system get volumes.longhorn.io "$VOL" -o jsonpath='{.status.state}'); echo "$i: $s"
  [ "$s" = detached ] && break; sleep 5
done
if [ "$s" = detached ]; then
  # the stale engine could not log out: remove its iSCSI session on the old node BEFORE the scale-up
  ssh "${SSH_CFG[@]}" "ansible@$OLD_IP" "sudo -n iscsiadm -m session 2>/dev/null | grep -F $VOL || echo 'no leftover session'"
  ssh "${SSH_CFG[@]}" "ansible@$OLD_IP" "sudo -n iscsiadm -m node -T iqn.2019-10.io.longhorn:$VOL -u 2>/dev/null || true; sudo -n iscsiadm -m node -T iqn.2019-10.io.longhorn:$VOL -o delete 2>/dev/null || true"
  kc -n "$NS" scale "$W" --replicas=1
  kc -n "$NS" rollout status "$W" --timeout=15m
else
  echo "STOP: $VOL is still '$s' after 5 minutes; the workload stays at 0. Follow the stop rule below."
fi
```

Verify: the pod is Ready with 0 restarts, the volume is `attached`/`healthy`, the check above prints `ok` for
it, the app answers (n8n needs about 4 minutes), and `kc -n "$NS" get "$W"` shows 1 replica again
(`WorkloadScaledToZero` reports a workload left at 0 after an hour; `WorkloadUnavailable` ignores spec 0 on
purpose). Expected downtime: 1 to 3 minutes; open-webui up to about 7 minutes when it lands on a node without
its image.

Stop rule (the block printed `STOP`): `kc -n longhorn-system get volumeattachments.longhorn.io "$VOL" -o yaml`
(attachment tickets) and `kc -n longhorn-system logs "$IM" --since=10m | grep -F "$VOL"`. A snapshot or backup
ticket: wait until it is gone, then run the `if` part again by hand. A stuck engine: the last resort is
deleting the instance-manager pod `$IM`, which restarts **every engine and every replica process on that
node** (all workloads with volumes there restart, replicas rebuild); follow the "Stale engine" recovery steps
in "Growing the PostgreSQL volume" → "If the expansion gets stuck", then the session cleanup and the scale-up.
A graceful reboot of the node also refreshes `iscsid` and every engine on it at once and is the gentler
option when several volumes on one node are stale (owner go).

**Prevention.** `infra/roles/longhorn_prereqs` writes `/etc/needrestart/conf.d/50-longhorn-iscsid.conf`
(`longhorn_prereqs_needrestart_skip_iscsid`, default `true`), so needrestart lists `iscsid` under
"Service restarts being deferred" instead of restarting it. Apply from an up-to-date main checkout, `--check`
first (with this tag only the needrestart tasks run, so `--diff` shows just the snippet):

```bash
ANSIBLE_SSH_ARGS="-F $HOME/.ssh/homelab-offlan.conf -o ControlMaster=auto -o ControlPersist=60s" \
  ansible-playbook infra/playbooks/20_k3s.yml --tags longhorn-needrestart --check --diff   # off the LAN; on the LAN drop ANSIBLE_SSH_ARGS
ANSIBLE_SSH_ARGS="-F $HOME/.ssh/homelab-offlan.conf -o ControlMaster=auto -o ControlPersist=60s" \
  ansible-playbook infra/playbooks/20_k3s.yml --tags longhorn-needrestart
# verify on each node (read-only); expect: (?^:^iscsid) => 0
sudo perl -e 'do "/etc/needrestart/needrestart.conf"; print map {"$_ => $nrconf{override_rc}{$_}\n"} grep {/iscsid/} keys %{$nrconf{override_rc}}'
```

It does not cover an upgrade of the `open-iscsi` package itself: after one, run the check above. The deferred
libraries in `iscsid` are picked up by the next reboot (the Pis need an occasional graceful reboot). The
structural fix is Longhorn 1.11.3+ (1.11.x), 1.12.1+ or 1.13.0+; remove the override after that upgrade
(`longhorn_prereqs_needrestart_skip_iscsid: false`, apply, then delete the option).

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
# Pod status (the chart's only pod label is pod=cloudflared)
kubectl -n platform get pods -l pod=cloudflared -o wide

# Logs
kubectl -n platform logs -l pod=cloudflared --prefix --tail=50
```

#### Replicas and placement (#322)

cloudflared runs as **two replicas of the same tunnel** (same token; Cloudflare allows up to 25 replicas
per tunnel and spreads requests over all connected replicas). It carries every public route and
`ssh.furchert.ch`, the only off-LAN way in, so one node's k3s restart must never leave it without a
supervised replica:

- `replicaCount: 2` in `cluster/values/cloudflared.yaml`.
- Chart 0.1.2 renders no affinity, probes beyond its liveness probe, resources or security contexts, so
  `40_platform.yml` patches its Deployment: a **required pod anti-affinity** on `kubernetes.io/hostname`
  (never two replicas on one node), a **readinessProbe** on `/ready` (200 only with an edge connection)
  and `minReadySeconds: 10`. With the default rolling update (maxSurge 1, maxUnavailable 0) an old pod
  is removed only after a new pod holds an edge connection. Helm's three-way merge keeps these fields on
  later chart upgrades; drop the patch task once a chart version renders them itself.
- A PodDisruptionBudget `cloudflared` (`minAvailable: 1`). It guards manual drains and other eviction-API
  callers only; nothing in this repo drains nodes.
- Consequence: every pod-template change (image bump, ingress change via the restart task) needs a
  **third schedulable node** for the surge pod. With two nodes down the rollout waits (old pods keep
  serving) and the Helm task's 3 min wait fails the playbook run.

Apply only the cloudflared part: the namespace, the two Helm repo tasks, the Helm release, the PDB and the patch. No tunnel
ingress PUT, no restart task, no Traefik values, so it is safe before a k3s upgrade. Off-LAN, add the
SSH jump config and the tunnel kubeconfig (`~/.kube/tunnel.yaml`, see "Off-LAN kubectl / Ansible
Access"). Prerequisite for the diff checks below: the helm-diff plugin (`helm plugin list` shows `diff`
3.4.1 or newer). Without it the helm module prints no diff and always reports the release as changed.

```bash
ansible-playbook infra/playbooks/40_platform.yml --tags cloudflared --list-tasks   # 6 tasks, ending with the patch
ansible-playbook infra/playbooks/40_platform.yml --tags cloudflared --check --diff
ansible-playbook infra/playbooks/40_platform.yml --tags cloudflared
# off-LAN: ANSIBLE_SSH_ARGS="-F $HOME/.ssh/homelab-offlan.conf -o IdentitiesOnly=yes -o ControlMaster=auto -o ControlPersist=60s" \
#   ansible-playbook … -e kubeconfig="$HOME/.kube/tunnel.yaml"
```

- **Never run this playbook with `-v`**: the helm module's result includes the release values, which
  hold the tunnel token. The plain `--diff` is safe (helm-diff masks Secret data).
- On the first run the "Cloudflared deployen" diff must show only `replicas: 1` → `2`. Any other change
  restarts the pods during the Helm step, before the placement patch: stop and investigate.
- Helm only adds the second pod; the patch task then replaces both pods, and a new pod never lands on a
  node that still runs a cloudflared pod. An SSH session that runs through a replaced pod drops once;
  reconnect.

Verify:

```bash
kubectl -n platform rollout status deploy/cloudflared-cloudflare-tunnel-remote --timeout=5m
kubectl -n platform get deploy cloudflared-cloudflare-tunnel-remote -o jsonpath='{.status.updatedReplicas}/{.status.readyReplicas} {.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey} {.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}'
                                                       # 2/2 kubernetes.io/hostname /ready
kubectl -n platform get pods -l pod=cloudflared -o wide   # 2x 1/1 Running, two different nodes
kubectl -n platform get pdb cloudflared                   # ALLOWED DISRUPTIONS 1
ansible-playbook infra/playbooks/40_platform.yml --tags cloudflared --check --diff   # again: changed=0
```

Rollback. The patched fields survive Helm and a plain revert, so remove them explicitly:

```bash
kubectl -n platform rollout undo deploy/cloudflared-cloudflare-tunnel-remote   # abort a stuck rollout only
# strategic merge with nulls: works with and without a preceding rollout undo
kubectl -n platform patch deploy cloudflared-cloudflare-tunnel-remote --type strategic -p '{"spec":{"minReadySeconds":null,"template":{"spec":{"affinity":null,"containers":[{"name":"cloudflared","readinessProbe":null}]}}}}'
kubectl -n platform delete pdb cloudflared
kubectl -n platform scale deploy/cloudflared-cloudflare-tunnel-remote --replicas=1
```

Then, before the next playbook-40 run, open a PR that sets `replicaCount: 1` and removes the PDB and patch
tasks but keeps the `tags: [cloudflared]` lines. A plain `git revert` of #322 also drops the tags, so a
`--tags cloudflared` run would select nothing, and a full run would re-apply the ingress, the restart and
the Traefik values.

#### Add New Public Endpoint

1. Edit `infra/playbooks/40_platform.yml`, add to `ingress` list before `http_status:404`
2. Re-run: `ansible-playbook infra/playbooks/40_platform.yml`
3. Create DNS CNAME in Cloudflare Dashboard

Worked example: `mcp.furchert.ch` in "mcp-hub (Flux, #170 onboarding)".

#### Internal-only paths on public hosts

Some paths of a public host answer `404` at the tunnel because only in-cluster callers use them.
These are `path` rules in `cf_ingress_body`, placed before the host's general rule (first match wins):

- `n8n.furchert.ch`: every `webhook*` variant of `…/club-mcp-gateway` (see "club-mcp").
- `auth.furchert.ch` (#306): the admin API `/api/v1/*`, the Swagger UI (`/swagger-ui.html`,
  `/swagger-ui/*`) and the OpenAPI documents (`/api-docs*`, `/v3/api-docs*`). The OIDC/OAuth paths
  stay public. Admin work goes through furchert.ch `/dashboard/auth`. For the raw API or the Swagger UI
  from the Mac use `kubectl -n apps port-forward svc/auth-service 18080:8080` and
  `http://localhost:18080/swagger-ui.html`.

A `40_platform.yml` run replaces the whole tunnel configuration with `cf_ingress_body` from the
checkout. `--check` skips that PUT (the task has `no_log`), so it never shows the new ingress list; it
only reports the cloudflared restart task as changed when the list differs. Run it from an up-to-date
`main` on the home network: the restart drops an off-LAN SSH forward. Before the run, compare the
tunnel's published application routes in the Cloudflare dashboard (Networking → Tunnels → the tunnel
→ Routes; formerly "Public Hostname") with `cf_ingress_body`.

#### Restart Tunnel Pod

```bash
kubectl -n platform rollout restart deployment/cloudflared-cloudflare-tunnel-remote
kubectl -n platform rollout status deployment/cloudflared-cloudflare-tunnel-remote
```

With two replicas the restart rolls one pod at a time and keeps a connected replica (see "Replicas and
placement"); an off-LAN SSH session through a replaced pod still drops once.

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

raspi5 alone also works without the jump config: `infra/inventory/remote.yml` keeps the LAN IPs as
`ansible_host` and routes raspi5 through `cloudflared access ssh --hostname ssh.furchert.ch`
(`ansible-playbook infra/playbooks/10_base.yml -i infra/inventory/remote.yml -l raspi5 …`). It passes
`IdentitiesOnly=yes`, so the key from `ansible_ssh_private_key_file` (`group_vars/all.yml`) must exist at that
path; otherwise add `-e ansible_ssh_private_key_file=<path>`. The other nodes have no tunnel hostname and need
the jump config.

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
`--check --diff` on the next LAN session (expect `changed=0`). It — like any direct `kubectl apply -f/-k`
of `cluster/apps/{n8n,litellm,open-webui}` — also bypasses the playbooks' version guards (`52_n8n.yml`
and `54_club_assistant.yml` image guards, `53_litellm.yml` config guard): never use it to change the
n8n image or the LiteLLM config, and change the Open WebUI image this way only as the planned step of an
upgrade (backup first). An `*_change_ack` value is part of the operator's own go for that change; an
agent never supplies one on its own. Never use it for the Flux-managed apps
(auth-service, device-service, furchert-ch): change the app repo and let Flux reconcile — a manual
apply there is overwritten by the next reconciliation (see the Flux contract in INTERFACES.md). For
anything beyond a read or a single-file hotfix, run the owning playbook through the port-forward
(`ansible-playbook … -e kubeconfig=…`, see the gotcha above) instead of this one-shot path. The
`Host raspi5` entry from the SSH-access section above already carries `User ansible`,
the `ProxyCommand` and `IdentityFile`, so `ssh raspi5 'sudo k3s kubectl -n apps get pods'` is the
short form of the commands above.

---

### fail2ban (#98)

fail2ban throttles repeated SSH authentication failures from devices on the LAN; sshd is key-only, and UFW
opens port 22 to the LAN and the k3s pod/service CIDRs only. It never bans the cluster's own paths: loopback, the k3s pod
CIDR and every inventory node are in `ignoreip` (`hardening_fail2ban_ignoreip`), because tunnelled SSH
arrives from a cloudflared replica and a ban there would only cut the operator's off-LAN access.

`fail2ban.service` is `Type=simple`, so a server that exits right after `systemctl start` used to look like a
successful start. The `hardening` role therefore tests the configuration, restarts fail2ban for a changed jail
only if the test passes, and fails the host on a failed test or if `fail2ban-client status sshd` does not answer
within a minute. After a failed test, fix the configuration, run `sudo systemctl restart fail2ban` once (the
skipped restart is not repeated, because the jail file no longer changes) and re-run the role.

```bash
# On the node
sudo fail2ban-client status sshd                 # jail up, currently/total banned
sudo fail2ban-client set sshd unbanip <ip>       # lift a ban

# Read-only diagnosis when the client reports "Is fail2ban running?"
systemctl status fail2ban --no-pager -l
systemctl show fail2ban -p UnitFileState,ActiveState,SubState,Result,ExecMainStatus,NRestarts
sudo journalctl -u fail2ban -b --no-pager -n 100   # -b -1: previous boot
sudo tail -n 100 /var/log/fail2ban.log
dpkg-query -W fail2ban python3-systemd python3-pyasyncore nftables
apt-cache policy fail2ban
sudo fail2ban-client --test                       # configuration test, starts nothing
ls -l /etc/fail2ban/jail.local /etc/fail2ban/jail.d/
command -v nft                                    # Ubuntu's default ban action uses nft

# Re-apply the role on one node (off-LAN: ANSIBLE_SSH_ARGS prefix from "Off-LAN kubectl / Ansible Access")
ansible-playbook infra/playbooks/10_base.yml -l <node> --tags hardening --check --diff
ansible-playbook infra/playbooks/10_base.yml -l <node> --tags hardening   # a second run reports changed=0
```

Known causes: Ubuntu 24.04's release package `1.0.2-3` crashes on Python 3.12 (`No module named 'asynchat'`,
LP #2055114). The fixed `1.0.2-3ubuntu0.1` is in noble-updates only, which unattended-upgrades does not install,
and the role's `state: present` never upgrades: `sudo apt-get install --only-upgrade fail2ban`. This needs the
`noble-updates` suite, which the `base` role manages in `/etc/apt/sources.list.d/ubuntu.sources` (#346,
`ansible-playbook infra/playbooks/10_base.yml --tags apt`); on a node without it the command does nothing. A
configuration error exits with status 255, which systemd does not restart. Without `nft`, fail2ban runs but its bans fail
(errors in `/var/log/fail2ban.log`).

---

### Cloudflare Access for grafana, n8n, club, ai and ssh (#121)

`ssh.furchert.ch` already sits behind a Cloudflare Access application, which `cloudflared access ssh`
and the off-LAN runbooks need. `grafana`, `n8n`, `club` and `ai.furchert.ch` are public tunnel routes
protected only by each app's own login:

- Grafana: a local admin account.
- n8n: a local owner account, because OIDC single sign-on is enterprise-only in the n8n community
  edition; account MFA is #280.
- Open WebUI (`club`): a local admin account, signup off.
- LiteLLM (`ai`): SSO against auth-service, plus the break-glass form `/fallback/login`, which accepts
  `admin` + the master key and grants `proxy_admin`. The master key also works on the API.

This runbook puts all four behind Access with the same owner-only policy. For `ai`, a second policy lets
scripts in with an Access service token. It is done in the Cloudflare dashboard. A read-only drift check
of the result is a follow-up (#121; run from the Mac with a read-only token, never in CI).

`auth`, `mcp`, `club-mcp`, `device` and the apex stay without Access: they serve public OIDC/OAuth flows,
the claude.ai connectors (protected by the Anthropic-range WAF rule) or the public site. `device` gets
tunnel 404 rules for its REST API instead ("Internal-only paths on public hosts").

**Who reaches these hosts from outside the browser** (n8n workflow exports in doemefu/homelab-n8n,
club-assistant repo, all homelab repos, 2026-11-03 and 2026-11-12):

| Host | Caller outside a browser | Path | Handling |
|---|---|---|---|
| `n8n.furchert.ch` | Telegram Bot API → Telegram Trigger of the active workflow `m6_telegram_drafting` | `/webhook/<webhookId>/webhook` | **Bypass application** for exactly this path (step 4), created in the same sitting as the n8n app |
| `n8n.furchert.ch` | Open WebUI club pipe → `m6_chat_agent`, `m6_chat_commands` webhooks; club-mcp → `club-mcp-gateway` | — | in-cluster (`n8n.apps.svc.cluster.local`), not affected |
| `n8n.furchert.ch` | Approve/edit links in the drafting messages: the send-and-wait nodes "Approval SendAndWait" and "Form SendAndWait" of `m6_telegram_drafting`, opened in the phone's Telegram browser | `/webhook-waiting/*` | No bypass. The owner is the only authorized chat, so the phone shows the e-mail PIN page once per 24 h session, then the link works |
| `n8n.furchert.ch` | Workflow export/import and seeding scripts and agents using the n8n public API (`/api/v1/*`) from the Mac, including the club-assistant scripts that default to `N8N_BASE_URL=https://n8n.furchert.ch` | `/api/v1/*` | No bypass: use `kubectl -n apps port-forward svc/n8n 5678:80` and `N8N_BASE_URL=http://localhost:5678` (pre-check 3) |
| `n8n.furchert.ch` | club-assistant `scripts/backup.sh`, documented as a nightly 04:00 cron on raspi5, calls `export_workflows.sh` when `N8N_API_KEY` is set | `/api/v1/*` | **Blocking** pre-check 2 |
| `n8n.furchert.ch` | Google OAuth credential callback `/rest/oauth2-credential/callback` | — | browser redirect in a session that already passed Access, so no change |
| `grafana.furchert.ch` | none (browser only; alert links in Discord open in the browser) | — | — |
| `club.furchert.ch` | none (single user; Open WebUI calls LiteLLM and n8n in-cluster; socket.io is same-origin) | — | — |
| `ai.furchert.ch` | `scripts/smoke-test-litellm.sh` (this repo), club-assistant operator scripts (`backfill_drive_corpus.py`, `ocr_backfill.py`, `seed_golden_examples.py`, `eval_embed_d5.py`, `smoke_litellm_club.sh`) and any OpenAI- or Anthropic-compatible client on the Mac, all with bearer virtual keys or the master key | `/v1/*`, `/health/*` | **Service Auth policy** with an Access service token (step 3). Scripts send `CF-Access-Client-Id` and `CF-Access-Client-Secret`. Alternative without a token: `kubectl -n apps port-forward svc/litellm 4000:4000` and `http://localhost:4000`. **Never** a path bypass for `/v1/*` |
| `ai.furchert.ch` | LiteLLM SSO callback `/sso/callback` | — | top-level browser redirect in a session that already passed Access, so no change |
| `ai.furchert.ch` | Open WebUI, n8n and the club pipe | — | in-cluster (`litellm.apps.svc.cluster.local:4000`), not affected |

The exports cover the workflows the backup workflow writes to GitHub. Before step 4, check in the n8n UI
that no other **active** workflow has a Webhook, Form, Chat or Telegram trigger, or a Send-and-Wait or
"Wait → On webhook call" node. The Google Drive, Gmail and schedule triggers poll outbound and are not
affected.

**Pre-checks (owner).** 1–4 block the n8n application; 5 blocks the ai application.

1. n8n → Credentials → "n8n account" (type n8n API), used by "Back up n8n workflows to Github": its
   Base URL must be `http://localhost:5678/api/v1` (n8n calling itself inside the pod; no port-forward
   needed). If it is `https://n8n.furchert.ch/api/v1`, the backup request leaves the pod, comes back
   through Access and fails. Change it first, then run the backup workflow once by hand from the UI.
2. raspi5 crontab: `ssh raspi5 'crontab -l; sudo crontab -l' 2>/dev/null | grep -n backup.sh`. If the
   club-assistant `backup.sh` runs there with `N8N_API_KEY` set, point its `N8N_BASE_URL` at the n8n
   Service's ClusterIP, which a k3s node can reach
   (`N8N_BASE_URL=http://$(kubectl -n apps get svc n8n -o jsonpath='{.spec.clusterIP}')`), or drop
   the export step before step 2, and confirm the next nightly run is green.
3. club-assistant scripts that default to `N8N_BASE_URL=https://n8n.furchert.ch` (`n8n_import.py`,
   `n8n_put.py`, `seed_*_datatable.py`, `verify_eval_run.py`, `export_workflows.sh`): change their
   default to the port-forward URL `http://localhost:5678` (owner commit in the club-assistant repo).
4. n8n → workflow `m6_telegram_drafting` → Telegram Trigger node → Webhook URLs → **Production URL**.
   Note the path; it has the form `/webhook/<webhookId>/webhook`. Never put the id into this public repo.
   Plan homelab#320 (PUBLIC CONNECT on the n8n and club databases) for the same period as the n8n app.
5. ai callers: create the service token (step 3) first, then give every script that targets
   `https://ai.furchert.ch` the two headers (env `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`,
   see "Scripts and the ai service token" below) or move it to the port-forward. The club-assistant
   script defaults are owner commits. While at it, check that the LiteLLM master key is a long random
   value (at least 32 random bytes); it remains the break-glass admin password behind Access.

**Steps (Cloudflare dashboard, `one.dash.cloudflare.com`):**

1. **Login method:** Zero Trust → Integrations → Identity providers → Add new identity provider →
   **One-time PIN** (skip if it is already listed).
2. **Owner-only application per host.** Zero Trust → Access controls → Applications → Create new
   application → Self-hosted and private → Add public hostname. Use these values:
   - Application name: `grafana` (then `club`, `n8n` and `ai` the same way; `n8n` only after pre-checks
     1–4 and together with step 4, `ai` only after pre-check 5 and step 3).
   - Subdomain `grafana` (or `club`, `n8n`, `ai`), Domain `furchert.ch`. Leave the path empty, so the
     whole host is covered.
   - Session duration: `24 hours`.
   - Identity providers: only One-time PIN; enable "Apply instant authentication".
   - Access policies → create a policy `owner-only`: Action **Allow**, Include → **Emails** → your own
     e-mail address. Reuse the same policy for every other application.
   - Create.
3. **ai service token and Service Auth policy (ai only).**
   - Zero Trust → Access controls → Service credentials → Service Tokens → Create Service Token. Name
     `ai-scripts`, duration 1 year (note the expiry date in #121). Copy the Client ID and Client Secret
     once; the secret is shown only now. Keep both in the password manager and in the local environment
     of the machines that run scripts, never in a repo or in this cluster.
   - Access controls → Policies → create a policy `ai-scripts`: Action **Service Auth**, Include →
     **Service Token** → `ai-scripts`.
   - In the `ai` application, attach `owner-only` **and** `ai-scripts`. Do not add a Bypass policy or a
     second application for any `ai` path, `/v1/*` included: a bypass would leave the master key usable
     as an internet-facing admin credential.
4. **Telegram bypass (n8n only, same sitting as the n8n app).** Create new application → Self-hosted and
   private → Add public hostname with these values:
   - Application name: `n8n-telegram-webhook`.
   - Subdomain `n8n`, Domain `furchert.ch`, Path `webhook/<webhookId>/webhook` (from pre-check 4).
   - Policy: Action **Bypass**. Include → **IP ranges** → Telegram's webhook source ranges
     `149.154.160.0/20` and `91.108.4.0/22` (or Include → **Everyone** if Telegram deliveries fail).

   Access applies the most specific path, so only this one URL skips the login. Bypass requests are not
   logged by Access. What protects this path is the unguessable `<webhookId>` and n8n's check of
   Telegram's secret-token header (`X-Telegram-Bot-Api-Secret-Token`), not the IP ranges: anyone can
   create a bot and point its webhook at this URL, and Telegram's servers then deliver from inside the
   ranges. Do not add bypass rules for other n8n paths.
5. **ssh.furchert.ch (already exists; optional, may come after the four apps):** Zero Trust → Access
   controls → Applications → the SSH application. Attach the `owner-only` policy. Remove its old policy
   only after `cloudflared access login https://ssh.furchert.ch` and an off-LAN `ssh raspi5` still work.
   Do this **on the LAN** (a direct `ssh raspi5` is the fallback) and never on the day of a maintenance
   window (Mosquitto #122 phases, the device-service database window #153), because off-LAN kubectl runs
   through `ssh.furchert.ch`. Record the IdP and session length in #121, not here.

**Scripts and the ai service token.** A script reaches `https://ai.furchert.ch` with both headers on
every request, next to its own `Authorization: Bearer <key>`:

```bash
export CF_ACCESS_CLIENT_ID=<client id>.access CF_ACCESS_CLIENT_SECRET=<client secret>   # from the password manager
curl -s https://ai.furchert.ch/v1/models \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

- `scripts/smoke-test-litellm.sh` sends the two headers when both variables are set.
- Python clients: `openai.OpenAI(base_url=..., api_key=..., default_headers={"CF-Access-Client-Id": ..., "CF-Access-Client-Secret": ...})`
  or the same two entries in an `httpx`/`requests` headers dict.
- Claude Code (`ANTHROPIC_BASE_URL=https://ai.furchert.ch`): `ANTHROPIC_CUSTOM_HEADERS` with one
  `Name: Value` per line in the local settings `env`.
- Rotation: create a new token, update the environments, attach it to the `ai-scripts` policy, then
  revoke the old one. A leaked token alone gets past Access but still needs a LiteLLM key.

**Verification:**

```bash
# expect 302 to <team>.cloudflareaccess.com for each host (no Access session in curl)
for h in grafana n8n club ai; do
  curl -s -o /dev/null -w "$h %{http_code} %{redirect_url}\n" "https://$h.furchert.ch/"
done
curl -s -o /dev/null -w '%{http_code}\n' https://n8n.furchert.ch/rest/settings     # not 200 from n8n
# ai: a bearer key alone gets the Access response (302 or 403), never LiteLLM's answer
curl -s -o /dev/null -w '%{http_code}\n' https://ai.furchert.ch/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
# ai: with the service-token headers, LiteLLM answers (smoke test: all 5 checks pass)
LITELLM_MASTER_KEY=sk-... CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... ./scripts/smoke-test-litellm.sh
# Telegram path: with the IP-range bypass, a request from the Mac is outside the ranges and gets an
# Access response (redirect or block page), not n8n; Telegram itself is tested below.
# With the Everyone bypass, n8n answers 403 (missing Telegram secret-token header).
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' -X POST "https://n8n.furchert.ch/webhook/<webhookId>/webhook"
# n8n's own secret-token check, independent of Access: an in-cluster POST without the header → 403
kubectl -n apps exec deploy/n8n -- node -e \
  "fetch('http://localhost:5678/webhook/<webhookId>/webhook',{method:'POST',headers:{'content-type':'application/json'},body:'{}'}).then(r=>console.log(r.status))"
```

Then:
- Browser: every host asks for the e-mail PIN once, then shows the app login.
- Telegram: send a message to the club bot; `m6_telegram_drafting` shows a new execution (this is the real
  test of the bypass). From the phone, approve one draft and open the edit form once: the PIN page appears
  at most once per session, then the link works.
- The backup run started by hand in pre-check 1, and the next scheduled run, succeed. "Backup Watchdog"
  stays silent. If pre-check 2 found the raspi5 cron, its next run is green too.
- club on the phone: open `club.furchert.ch` once from the iOS home-screen web app (standalone mode).
  If the PIN page does not complete there, use Safari for the first login of each session.
- Off-LAN `cloudflared access ssh` still works.

**Expected behaviour:**
- When the 24 h Access session expires inside an open single-page app (n8n editor, Open WebUI, Grafana,
  the LiteLLM UI), its background requests get a cross-origin redirect and fail; the app looks broken
  until a full page reload, which shows the PIN page again.
- One-time PIN silently sends no code to an address outside the policy. Expect login attempts in the
  Access logs, but no Allow events for strangers.

**Rollback:** in Zero Trust → Access controls → Applications, delete the application or detach the
policy from that one application. Do not edit the shared `owner-only` policy itself, because every
application uses it. The tunnel and the apps themselves are unchanged. For `ai`, scripts keep working
without Access once the app is gone; the headers are ignored by LiteLLM.

**Follow-ups (club-assistant repo, owner commits):**
- Its laptop red-team cases against `n8n.furchert.ch` (RT-M05 404 checks, the RT-A webhook probe) now
  meet the Access redirect first.
- Its docs still call n8n "SSO-protected" (`docs/05-security.md`).
- Its n8n API scripts default to the port-forward (pre-check 3); its ai scripts send the service-token
  headers or use the port-forward (pre-check 5).

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
- `serviceMonitor/monitoring/cert-manager` → platform (job `cert-manager`, port 9402 — see "Platform alerting (#284)")
- `serviceMonitor/monitoring/mcp-hub` → apps (job `mcp-hub`, Service port `internal` 8084, `/metrics` — see "mcp-hub alerts (#178)")
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
| `LonghornRecurringJobMissing` | the `daily-snapshot`, `metrics-snapshot-cleanup` or `metrics-filesystem-trim` CronJob has disappeared | 1h |

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
- The **Mac-side app-data dumps** (`scripts/backup-app-data.sh`) and the **restic repository
  copies** (`scripts/copy-restic-repo.sh`, #91) report their freshness to the node since #301 (see
  "Backup freshness and integrity signals (#301)" below); the alert rule for them is a separate
  change in `cluster/values/kube-prometheus-stack.yaml`. Until it is live this stays a manual
  check — see the maintenance checklist.
- The nightly **restic integrity check** (#301) reports through the gauge
  `homelab_backup_integrity_check_failed`, which no rule reads until `ResticIntegrityCheckFailed`
  is live (a separate change in `cluster/values/kube-prometheus-stack.yaml`, applied with
  `41_monitoring.yml` right after the storage rollout). Until then the only signal is the daily
  `journalctl -t homelab-backup -p err` check — see the maintenance checklist.
- `scripts/copy-restic-repo.sh` holds the same lock (shared) while it copies. A 03:00 run that
  starts during a copy exits on the lock collision like a manual run would; the script refuses to
  start between 02:00 and 03:44 and caps each remote command at one hour, so a copy cannot reach
  03:00 in normal operation.
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

**Backup freshness and integrity signals (#301):** two more textfile signals from the `storage`
role on raspi5.

- **Nightly integrity check.** After `forget --prune`, `homelab-backup.sh` runs
  `restic check --read-data-subset=<slice>/N` (`storage_restic_check_subset_days`, default 7;
  `0` switches it off; the slice rotates by calendar day): every pack is read back, decrypted
  and hash-checked once every N days. A
  failed check does **not** fail the backup — the snapshot is already taken — but creates the
  sticky marker `/var/lib/backup/restic-check-failed`, and `homelab_backup_integrity_check_failed`
  (in `homelab-backup.prom`) reads 1 until you clear it. The journal line is
  `restic check FAILED (subset …)` under `-t homelab-backup -p err`. To clear: run the full check
  ("Integrity check" under "Backup (Restic)" with `--read-data`); only when it passes,
  `ssh raspi5 "sudo rm /var/lib/backup/restic-check-failed"`. The gauge reads 0 only after the next
  run: wait for 03:00 or run `ssh raspi5 "sudo /usr/local/bin/homelab-backup.sh"` (outside
  02:00–03:44).
- **Off-node freshness.** `/usr/local/bin/homelab-backup-mark` (installed by the role) writes
  `homelab-backup-offnode.prom` with
  `homelab_backup_offnode_last_success_timestamp_seconds{kind="app-data"|"restic-copy"}` (raspi5's
  clock; `0` = never). `backup-app-data.sh` calls it over SSH after a complete, successful run (all
  six components, so not with `--only`); `copy-restic-repo.sh` after a verified copy of the default
  repository (not when the shrink guard trips). Both are best effort: a failed mark prints a
  warning with the command to run later and never fails the backup. `--no-mark` skips it;
  `--ssh-config ~/.ssh/homelab-offlan.conf` reaches raspi5 off-LAN. The metric name differs from
  `homelab_backup_last_success_timestamp_seconds` on purpose: `ResticBackupStale` takes the `max()`
  of that name, so a fresh Mac series under it would hide a stale restic run.

**Rollout (#301, owner):** after the PR is merged, from an up-to-date checkout on `main`. Only the
Storage play runs (`--tags storage`); stop if `--check --diff` shows changes outside its tasks.

```bash
cd ~/informatik/homelab/infrastructure && git pull
# off-LAN: first `cloudflared access login https://ssh.furchert.ch`, then prefix every
# ansible-playbook line with
#   ANSIBLE_SSH_ARGS="-F $HOME/.ssh/homelab-offlan.conf -o ControlMaster=auto -o ControlPersist=60s"
# and replace `ssh raspi5` with `ssh -F ~/.ssh/homelab-offlan.conf ansible@192.168.1.61`
ansible-playbook infra/playbooks/10_base.yml -l raspi5 --tags storage --check --diff
ansible-playbook infra/playbooks/10_base.yml -l raspi5 --tags storage
ansible-playbook infra/playbooks/10_base.yml -l raspi5 --tags storage    # second run: changed=0
# baseline full check once (outside 02:00-03:45), then one backup run with the new script
ssh raspi5 "sudo restic check --read-data --repo /var/lib/backup/restic-repo --password-file /etc/restic-password"
ssh raspi5 "sudo /usr/local/bin/homelab-backup.sh"
ssh raspi5 "cat /var/lib/node_exporter/textfile_collector/homelab-backup.prom /var/lib/node_exporter/textfile_collector/homelab-backup-offnode.prom"
# expect homelab_backup_integrity_check_failed 0 and both offnode kinds at 0 until the Mac scripts ran
```

Then run `./scripts/copy-restic-repo.sh` and `./scripts/backup-app-data.sh` once each and check
that the two `kind` series carry today's time. `copy-restic-repo.sh` also works off-LAN with
`--ssh-config ~/.ssh/homelab-offlan.conf`; a marked app-data run is LAN-only in practice, because
off-LAN the big PVC archives need `--only`, and an `--only` run is never marked.

**Rollback (#301, owner):** revert the alert rules first, then this PR. The revert also removes
`tags: [storage]` from `10_base.yml`, so re-apply **untagged**:
`ansible-playbook infra/playbooks/10_base.yml -l raspi5 --check --diff` (review any base,
hardening or netmon drift), then without `--check`. Finally
`ssh raspi5 "sudo rm -f /usr/local/bin/homelab-backup-mark /var/lib/node_exporter/textfile_collector/homelab-backup-offnode.prom /var/lib/backup/restic-check-failed"`.

**`CPUThrottlingHigh` review (#68, following the 2026-08-28 auth-service/device-service CPU-limit
changes to 1000m):** 24h throttled-CFS-period ratios — `postgres-exporter` (in the `postgresql-0`
pod) **0.67**, the only container above the 25% alert threshold, at a `limits.cpu: 100m` against
~0.0016 cores average usage (classic scrape-burst-vs-tiny-quota pattern); `auth-service` 0.009 and
`device-service` 0.007 at their new 1000m limits — both already fine, no further tuning needed.
Decision: raised `postgres-exporter`'s `limits.cpu` to `250m` in `infra/playbooks/50_apps_infra.yml`
(`requests` unchanged); kept the alert itself (severity `info`, already excluded from paging by
`InfoInhibitor`) rather than tuning its expression — it was correctly identifying a genuinely
undersized CPU quota, not a false positive.

**Platform alerting (#284):** Flux, cert-manager and whole-workload outages, in
`additionalPrometheusRulesMap.homelab-platform` (tests: `cluster/values/tests/platform.test.yml`).
All `severity: warning`, routed to Discord through the single route.

| Alert | Fires when | `for` |
|-------|-----------|-------|
| `FluxReconciliationFailed` | a Flux object (Kustomization, GitRepository, OCIRepository, HelmRepository, HelmRelease, Image*) is not `Ready=True` and not suspended | 15m |
| `FluxResourceMetricsMissing` | kube-state-metrics is up but exports no `gotk_resource_info` for a Flux kind in use | 30m |
| `WorkloadUnavailable` | a Deployment or StatefulSet in `apps`, `platform` or `flux-system` has 0 available/ready replicas while `spec.replicas > 0` | 5m |
| `WorkloadMissing` | one of the named workloads (list in INTERFACES.md §9) no longer exists | 15m |
| `WorkloadScaledToZero` | a Deployment or StatefulSet in `apps`, `platform` or `flux-system` has wanted 0 replicas for an hour (forgotten scale-up after maintenance). Deliberate zeros longer than 1 h fire it by design: kill switch L3 of mcp-hub or club-mcp, a club-mcp decommission before the manifests are removed, a long `backup-app-data.sh --quiesce` run (open-webui, n8n): silence it | 1h |
| `PersistentVolumeClaimResizeStuck` | a PVC requests more than its bound PV provides, or a resize condition (`Resizing`, `FileSystemResizePending`, `*ResizeError`) stays true; Longhorn: "Stale engines after an iscsid restart (#362)" | 15m |
| `CertManagerCertificateExpiringSoon` | an issued Certificate expires in less than 14 days | 1h |
| `CertManagerCertificateNotReady` | a Certificate is `Ready=False/Unknown` | 15m |
| `CertManagerDown` | no successful scrape of the cert-manager controller | 15m |

Design notes:
- **Flux state comes from kube-state-metrics**, not from the controllers: Flux v2.1 removed
  `gotk_reconcile_condition`; the upstream replacement is a custom-resource-state config that turns
  each Flux object into `gotk_resource_info{namespace,name,customresource_kind,ready,suspended}`
  (about 28 series). A PodMonitor on the six controllers would add thousands of series to a
  Prometheus that was already near its memory limit. Adding a Flux kind means one more
  `groupVersionKind` entry **with its own help text** and its plural in
  `kube-state-metrics.rbac.extraRules`. kube-state-metrics (v2.12+) de-duplicates same-named
  families with an identical HELP line and drops the later kinds' samples (kube-state-metrics#2366);
  the first rollout exported only 3 of the 5 kinds in use and `FluxResourceMetricsMissing` fired.
- **cert-manager** is scraped by an inline ServiceMonitor in `41_monitoring.yml`, not by the chart's
  `prometheus.servicemonitor.enabled`, which would need a `40_platform.yml` run. No Certificate exists
  today (public TLS terminates at Cloudflare), so the certificate rules stay dormant until one does.
- **WorkloadUnavailable vs. the chart rules:** `KubeDeploymentReplicasMismatch` /
  `KubeStatefulSetReplicasMismatch` need 15 min plus 10 min of an unchanged rollout and also fire for
  partial outages. While `WorkloadUnavailable` fires, an Alertmanager inhibit rule in
  `41_monitoring.yml` mutes the chart alert for the same object, so one outage gives one message.
  Expected short firings: a Recreate-strategy upgrade with a slow image pull (open-webui ≈ 7 min,
  n8n) and a node reboot that evicts a single-replica pod with an RWO volume.
- **WorkloadScaledToZero / PersistentVolumeClaimResizeStuck (#362)** come from kube-state-metrics only.
  The resize rule joins each claim's current PV (`kube_persistentvolumeclaim_info{volumename}`, not a
  PV's claimRef, so a retained PV of a re-created claim cannot mask it) to the cluster-scoped
  `kube_persistentvolume_capacity_bytes` (the PV capacity grows only when the controller-side expansion
  succeeds); its condition branch uses `kube_persistentvolumeclaim_status_condition{condition=…}`,
  experimental in KSM v2.14. During the #359 expansion a stale Longhorn engine hung the frontend rescan for 18 minutes
  and no alert fired.
- **The #125 key move** also put the long-ignored KSM/node-exporter `resources` into effect (they
  had none before); KSM's memory limit is 256Mi because custom-resource-state caches every CRD.
  Prometheus' memory limit went from 1Gi to 1536Mi in the same change (RSS peaked at 1009 Mi).

Known blind spots: a Flux controller that is alive but has stopped reconciling leaves `Ready=True`
(`WorkloadUnavailable` catches a dead one, `WorkloadMissing` a deleted one); nothing outside the
cluster watches the cluster. A deleted `kustomize-controller` cannot heal itself through Flux:
re-apply the bundle from a main checkout with `kubectl apply -k cluster/flux-system/` (owner step).

**Off-cluster dead-man's switch (owner step, not set up):** Alertmanager runs inside the cluster,
so if raspi5 or the whole cluster dies, nothing reaches Discord. The chart's always-firing
`Watchdog` alert is the heartbeat; it needs an external receiver that pages when the heartbeats
stop. Today `Watchdog` goes to Discord every 12 h with everything else.
1. Create a heartbeat check at an external service (a hosted heartbeat/cron-monitoring service, or
   a Cloudflare Worker cron on the existing account). Period 5 min, grace 10 min, notify via
   Discord or e-mail. This is a new external service, so it is the owner's choice.
2. Store its ping URL as `alertmanager_watchdog_heartbeat_url` in
   `infra/inventory/group_vars/all.sops.yml`. With the URL in the clipboard:
   `pbpaste | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' | sops set --value-stdin infra/inventory/group_vars/all.sops.yml '["alertmanager_watchdog_heartbeat_url"]'`
3. In `infra/playbooks/41_monitoring.yml` (inline `alertmanager.config`), add a sub-route and a
   receiver, then run the playbook. The sub-route also stops the 12-hourly Watchdog message in Discord:

   ```yaml
   route:
     # ...existing keys...
     routes:
       - matchers: ['alertname = Watchdog']
         receiver: 'heartbeat'
         group_wait: 0s
         group_interval: 1m
         repeat_interval: 1m
   receivers:
     # ...existing receivers...
     - name: 'heartbeat'
       webhook_configs:
         - url: "{{ alertmanager_watchdog_heartbeat_url }}"
           send_resolved: false
   ```

**Rollback (#284):** `helm -n monitoring history kube-prometheus-stack` → `helm -n monitoring rollback
kube-prometheus-stack <revision before the change>`, then
`kubectl -n monitoring delete servicemonitor cert-manager` (Ansible-applied, not part of the
release), and revert the PR so the next playbook run does not re-apply it.

**mcp-hub alerts (#178):** the hub's own metrics (`docs/080-mcp-hub.md` §9.7, live since hub#90) are
scraped by the ServiceMonitor `monitoring/mcp-hub` (`41_monitoring.yml`; Service port `internal`,
8084, `/metrics`, 30 s, job `mcp-hub`). Rules in `additionalPrometheusRulesMap.homelab-mcp-hub`
(tests `cluster/values/tests/mcp-hub.test.yml`), expressions verbatim from spec 080 §7.4:

| Alert | Fires when | `for` |
|-------|-----------|-------|
| `McpHubAccountAuthExpired` | an account × capability reports `auth_expired` (one-hot `mcp_hub_account_status`) | 30m |
| `McpHubDown` | the hub target scrapes with `up == 0`, or there is no target while `spec.replicas > 0` | 10m |

- **Action for `McpHubAccountAuthExpired`:** Graph accounts re-login with `mcp-hub login <account>`
  ("mcp-hub token store and the Outlook account (#171 onboarding)"); app-password accounts get a
  new app password in the encrypted group vars plus playbook 59 ("mcp-hub (Flux, #170 onboarding)",
  "mcp-hub: Gmail account (#172)"). A pod restart resets the status to `unknown` and restarts the
  30 min.
- **Checks for `McpHubDown`:** `kubectl -n apps get pods -l app=mcp-hub`,
  `kubectl -n monitoring get servicemonitor mcp-hub`, the Service port name `internal`, and
  `kubectl -n apps get networkpolicy -o custom-columns=NAME:.metadata.name,SEL:.spec.podSelector.matchLabels`
  (no policy may select `app=mcp-hub` without admitting `monitoring` → 8084; #127).
- **One message per outage:** while `WorkloadUnavailable` fires for `apps/mcp-hub`, an inhibit rule
  in `41_monitoring.yml` mutes `McpHubDown` and the chart's `TargetDown` for job `mcp-hub`; while
  only the scrape fails (pod available), a second rule lets `McpHubDown` mute `TargetDown` for the
  job. The `equal` lists are empty on purpose: the absent() branch of `McpHubDown` carries only
  `job="mcp-hub"`. `KubePodCrashLooping` / `KubePodNotReady` (pod-level) are not muted.
- **Planned stop with replicas left at 1:** silence `WorkloadUnavailable`, `McpHubDown` and
  `TargetDown` for the hub. A scale to 0 (kill switch L3) needs no silence for the first hour; if it
  lasts longer, silence `WorkloadScaledToZero` for `apps/mcp-hub`.
- **Rollout (owner):** playbook 41 after merge, from an up-to-date main checkout. It upgrades the
  release (rules) before it applies the ServiceMonitor; if the run aborts in between,
  `McpHubDown` fires after 10 min (a true signal). Verify: `up{job="mcp-hub"} == 1`,
  `count(mcp_hub_account_status)` = 6 × the configured account × capability pairs (24 today),
  `kubectl -n monitoring get prometheusrule kube-prometheus-stack-homelab-mcp-hub`, no `McpHub*`
  alert firing, and the inhibit rules loaded: `alertmanager_config_last_reload_successful == 1`
  **and** `alertmanager_config_last_reload_success_timestamp_seconds` later than the playbook run
  (a config the operator rejects leaves the old one running with the gauge still 1). Never print
  the generated Alertmanager config; it holds the Discord webhook.
- **Rollback:** `helm -n monitoring rollback kube-prometheus-stack <revision before the change>`,
  `kubectl -n monitoring delete servicemonitor mcp-hub` (Ansible-applied), revert the PR. Do this
  **before** rolling the hub back below hub#90, or the 404 on `/metrics` fires `McpHubDown`.

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
2. Re-run with the version-change acknowledgement (the playbook refuses any image change without it,
   so a merged Dependabot bump can never be rolled out by an unrelated run):
   `ansible-playbook infra/playbooks/52_n8n.yml -e n8n_image_change_ack='<exact image string from the manifest>'`
3. Confirm: `kubectl -n apps rollout status deployment/n8n --timeout=10m`

The club-assistant runs on this n8n; agree an upgrade window with its operator and run its post-upgrade
re-tests and interim controls (club-assistant repo
`.claude/worklogs/20261013-233437-platform-drift-parent-8d37.md`, section "Apply runbook", R-N).

n8n's TypeORM migrations against its SQLite database are forward-only in practice — back up the
`n8n-data` PVC per the n8n backup steps in the [Backup & rollback](#backup--rollback-for-image-updates-open-webui-litellm-n8n-postgresql-cloudflared)
runbook below before upgrading, and never point an older image at a database a newer image has
already migrated.

> **Note:** OIDC single sign-on is an enterprise feature that the n8n community edition does not
> unlock (owner confirmed 2026-10-22): `/rest/settings` reports `enterprise.oidc: false` although
> the env-managed OIDC settings (`N8N_SSO_MANAGED_BY_ENV`, `N8N_SSO_OIDC_*`) are applied and the log
> prints "OIDC login is enabled — applying OIDC SSO env vars" — that log line is not evidence of a
> working SSO login. The owner signs in with a local n8n account; hardening of that login is tracked
> in #121 and #280. Post-upgrade smoke tests use the local account, not OIDC.

#### Pinned defaults (#342)

`cluster/apps/n8n/deployment.yaml` sets these values explicitly (owner decision 2026-11-07), so a later
n8n release cannot change them silently. The n8n 2.46.4 startup log flags each of the last six as a
default or name that changes in a future version.

| Variable | Value | Reason |
|----------|-------|--------|
| `N8N_DIAGNOSTICS_ENABLED` | `false` | Telemetry off (default `true`). |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | `true` | Today's default; becomes `false`. |
| `N8N_RUNNERS_MODE` | `internal` | Today's default. Internal mode itself is deprecated, so its startup warning stays until the task runner moves to an external launcher. |
| `N8N_RUNNERS_TASK_TIMEOUT` | `300` (seconds) | Today's default; drops to 60. |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` | `2147483648` (2 GiB) | Today's default; drops to 256 MiB. |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` | `5000` | Today's default; drops to 1000. |
| `N8N_WEBHOOK_URL` | `https://n8n.furchert.ch/` | Replaces the deprecated `WEBHOOK_URL`; base URL of production and test webhooks. |

Playbook 52 patches the live Deployment (strategic merge), which adds env entries but never removes
one. After the first 52 run with this manifest the live pod still carries the old `WEBHOOK_URL` next to
`N8N_WEBHOOK_URL` (same value, harmless, n8n prefers the new one). Keeping both works.

Optional cleanup (removes the deprecation warning, costs one more n8n restart of about 4 min). First
confirm that `N8N_WEBHOOK_URL` is live; the command must print `https://n8n.furchert.ch/`:

```bash
kubectl -n apps get deploy n8n -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="N8N_WEBHOOK_URL")].value}'
kubectl -n apps set env deployment/n8n WEBHOOK_URL-   # only after the check above printed the URL
```

Never drop `WEBHOOK_URL` before 52 has added `N8N_WEBHOOK_URL`: with neither set, n8n builds webhook
URLs as `https://n8n.furchert.ch:5678/` and re-registers external webhooks (Telegram) with that URL.

---

### Open WebUI

Deployed by `54_club_assistant.yml`; image updates and backups: see
[Backup & rollback](#backup--rollback-for-image-updates-open-webui-litellm-n8n-postgresql-cloudflared).

#### Pinned defaults (#342)

Open WebUI runs with `ENABLE_PERSISTENT_CONFIG=false`: the Deployment env is the source of truth, and an
Admin-panel change to one of these settings lasts only until the next pod restart.
`cluster/apps/open-webui/deployment.yaml` sets (owner decision 2026-11-07):

| Variable | Value | v0.13.0 default (before v0.13.0) | Meaning |
|----------|-------|----------------------------------|---------|
| `CHAT_RESPONSE_MAX_TOOL_CALL_ITERATIONS` | `512` | 1024 (256) | Tool-call rounds per chat response; `-1` = unlimited. |
| `SUBAGENTS_MAX_CONCURRENT` | `30` | unlimited (20) | Foreground sub-agents running at once. |
| `SUBAGENTS_MAX_ASYNC` | `30` | unlimited (20) | Background sub-agents running at once. |
| `SUBAGENTS_MAX_ITERATIONS` | `50` | unlimited (30) | Tool-call rounds per sub-agent. |
| `SUBAGENTS_MAX_OUTPUT` | `50000` | unlimited (30000) | Characters of a sub-agent result passed back; longer results are truncated. |
| `ENABLE_NOTIFICATIONS` | `false` | `true` | Notification inbox off. |
| `ENABLE_COMMENTS` | `false` | `false` | Comments off (pinned at the default). |
| `CORS_ALLOW_ORIGIN` | `https://club.furchert.ch` | `*` | Browser CORS and socket.io allowed origins. |

Sub-agents are off by default (`ENABLE_SUBAGENTS=false`); the `SUBAGENTS_MAX_*` limits apply once an
admin enables them. With the CORS pin, a browser session through `kubectl port-forward`
(origin `http://localhost:…`) loses its socket.io connection (streaming, event dialogs); use
`https://club.furchert.ch`. Server-side callers (n8n, the club pipe) send no `Origin` header and are not
affected.

Accepted defaults (owner decision 2026-11-07):

- **Tool Creation stays on.** v0.13.0 enables the builtin "Tool Creation" per model by default: in a chat
  with native function calling, the model can save a workspace Python tool, and saving runs the module on
  the server (the container runs as UID 0, see the SECURITY DEVIATION block in the manifest).
- **The workspace-tools user permission stays off** (`USER_PERMISSIONS_WORKSPACE_TOOLS_ACCESS`, default
  `false`), so only admins (and members of a group granted Workspace → Tools access) can create tools
  this way.

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

**Config-change guard:** `53_litellm.yml` refuses to run when the checkout's `config.yaml` differs
from the live ConfigMap, because club routing changes have been rolled out from feature branches and a
run from an older checkout would silently revert them. Before acknowledging, compare the live config
with the checkout and make sure every live change is contained in it:

```bash
kubectl -n apps get configmap litellm-config -o jsonpath='{.data.config\.yaml}' > /tmp/litellm-live.yaml
python3 -c "import yaml;print(yaml.safe_load(open('cluster/apps/litellm/configmap.yaml'))['data']['config.yaml'],end='')" \
  | diff /tmp/litellm-live.yaml -
# intended change only -> re-run with the sha256 the failure message prints:
ansible-playbook infra/playbooks/53_litellm.yml -e litellm_config_change_ack=<sha256>
```

The ack goes on the command line only, never into inventory/group_vars. A playbook run with an
unchanged config needs no ack.

#### SSO roles

LiteLLM derives a user's role from auth-service on every SSO login (#164): the
`GENERIC_ROLE_MAPPINGS_*` env in `cluster/apps/litellm/deployment.yaml` maps the userinfo claim
`role` = `ADMIN` to `proxy_admin` and every other user to `internal_user_viewer`, and LiteLLM writes
that role to the user's row in its database. Club members need no LiteLLM role: Open WebUI, n8n and
the club scripts call the LLM routes with virtual keys, which every role may use. So LiteLLM admin =
auth-service `ADMIN` — before the first apply, check that `/dashboard/auth` on furchert.ch lists only
the owner as `ADMIN`.

- **Stale rows:** a user's row changes only at their next SSO login, and users who only own virtual
  keys may never sign in again. After the first apply, open `https://ai.furchert.ch/ui` → Internal
  Users and set every row except the owner's to `internal_user_viewer`.
- **Break-glass:** the LiteLLM login form (`https://ai.furchert.ch/fallback/login`, behind the Access
  application once #121 is applied; in-cluster via `kubectl -n apps port-forward svc/litellm 4000:4000`)
  accepts username `admin` with the master key as password
  (`UI_USERNAME`/`UI_PASSWORD` unset) and grants `proxy_admin`; the master key also works on the API.
  Check that this login works before the first apply.
- **Rollback:** the playbook's apply never removes env entries, so deleting them from the manifest is
  not enough. With the owner's go:
  `kubectl -n apps set env deploy/litellm GENERIC_ROLE_MAPPINGS_ROLES- GENERIC_ROLE_MAPPINGS_GROUP_CLAIM- GENERIC_ROLE_MAPPINGS_DEFAULT_ROLE-`
  and then set roles by hand in Internal Users.
- **Upgrades:** the three env names exist only in LiteLLM's code (`litellm/proxy/management_endpoints/ui_sso.py`,
  `_setup_role_mappings`), not in its docs. Check that they still exist in the new tag before bumping.
  Add or remove the three together: a malformed `GENERIC_ROLE_MAPPINGS_ROLES`, an invalid
  `GENERIC_ROLE_MAPPINGS_DEFAULT_ROLE` or `ROLES` without `GROUP_CLAIM` makes every SSO login fail
  (use break-glass).

#### Verify

```bash
kubectl get pods -n apps -l app=litellm
kubectl get secret litellm-secrets -n apps

# Full smoke test (requires LITELLM_MASTER_KEY). Through ai.furchert.ch also set the Access
# service token (see "Cloudflare Access for grafana, n8n, club, ai and ssh (#121)"):
LITELLM_BASE_URL=https://ai.furchert.ch LITELLM_MASTER_KEY=sk-... \
  CF_ACCESS_CLIENT_ID=<id>.access CF_ACCESS_CLIENT_SECRET=<secret> \
  ./scripts/smoke-test-litellm.sh
# Without a service token: through the in-cluster Service
kubectl -n apps port-forward svc/litellm 4000:4000 &
LITELLM_BASE_URL=http://localhost:4000 LITELLM_MASTER_KEY=sk-... ./scripts/smoke-test-litellm.sh
```

#### Upgrade

1. Update image tag in `cluster/apps/litellm/deployment.yaml` to new pinned version
2. Check [LiteLLM release notes](https://github.com/BerriAI/litellm/releases) — avoid known malicious versions (e.g., 1.82.7, 1.82.8) — and that the `GENERIC_ROLE_MAPPINGS_*` env names still exist (see "SSO roles")
3. Re-run: `ansible-playbook infra/playbooks/53_litellm.yml`
4. Confirm: `kubectl rollout status deployment/litellm -n apps`

> **Rollout wait:** the playbook's rollout-wait task ("LiteLLM Rollout warten") uses the
> `kubectl rollout status` conditions (#58) except its progress-deadline check: new spec observed,
> every replica updated, no old pod left, every updated pod available. It waits up to 900 s (image pull plus the 10-min startupProbe
> budget) and fails after that while the rollout itself continues; step 4 stays as the final check.

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

#### data-service NetworkPolicy (#127)

`cluster/apps/data-service/networkpolicy.yaml` admits TCP 8082 only from:
- the furchert-ch pods (`app: furchert-ch`), which use the netmon read API;
- the kube-prometheus-stack Prometheus pods, which scrape `/actuator/prometheus`.

It restricts ingress only, so the collectors' egress is not affected. Node-local traffic is always admitted: kubelet probes, `kubectl port-forward`, and host processes or hostNetwork pods on data-service's node. Flux (Kustomization `apps`, prune) applies the file on merge and removes it on revert.

The selectors depend on labels and a port that live in other repos:
- `app: furchert-ch` in furchert-ch `k8s/deployment.yaml`;
- `app: data-service` and containerPort 8082 in data-service `k8s/deployment.yaml`.

A label or port change there, or a new caller of data-service, needs this policy updated in the same change.

Do not merge or reconcile it during a k3s upgrade window: the upgrade changes the embedded policy controller. Re-run the matrix after an upgrade.

**Before merge (home network or tunnel context):**

```bash
kubectl -n apps get pods -l app=furchert-ch --show-labels                      # exactly 1 pod
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus,operator.prometheus.io/name=kube-prometheus-stack-prometheus   # exactly 1 pod
# Positive control for the negative test below: must print {"status":"UP"...}
kubectl -n apps run np-test --restart=Never --image=busybox:1.37.0 -- wget -T 5 -qO- http://data-service.apps.svc.cluster.local:8082/actuator/health
kubectl -n apps wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-test --timeout=60s; kubectl -n apps logs np-test; kubectl -n apps delete pod np-test
```

**After merge (verification matrix):**

| # | Check | Expected |
|---|---|---|
| 1 | `flux reconcile kustomization apps --with-source`, then `kubectl -n apps get networkpolicy data-service` | exists |
| 2 | `kubectl -n apps exec deploy/furchert-ch -- wget -qO- -T 5 http://data-service.apps.svc.cluster.local:8082/actuator/health` | `{"status":"UP"...}` |
| 3 | furchert.ch `/dashboard/network` (ADMIN) | data loads |
| 4 | Grafana Explore: `up{job="data-service"}` | 1 |
| 5 | Same `np-test` pod as above, but wait with `--for=jsonpath='{.status.phase}'=Failed` | wait succeeds: `wget` failed (timeout or connection refused); logs show the error |
| 6 | `kubectl -n apps delete pod -l app=furchert-ch` (furchert.ch is down for a few seconds, replicas 1); wait for Ready; repeat #2 and #3 | still works. kube-router lets connections that were already open continue, so this proves new pod IPs are admitted |
| 7 | after 15 min: `min_over_time(up{job="data-service"}[15m])` | 1 |
| 8 | `kubectl -n apps get pods -l app=data-service` | Ready, restart count unchanged |

**Rollback:** revert the PR. Flux prunes the policy within 10 minutes, or immediately with `flux reconcile kustomization apps --with-source`. Emergency: `flux suspend kustomization apps && kubectl -n apps delete networkpolicy data-service`, merge the revert, run `flux reconcile source git flux-system` (so the resume does not re-apply the old revision), then `flux resume kustomization apps`. Confirm `flux get kustomizations apps` shows it resumed: the Flux sync alert skips suspended Kustomizations.

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
| `26h` | `blocklists`, `retention` (daily), `webanalytics-rollup` (twice daily, 01:12 and 07:30 Europe/Zurich; homelab#350) | daily |
| `3h` | `egress` | hourly |
| `90m` | `lan`, `reputation` | 15 min / 30 min |
| `15m` | every other collector: `cloudflare-requests`, `cloudflare-firewall`, `login-events`, and any collector not listed | 5 min / 1 min |

1. Check `GET /api/netmon/status` through furchert-ch `/dashboard/network`, or the data-service logs (`kubectl -n apps logs deploy/data-service`). `lastError` and `consecutiveFailures` name the cause. data-service never logs tokens.
2. `credentials` on a Cloudflare collector means the token has expired or was revoked. Create a new token (zone `furchert.ch`, Analytics:Read), update `data_service_cloudflare_analytics_token` in SOPS, run playbook 59 and restart data-service.
3. A collector added in data-service without its own class falls into the `15m` class. If its cadence is slower, add a class to the rules in `cluster/values/kube-prometheus-stack.yaml`.
4. A collector that is disabled (`netmon.collectors.<name>.enabled=false`) must not export the gauge. If one stays NaN forever, that is a data-service bug, not an outage.
5. For `webanalytics-rollup`, `/api/netmon/status` does not list it: check `GET /api/webanalytics/status` (through furchert-ch `/dashboard/analytics` or the data-service logs, `kubectl -n apps logs deploy/data-service`). Contract: `docs/100-web-analytics.md` §7.5, §8.2.

**Web analytics rollup gate (homelab#350, WA-3a).** The `webanalytics-rollup` collector ships disabled and exports no gauge, so the rule change is inert until data-service enables it. Order: merge the homelab change, the owner runs `ansible-playbook infra/playbooks/41_monitoring.yml` (with `--check --diff` first), records the run in homelab#350, and verifies read-only that the live rule carries the new class: `kubectl -n monitoring get prometheusrule kube-prometheus-stack-homelab-netmon -o yaml | grep -o webanalytics-rollup | wc -l` prints `6` (three occurrences in the 26h rule, three in the catch-all exclusion). Also check the selector operators, not only the count: `... | grep -o 'collector=~"[a-z|-]*webanalytics-rollup"' | wc -l` prints `3` and `... | grep -o 'collector!~"[a-z|-]*webanalytics-rollup[a-z|-]*"' | wc -l` prints `3`. Then confirm that Prometheus itself runs the new rules (a delayed or failed reload would keep the old catch-all): in the Prometheus UI or `/api/v1/rules`, both `NetmonCollectorStale` expressions (26h class and 15m catch-all) contain the rollup with `=~` and `!~` respectively, and each active expression equals the checked-in rule in `cluster/values/kube-prometheus-stack.yaml` (compare the whole expression, not only the selector). Only then is the data-service change that sets `netmon.collectors.webanalytics-rollup.enabled=true` merged (it links the #350 comment with the playbook run). Without the live rule, the enabled collector would fall into the 15m catch-all. Rollback after the collector is enabled: disable the collector in data-service first, then revert the rule change and re-run `41_monitoring.yml`; reverting the rule first would put the rollup into the 15m class and page. Wait until the disabled configuration has reached the running data-service Pod (new Pod Ready, `/api/webanalytics/status` shows the collector disabled) `up{job="data-service"} == 1` (a healthy scrape, so a missing gauge is not the result of a failed scrape) and Prometheus no longer has a `netmon_collector_last_success_timestamp_seconds{collector="webanalytics-rollup"}` series, before reverting the rule.

**`NetmonDataServiceDown`** (warning, `for: 10m`) fires when Prometheus cannot scrape data-service, or has no target for it at all. Check `kubectl -n apps get pods -l app=data-service`, `flux get kustomizations data-service -n flux-system`, `kubectl -n monitoring get servicemonitor data-service` and the NetworkPolicy `kubectl -n apps get networkpolicy data-service`: its Prometheus selector must still match the Prometheus pod labels ("data-service NetworkPolicy (#127)"). The alert also fires during a planned scale-to-0 or Flux suspend, so silence it in Alertmanager for planned downtime.

### Web analytics (WA-5): alerts, Cloudflare rules and owner checks

Web analytics (Epic #348, spec `docs/100-web-analytics.md`) stores events in schema `webanalytics` of the `data_service` database and is dark until WA-6. This section holds the operator side of WA-5 (homelab#351): the alert rules, the Cloudflare settings and the owner checks. Procedures that need the data-service WA-5 code (purge a day, change caps, disable ingest, reset the rollup mark) follow with data-service#56 and link its own docs.

#### Alerts (`homelab-webanalytics`)

Rules live in `cluster/values/kube-prometheus-stack.yaml` under `additionalPrometheusRulesMap.homelab-webanalytics`; tests in `cluster/values/tests/webanalytics.test.yml`, `cluster/values/tests/webanalytics-timing.test.yml` (30 s cadence, boundary of the 15 minute hold), `cluster/values/tests/webanalytics-gauges.test.yml` (the two gauge rules, absent-series cases) and `cluster/values/tests/webanalytics-silent.test.yml` (the latch and `WebAnalyticsIngestSilent`, 15 minute grid). Spec §7.9 is the contract for the metric names.

| Alert | Fires when | For | Severity | First checks |
|-------|------------|-----|----------|--------------|
| `WebAnalyticsIngestSpike` | accepted events in the last hour > 500 **and** > 3 × the 7-day average of the hourly count (recording rule `webanalytics:accepted:increase1h`, current hour excluded) | 15m | warning | compare `webanalytics_edge_dropped_total` and `webanalytics_events_rejected_total`; Cloudflare analytics for a bot burst on `/api/v`; the cap state in `GET /api/webanalytics/status` |
| `WebAnalyticsRejectRatioHigh` | rejects (all reasons except `erased`) > 100/h **and** > 50 % of rejects plus accepted | 30m | info | version mismatch between furchert-ch and data-service (spec §6.2), reasons in `webanalytics_events_rejected_total` |
| `WebAnalyticsIngestCapped` | `max(webanalytics_ingest_capped) == 1`: the hourly (2 500) or daily (10 000) ingest cap is reached | 5m | warning | `GET /api/webanalytics/status` (`dailyCap`, `capped`), spike and reject counters, then data-service's runbooks "purge a poisoned day" and "adjust caps" |
| `WebAnalyticsIngestSilent` | no analytics event accepted for 7 days, or for 24 hours after a week that averaged at least 50 events per day; armed by the first accepted events (latch `webanalytics:accepted:last_seen_timestamp`; the 50 per day baseline is frozen in `webanalytics:accepted:baseline_per_day`); both `data-service` and `furchert-ch` deployments available | 1h | info | the furchert-ch collect route and `ANALYTICS_*` flags, the tracker, the forward queue and token, `GET /api/webanalytics/status`, caps and rejects; a planned stop (kill switch, caps 0) fires it too, silence it for the duration |
| `WebAnalyticsSecondLineRejects` | any increase of `webanalytics_events_rejected_total` in the last hour for a reason other than `erased` and `visitor_cap` | 0m | warning | the `reason` label; contract mismatch or an attack that passed furchert-ch's validation; data-service logs (class only) |
| `WebAnalyticsTableLarge` | `max(webanalytics_raw_table_bytes) > 3 GiB` (total relation size of `webanalytics.events`; about 2.0 to 2.2 GB is expected at the caps; the volume is 10 GiB since homelab#359) | 1h | warning | retention job log, caps, volume headroom (owner checks below), data-service's "purge a poisoned day" |

`info` alerts are normally visible only in Prometheus and Alertmanager, because the chart's `InfoInhibitor` suppresses them in Discord unless a warning fires in the same namespace. The gauge rules `WebAnalyticsIngestCapped` and `WebAnalyticsTableLarge` read the gauges of data-service WA-5 (`webanalytics_ingest_capped`, `webanalytics_raw_table_bytes`); `WebAnalyticsTableLarge` has no series until the first successful measurement and does not fire then. `WebAnalyticsIngestSilent` (WA-6, #352) is gated by the latch recording rule and stays inert until the first events: it can be applied before the go-live end-to-end checklist, which then arms it (the checklist's events followed by a quiet week fire it on day 7, or on day 1 after a busy week). A Prometheus outage longer than one day loses the latch (the next accepted event rebuilds it). After `41_monitoring.yml`, `/api/v1/rules` shows the rule `ok` and `inactive`, and after the checklist the series `webanalytics:accepted:last_seen_timestamp` exists.

**Rollout.** Merge, then run `ansible-playbook infra/playbooks/41_monitoring.yml --check --diff` from an up-to-date checkout of `main`. Stop if the diff shows anything except the new PrometheusRule; then run the playbook, and a second run must show no change. Afterwards (all read-only; paste into a `bash` subshell, type `bash` first, because the block uses `exit`):

```bash
# the PrometheusRule carries the alerts and the recording rule
kubectl -n monitoring get prometheusrule kube-prometheus-stack-homelab-webanalytics -o yaml \
  | grep -oE '(alert|record): [A-Za-z:0-9]+'
# Prometheus itself loaded the group (a failed reload would keep the old rules): port-forward, then
nc -z localhost 19090 2>/dev/null && { echo "port 19090 is already in use: stop"; exit 1; }
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null &
PF=$!
for i in $(seq 1 20); do curl -sf http://localhost:19090/-/ready >/dev/null && break; sleep 1; done
curl -sf http://localhost:19090/-/ready >/dev/null && kill -0 "$PF" || { echo "port-forward not ready"; kill "$PF"; exit 1; }
curl -s http://localhost:19090/api/v1/rules | python3 -c 'import sys,json; g=[x for x in json.load(sys.stdin)["data"]["groups"] if x["name"]=="homelab-webanalytics"]; print([r["name"] for r in g[0]["rules"]])'
# the metrics exist (counters are exported with 0 from startup)
curl -s 'http://localhost:19090/api/v1/query?query=count(webanalytics_events_accepted_total)'
curl -s 'http://localhost:19090/api/v1/query?query=count(webanalytics_events_rejected_total)'
kill "$PF"
```

The gauge rules are in; the metric names were verified on the live scrape of 2026-11-09.

#### Runbooks (canonical in data-service; this file keeps the cluster-level steps)

The SQL and the step lists live in homelab-data-service `DEPLOYMENT.md`, section "Runbooks (canonical; ...)", and are tested there against the real schema. They are not repeated here:

| Situation | Data-service runbook | Cluster-level steps here |
|-----------|---------------------|--------------------------|
| A bot burst or poisoned events got through | (1) purge a poisoned day (raw events and the day's aggregates in one transaction) | dump the schema to the Mac first, then run the SQL through `kubectl -n apps exec -i postgresql-0 -c postgresql -- psql ...` (the data-service runbook gives the exact commands) |
| Recompute after a fix | (2) reset D − 1, D, D + 1; (3) re-mark rollup days | same exec path; the rollup runs at 01:12 and 07:30 Europe/Zurich |
| The caps are too low or too high | (4) adjust caps: a `k8s/deployment.yaml` PR in the data-service repo (Flux applies it), then `kubectl -n apps delete pod -l app=data-service` (never `rollout restart`) | none |
| Stop analytics ingest | (5) data-side stop (a cap of 0; it makes `WebAnalyticsIngestCapped` fire, silence it for the duration); prefer furchert-ch's kill switch `ANALYTICS_COLLECT_ENABLED=false` (manifest PR in the furchert-ch repo, Flux applies it, then `kubectl -n apps delete pod -l app=furchert-ch`); forget and DELETE keep working | the rollup kill switch is the environment variable `NETMON_COLLECTORS_WEBANALYTICS_ROLLUP_ENABLED="false"` (data-service manifest PR; `SPRING_APPLICATION_JSON` outranks it, do not set both) |

Capacity: the PostgreSQL volume is 10 GiB since homelab#359 (runbook "Growing the PostgreSQL volume").

#### Cloudflare rules for web analytics (owner, dashboard)

Cloudflare is a processor here (edge and transport) and no analytics product is enabled for the zone.

1. **Web Analytics / RUM and Zaraz off.** Dashboard `furchert.ch` → Web Analytics (no site enabled, no automatic beacon) and Zaraz (no tool configured). Record the result in homelab#351.
2. **`/api/v` outside the auth rate-limit rule.** The Free-plan rule `auth-service: token and login` (see "Cloudflare rules (owner, dashboard; recreate from these settings)" below) matches only `(http.request.uri.path eq "/oauth2/token" or http.request.uri.path eq "/login")`. Check that the expression contains no prefix match such as `starts_with(... "/api")`, so the collect route `/api/v` and `/api/v/forget` are not counted by it. furchert-ch limits `/api/v` itself (spec §5.8).
3. **Optional WAF custom rule** (only the first time the owner wants edge filtering of the collect route; one custom-rule slot, keep the slot reserved for the mcp-hub incident rule free if the plan only has one left, see "L1 — Cloudflare block"): name `web analytics: collect route`, expression
   `(http.host eq "furchert.ch" and http.request.uri.path in {"/api/v" "/api/v/forget"} and (http.request.method ne "POST" or cf.client.bot))`, action **Block**. If `cf.client.bot` is not available on the zone's plan, use `(http.host eq "furchert.ch" and http.request.uri.path in {"/api/v" "/api/v/forget"} and http.request.method ne "POST")`. Undo: disable or delete the rule; the collect route works without it.

#### Backups, NetworkPolicy and restore test

- **Backups (Q2, spec §13):** the nightly dumps, Longhorn snapshots and the Mac app-data dumps are unchanged. They contain the pseudonymous visitor ids of `webanalytics.events`. Erasure and retention act on live data only; copies age out on their own rotation (the Mac dumps when the owner deletes them).
- **NetworkPolicy:** unchanged. The collect path is furchert-ch → data-service `POST /api/webanalytics/events` on the existing policy (`apps/data-service`, TCP 8082 from the furchert-ch pods).
- **Restore test of `data_service` (owner step, schema `webanalytics` only; not run unattended).** Paste each stage into a `bash` subshell (type `bash` first): the stages use shell functions and `exit`, which would otherwise close the interactive shell. The Longhorn volume of the shared PostgreSQL is already close to full at block level (data-service#57), so the test restores one schema, streams the dump over stdin (no copy in `/tmp`) and drops the scratch database at the end.

Run the three stages in the **same `bash` session** (the functions and variables carry over).

*Stage 1: prechecks and the live counts.*

```bash
pg() { kubectl -n apps exec postgresql-0 -c postgresql -- "$@"; }          # no stdin
pgi() { kubectl -n apps exec -i postgresql-0 -c postgresql -- "$@"; }       # with stdin, only for the two pg_restore calls
psqlq() { pg psql -U postgres -t -A "$@"; }
WORK=$(mktemp -d)
COUNTS="SELECT table_name || '=' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema='webanalytics' AND table_type='BASE TABLE' ORDER BY table_name;"

# 0) Free space first. (a) The data directory must be below 70 % and have room for three times the schema
#    size plus 1 GiB (restore, restore-time writes and live-write headroom)
DATADIR=$(pg psql -U postgres -t -A -c "SHOW data_directory;")
pg df -h "$DATADIR"
SIZE=$(psqlq -d data_service -c "SELECT coalesce(sum(pg_total_relation_size(format('%I.%I', schemaname, tablename)::regclass)), 0) FROM pg_tables WHERE schemaname='webanalytics';")
AVAIL=$(pg df -Pk "$DATADIR" | awk 'NR==2{print $4*1024}')
[ -n "$SIZE" ] && [ -n "$AVAIL" ] || { echo "schema size or free space unknown: stop"; exit 1; }
echo "schema size $SIZE bytes, data directory available $AVAIL bytes"
[ "$AVAIL" -gt $((3*SIZE + 1073741824)) ] || { echo "not enough free space on the data directory: stop"; exit 1; }
# (b) ... and every Longhorn replica node must have room too: the filesystem figure does not show the
#     block-level usage of the replicas
kubectl -n longhorn-system get nodes.longhorn.io -o json | python3 -c 'import sys,json
for n in json.load(sys.stdin)["items"]:
    for d in n["status"].get("diskStatus", {}).values():
        print(n["metadata"]["name"], "available %.1f GiB of %.1f GiB" % (d["storageAvailable"]/2**30, d["storageMaximum"]/2**30))'
# Proceed only if each node has more available than three times the schema size plus 1 GiB. Otherwise stop.

# 1) Live counts, taken right before the backup run (outside 01:12 and 07:30)
psqlq -d data_service -c "$COUNTS" > "$WORK/counts-live.txt"
```

*Between the stages:* run `scripts/backup-app-data.sh` (see "App-data backups to the operator's Mac (#64)"). When it finishes, set `RUN` to the directory printed by "Backup complete" (`RUN=~/informatik/homelab/backups/<YYYY-MM-DD_HHMMSS>`); never reuse an older run, matching counts would hide the mistake.

*Stage 2: restore and compare.*

```bash
# 2) The dump contains the schema (the container's pg_restore: no local PostgreSQL client needed)
pgi pg_restore -l < "$RUN/pg-data_service.dump" | grep -E 'SCHEMA - webanalytics'

# 3) Create the scratch database; STOP if it fails (see "After an interrupted test" below)
pg createdb -U postgres restore_test || { echo "restore_test exists or createdb failed: stop"; exit 1; }
# The schema is created in every case: pg_restore -n skips the SCHEMA entry
psqlq -d restore_test -c "CREATE SCHEMA IF NOT EXISTS webanalytics;"
# Restore only that schema, streamed over stdin; the errors are kept before any cleanup
RESTORE_OK=1; SAVED=1
pgi pg_restore -U postgres -d restore_test --no-owner -n webanalytics < "$RUN/pg-data_service.dump" 2> "$WORK/restore.err" || RESTORE_OK=0
[ -s "$WORK/restore.err" ] && RESTORE_OK=0
if [ "$RESTORE_OK" = 0 ]; then
  cp "$WORK/restore.err" "$RUN/restore-test.err" && cmp -s "$WORK/restore.err" "$RUN/restore-test.err" || SAVED=0
  [ "$SAVED" = 1 ] \
    && echo "pg_restore failed or reported errors: details in $RUN/restore-test.err; the test FAILS, skip step 4 and run stage 3" \
    || echo "could not save the errors completely, they stay in $WORK/restore.err (keep that directory); the test FAILS, run stage 3"
fi

# 4) Only when RESTORE_OK=1: counts must match for every table, and at least one non-empty table must be among them
if [ "$RESTORE_OK" = 1 ]; then
  psqlq -d restore_test -c "$COUNTS" > "$WORK/counts-restored.txt"
  diff "$WORK/counts-live.txt" "$WORK/counts-restored.txt" && echo "counts match"
  grep -vE '=0$' "$WORK/counts-live.txt" | head -3
fi
```

*Stage 3: cleanup, mandatory.*

```bash
# 5) Drop the scratch database; if this fails, verify and finish the cleanup by hand before anything else
pg dropdb -U postgres restore_test || { echo "dropdb failed: check with psqlq -d postgres -c '\l', drop restore_test, then continue"; exit 1; }
# keep $WORK when the error file could not be saved completely
{ [ "$RESTORE_OK" = 1 ] || [ "$SAVED" = 1 ]; } && rm -rf "$WORK"
```

The test passes only if `pg_restore` ended without errors (an index or constraint can fail after the rows loaded, with equal counts) and the counts match. If events were written between the count snapshot and the dump, the `events` count can differ by the rows of that window; rerun outside traffic or compare the aggregate tables only and record the reason.

**After an interrupted test.** A leftover `restore_test` blocks the next `createdb`. Check that no restore is still running (`SELECT pid, state FROM pg_stat_activity WHERE datname='restore_test';` through `psqlq -d postgres`; wait or terminate it), then drop the scratch database inside the PostgreSQL container with `kubectl -n apps exec postgresql-0 -c postgresql -- dropdb -U postgres restore_test` (never a bare `dropdb`, which would run on the Mac) and start again from stage 1.

**Before go-live the result can be inconclusive.** A fresh installation with the rollup disabled can have no analytics rows at all (every count `0`); a correct restore then cannot meet the "one non-empty table" criterion. Record "inconclusive" in homelab#351 and repeat the test after the first permitted rollup or the first real events.

#### Owner checks (record each result in homelab#351)

| Check | Where | Pass when |
|-------|-------|-----------|
| Cloudflare Web Analytics/RUM and Zaraz off | dashboard `furchert.ch` | no site enabled, no Zaraz tool |
| `cf.client.bot` available | WAF custom rule editor (field list) | field accepted, else the fallback rule above |
| `/api/v` outside the auth rate-limit rule | Security → WAF → Rate limiting rules | expression matches only `/oauth2/token` and `/login` |
| n8n schedules versus the rollup runs | n8n UI → workflows → schedule triggers | no job fires in the minutes around 01:12 and 07:30 Europe/Zurich, or an overlap is recorded as harmless (the run takes seconds) |
| PVC usage versus the expansion threshold | `kubectl -n apps exec postgresql-0 -c postgresql -- df -h "$(kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -t -A -c 'SHOW data_directory;')"` and the Longhorn UI (block level) for `data-postgresql-0` | usage is recorded against the 10 GiB volume of homelab#359; `WebAnalyticsTableLarge` alerts at 3 GiB of table size, analytics at its cap adds about 2.0 to 2.2 GB of total relation size (spec §7.3, §7.9), on 2026-11-08 (data-service#57) the filesystem was 2.3 G of 4.9 G (48 %) and the Longhorn block level 4.58 GiB of 5 GiB (about 92 %); confirm the unit in the Longhorn UI |

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
| `homelab_k3s_state_db_bytes{node}` | raspi5 only (`netmon_node_k3s_state_db` in `group_vars/k3s_server.yml`): kine `state.db` + WAL bytes → alerts `K3sDatastoreLarge` (> 500 MB for 30 min, warning) and `K3sDatastoreSizeMissing` (absent 1 h, warning); see "k3s datastore (kine/SQLite) maintenance" (#150) |
| `homelab_k3s_kine_compaction_lag_revisions{node}` | raspi5 only (same flag): `MAX(id) - compact_rev_key` from a read-only SQLite read → alerts `K3sKineCompactionLagging` (> 50k for 2 h, warning) and `K3sKineCompactionLagMissing` (absent 1 h while the size gauge is present, warning); see "k3s datastore (kine/SQLite) maintenance" → "Compaction lag (#129)" |

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
- **`K3sDatastoreSizeMissing`** (raspi5): a missing or unreadable `state.db` does **not** make the script stale — it skips only `homelab_k3s_state_db_bytes` and logs `k3s state db skipped: <error>` to `journalctl -u homelab-netmon`. See "k3s datastore (kine/SQLite) maintenance" → "Early warning".
- **`K3sKineCompactionLagMissing`** (raspi5): the SQLite read failed but the script still ran; `journalctl -u homelab-netmon -n 20` shows `k3s kine lag skipped: <error>` (k3s stopped cleanly, a locked or damaged database, or a script older than the gauge: re-run `10_base.yml --tags netmon_node`).
- **Metric has `exported_node` instead of `node`**: would mean the node-exporter ServiceMonitor stopped honouring labels (`honorLabels: true` in chart 69.3.1); data-service's queries rely on `node`.
- **Unit tests** (stdlib only, run before changing the script): `python3 -m unittest discover -s infra/roles/netmon_node/tests -v`.
- **`nf_conntrack_acct`** stays at the kernel default; `netmon_node_conntrack_acct: true` is reserved for the NM-2 fallback (docs/060 §5.5/§6.6).

---

### mcp-hub (Flux, #170 onboarding)

`mcp-hub` gives Claude (claude.ai custom connector) read-only access to mail and calendars through one endpoint, reachable at `https://mcp.furchert.ch/mcp` (tunnel route since #177, live since 2026-10-01). It is Flux-managed like data-service (`cluster/apps/mcp-hub/`), reads its account registry, provider credentials and subject allowlist from the Secret `mcp-hub-secrets` (mounted as files, created by `59_app_services.yml`), and validates access tokens that auth-service issues to the client `claude-mcp-hub`. Contract: `docs/080-mcp-hub.md` (§4.6 incident procedure, §4.7 edge, §7.1 variables); authorization decision: [`docs/adr/0003-mcp-hub-authorization.md`](docs/adr/0003-mcp-hub-authorization.md). Run every command from the repository root. Every step that changes the cluster, Cloudflare or SOPS is an owner action.

Stages a and b are complete (2026-10-01 / 2026-10-02); this section is the reference for later registry changes.

#### Order (first rollout, spec 080 §11.1 WP7)

The go-live has two stages. **Stage a** runs with the registry entry switched off and no provider credential in the cluster; the hub image may already offer the mail tools (spec 080 D61) — with no enabled account they reach no provider. It proves the login, the token, the kill switch and the incident drill in production: the `icloud` registry entry is switched off (`enabled: false`) and `mcp_hub_credentials: {}`, so `icloud` shows `disabled` (`unknown` is reserved for enabled accounts whose adapter or check has not run yet). **Stage b** follows once the mail and calendar tools have shipped: it switches the `icloud` entry on and adds its credentials (step 13). Stage a was completed on 2026-10-01; stage b was switched on on 2026-10-02 (acceptance: `homelab#170`). Rolling back at any stage: once auth-service has seeded the `claude-mcp-hub` client (step 5), a revert of the auth-service change, an older auth-service image or a removed or renamed client entry is allowed only after "Disable and remove the `claude-mcp-hub` client" ("mcp-hub incident runbook").

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
13. Stage b (after the hub release with the mail and calendar tools is running): in the same SOPS edit set `enabled: true` on the `icloud` entry of `mcp_hub_accounts` and add `icloud-username` and `icloud-app-password` to `mcp_hub_credentials` (step (f)), run playbook 59 (step (h)), then restart the hub (step (n)) — the registry changed, and the hub reads it only at start-up (without the editor: "Stage b without the editor" below). No route or rule change. `list_accounts` shows `icloud` as `ok` after the first background status check, about 30 s after the restart (`unknown` before it), no longer `disabled`; the check repeats every 30 min (`HUB_HEALTH_CHECK_INTERVAL_SECONDS` in the hub's own manifest). Ask for tomorrow's events and for unread iCloud mail. Stage-b symptoms are under "Troubleshooting" below.

A pod that starts before step 4 waits in `ContainerCreating` (Secret volume missing) and starts by itself once the Secret exists.

Restart Flux-managed Deployments by deleting the pod: `kubectl -n apps delete pod -l app=auth-service` or `kubectl -n apps delete pod -l app=mcp-hub`. A `kubectl rollout restart` works once, but Flux removes its annotation at the next reconcile and the pod restarts a second time.

**Which Secret changes need a hub restart.** The kubelet refreshes every key of `mcp-hub-secrets` in the running pod within about 1–2 min, but the hub uses them differently:

| Key | Read by the hub | After a change |
|-----|-----------------|----------------|
| `accounts.json` (registry) | once, at start-up | **delete the hub pod** (step (n)) — every registry change: stage b, a new account (`gmail` #172, `outlook` #171, `uzh` #173), `enabled` on or off. Once the hub has `check-registry` (#171), run the registry check (e2) of "mcp-hub token store and the Outlook account" before the pod deletion |
| `allowed-subjects` | re-read at least every 60 s | nothing (kill switch L2 adds a pod delete only to be faster) |
| credential keys (`icloud-username`, …) | when a provider connection opens; presence checked per `list_accounts` call | nothing, as long as the key names in `accounts.json` stay the same; a renamed or new key is a registry change |
| `db-username`, `db-password`, `token-encryption-key` (#171) | per database connection or token refresh | nothing; a key change outside the rotation (k) of "mcp-hub token store and the Outlook account" means a re-login of every Graph account |
| `token-encryption-key-previous` (#171, rotation only) | per use | nothing; remove it only through (k) |
| `db-password` change (#171, deliberate password rotation) | per database connection | nothing, but playbook 59 runs `ALTER ROLE` before the Secret file is refreshed on the node: expect token-store errors (`OperationalError`) for about 2 min |

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

##### Stage b without the editor (`sops set`)

Step 13 can also be done without the editor, in the same style as the step (f) alternative. Paste the commands one at a time (the `if … fi` block counts as one command and is pasted only after both prompts have been answered). The two `read` lines prompt for the iCloud user name and the app-specific password (they work in zsh and bash); the password is not echoed, so press Enter after typing it.

```bash
F=infra/inventory/group_vars/all.sops.yml
printf 'iCloud user name: '; IFS= read -r U
printf 'App-specific password: '; IFS= read -rs P; printf '\n'
if [ -n "$U" ] && [ -n "$P" ]; then
  sops set "$F" '["mcp_hub_accounts"]["accounts"][0]["enabled"]' 'true'
  printf '%s' "$U" | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_credentials"]["icloud-username"]'
  printf '%s' "$P" | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_credentials"]["icloud-app-password"]'
else
  echo 'Empty input: nothing was written. Run the block again.'
fi
unset U P
```

Then commit the re-encrypted file through a pull request (as for step (f)), run playbook 59 (step (h)) and restart the hub (step (n)).

**Go-live result (2026-10-02).** Stage b was switched on on 2026-10-02. After the last step, about 30 s after the pod start, the hub log showed `status_check_cycle` with `outcome: ok` and `result_count: 2`, and `list_accounts` showed both capabilities (mail, calendar) working; use the same two checks after any later registry or credential change. Lesson: a mistyped value needed a second SOPS commit (`homelab#189`). The block above can simply be run again to overwrite the values; then commit through a pull request, re-run playbook 59 and delete the hub pod again (step (n)).

**User names for mail and calendar.** Apple documents the Apple Account e-mail as the CalDAV user name and the iCloud Mail address (or its name part) as the IMAP user name; when the Apple Account is not an iCloud address, the two differ. The registry allows a separate credential key per capability (`mail.username_ref`, `calendar.username_ref`). If `list_accounts` shows `auth_expired` for one capability and `ok` for the other after the first status check, add a second user-name key to `mcp_hub_credentials`, point that capability's `username_ref` to it in `mcp_hub_accounts`, run playbook 59 and delete the hub pod (step (n); a registry change). At go-live (2026-10-02) one username key served both mail and calendar, so this fallback was not needed.

**Resources.** The hub pod has a CPU limit of 1 and a memory limit of 320 Mi (D86); memory gate for the mail tools and `get_thread`: cgroup `memory.peak` ≤ 290 MiB with `oom_kill` 0 at `--memory=320m` (measured 2026-10-27, peak 255 MiB with the calendar scenario). Measured in the production image, one calendar account stays at or below about 165 MiB in the worst case. Before a second calendar account is enabled (a later story), raise the memory limit or query the accounts one after another (spec 080 R26).

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
kubectl -n platform logs -l pod=cloudflared --prefix --tail=20 --request-timeout=10s
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

Stage b (the calendar and mail tools with `icloud` enabled):

- `icloud` stays `unknown` for more than a minute after step (n): the background status check is off in the running hub. It runs only with `HUB_STATUS_CHECK_ENABLED` set to `true` in the hub repository's `k8s/` manifest (spec 080 D57). Check the running Deployment: `kubectl -n apps get deploy mcp-hub --request-timeout=10s -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'`. If it is missing, the CalDAV release of the hub is not deployed yet (step (j)).
- `icloud` shows `auth_expired`, and the hub log has a `status_check_failed` line with `outcome=auth_expired`: Apple refused the app-specific password (revoked, or the Apple Account password changed). Create a new app-specific password, put it into `icloud-app-password` in SOPS and run playbook 59. The key name stays the same, so no restart is needed; the status returns to `ok` at the next check (at most 30 min), or at once after step (n).
- `get_events` answers with `truncated: true`: a recurrence-expansion cap or the expansion time budget stopped the call (spec 080 D62). Ask again for a shorter time window. A `calendar_object_skipped` line in the hub log means that one calendar object was refused (for example a recurrence rule finer than daily) and left out; the other events are still returned. This is expected behaviour, not a hub fault.
- `get_events` returns `skipped_objects` greater than 0: one or more calendar objects were left out. `kubectl -n apps logs deploy/mcp-hub --since=10m --request-timeout=10s | grep calendar_object_skipped` shows the `outcome` per skipped object (`rule_refused`, `object_too_large`, `too_many_components`, `too_many_dates`, `start_out_of_range`, `expansion_too_slow`). This is expected for unusual objects (limits in spec 080 §5.4). One known case to report back: a custom time zone with several open-ended rule pairs.
- `search_messages` lists an account in `incomplete_accounts` (spec 080 §5.2, D85): `result_cap` — more matches than one search returns; on iCloud or Gmail narrow `since` or add filters, on Outlook use other or more specific words. `search_refused` — the server refused to search a folder (for example `NO [BADCHARSET]`), or no Gmail query word was searchable. `time_limit` — the soft stop came first (Gmail searches can take several seconds, homelab-mcp-hub#64); narrow `since`. `changed_during_call` — mail moved or was expunged during the call; repeat the call.

Playbook 40 (tunnel route, step (l)):

- "Cloudflared deployen" fails because the chart archive cannot be fetched (on 2026-10-01 GitHub answered 504 for `cloudflare-tunnel-remote-0.1.2.tgz`, although the chart was cached): apply the route without the Helm step with `ansible-playbook infra/playbooks/40_platform.yml --start-at-task "CF Ingress-Konfiguration als Variable setzen"` — the tasks from there on depend only on variables. Run the whole playbook again later.
- The cloudflared restart drops an SSH forward that runs through the tunnel (off-LAN `kubectl`/Ansible), so a task after it can fail with "connection refused". Re-establish the forward ("Off-LAN kubectl / Ansible Access") and run the same command again; the playbook is idempotent.

Backups: the token-store database `mcp_hub` (#171) is excluded from `scripts/backup-app-data.sh` by design — see "App-data backups to the operator's Mac (#64)" and (m) of "mcp-hub token store and the Outlook account".

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

### mcp-hub token store and the Outlook account (#171 onboarding)

`outlook` (Outlook.com mail through Microsoft Graph, no calendar) needs the hub's token store: the PostgreSQL database `mcp_hub` (role `mcp_hub`, schema `mcp_hub`) and the `mcp-hub-secrets` keys `db-username`, `db-password` and `token-encryption-key`, created by playbook 59 once the SOPS variables `mcp_hub_db_password` and `mcp_hub_token_encryption_key` are set (set both or neither; they need the three `mcp_hub_*` hub variables). The refresh token is stored encrypted; the hub derives the key id from the key, so a key rotation (k) needs no hub change. Contract: `docs/080-mcp-hub.md` §6.3, §7.2, §7.3, §9.6. Run every command from the repository root unless it starts with `cd`. Every step that changes the cluster, Microsoft or SOPS is an owner action. Order: (a) → (b) → (c) → (c2) → (d) → (e) → (e2) → (f) → (g) → (h) → (i).

**(a) Preconditions** (read-only):

```bash
kubectl config current-context
# must be a LAN context: default (~/.kube/homelab.yaml) or home. Off-LAN see (d): kubectl config use-context tunnel
gh pr list -R doemefu/homelab-mcp-hub --state merged --search "Graph mail adapter in:title" --json number,title,mergedAt
kubectl -n apps get deploy mcp-hub -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' --request-timeout=10s
kubectl -n apps exec deploy/mcp-hub -c mcp-hub --request-timeout=10s -- mcp-hub login; echo "exit $?"
# expect: one row, the merged "Graph mail adapter" PR; the image tag main-YYYYMMDDTHHMMSS (UTC) is LATER than its
# mergedAt (otherwise Flux has not rolled PR B yet: wait and repeat); usage text and exit 2 (the login command is present)
```

**(b) App registration** (one registration, shared with the later `uzh` account, spec 080 D68). In your own Entra tenant: App registrations → New registration (or the existing shared registration), Supported account types **Any Entra ID Tenant + Personal Microsoft accounts**, no redirect URI, no client secret; API permissions: remove `User.Read`, add Microsoft Graph delegated `Mail.Read`, `Calendars.Read` and `offline_access` (the `outlook` login requests only `Mail.Read` and `offline_access`); Authentication: **Allow public client flows = Yes**. Keep the Application (client) ID in the password manager; it goes into SOPS below and nowhere else. Do not upgrade the Azure free subscription and create no Azure resources (spec 080 §6.3, R28).

**(c) SOPS values (editor-free).** Run in your checkout, on `main`, up to date. The password and the key are generated only if absent and never displayed; the key changes only through (k). The `read` line prompts for the client ID from (b); a value that is not a GUID writes nothing. The registry entry is appended only after the client ID was written and only if the registry is exactly `[icloud]`, so a second run never overwrites an entry.

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch main && git pull --ff-only
F=infra/inventory/group_vars/all.sops.yml
sops decrypt --extract '["mcp_hub_db_password"]' "$F" >/dev/null 2>&1 || openssl rand -hex 24 | tr -d '\n' | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_db_password"]'
sops decrypt --extract '["mcp_hub_token_encryption_key"]' "$F" >/dev/null 2>&1 || openssl rand -base64 32 | tr -d '\n' | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_token_encryption_key"]'
OK=0; printf 'Outlook app (client) ID: '; IFS= read -r CID; CID=$(printf '%s' "$CID" | tr 'A-F' 'a-f')
if printf '%s' "$CID" | grep -Eq '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'; then printf '%s' "$CID" | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_credentials"]["outlook-ms-client-id"]' && OK=1; else echo 'Not a client ID: nothing written. Run this block again.'; fi; unset CID
if [ "$OK" != 1 ]; then echo 'Fix the client ID first: nothing appended.'; else IDS=$(sops decrypt --extract '["mcp_hub_accounts"]["accounts"]' --output-type json "$F" | jq -c '[.[].id]'); if [ "$IDS" = '["icloud"]' ]; then sops set "$F" '["mcp_hub_accounts"]["accounts"][1]' '{"id":"outlook","label":"Outlook.com","provider":"microsoft","enabled":true,"capabilities":{"mail":true,"calendar":false},"graph":{"tenant":"consumers","client_id_ref":"outlook-ms-client-id","scopes":["Mail.Read","offline_access"]},"mail":{"protocol":"graph"}}'; elif [ "$IDS" = '["icloud","outlook"]' ]; then echo 'outlook already present: nothing appended.'; else echo 'Registry is not exactly [icloud]: nothing appended. Stop and check the registry.'; fi; unset IDS; fi; unset OK
sops decrypt --extract '["mcp_hub_accounts"]["accounts"]' --output-type json "$F" | jq -c '[.[].id]'
# expect: ["icloud","outlook"]
```

Then commit the SOPS change through a pull request (as `#188`):

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch -c chore/sops-mcp-hub-outlook && git add infra/inventory/group_vars/all.sops.yml && git commit -m "chore(sops): mcp-hub token store and the outlook account (#171)" && git push -u origin chore/sops-mcp-hub-outlook && gh pr create -R doemefu/homelab --fill
```

**(c2) Merge the SOPS PR, then check presence (value-free).** Merge the PR in GitHub, then:

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch main && git pull --ff-only && F=infra/inventory/group_vars/all.sops.yml && for k in mcp_hub_db_password mcp_hub_token_encryption_key; do sops decrypt --extract "[\"$k\"]" "$F" >/dev/null 2>&1 && echo "$k present" || echo "$k MISSING - stop"; done; sops decrypt --extract '["mcp_hub_credentials"]' --output-type json "$F" | jq -r 'keys[]' | grep -x outlook-ms-client-id || echo "outlook-ms-client-id MISSING - stop"
```

**(d) Playbook 59** — check mode, then twice. On the LAN:

```bash
cd /Users/dominic/informatik/homelab/infrastructure && ansible-playbook infra/playbooks/59_app_services.yml --check --diff
# expect: the asserts pass; the kubectl exec tasks are skipped in check mode; the Secret tasks show a hidden (no_log) change
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml
# expect run 1: "Mcp-hub token store — create PostgreSQL role" and "… create PostgreSQL database" changed, the Secret task changed;
# expect run 2: no mcp-hub task changed (the password tasks always report ok)
```

Off-LAN: the playbook's tasks run `kubectl` locally with the LAN kubeconfig. Start the port-forward of "Off-LAN kubectl / Ansible Access" first, run `kubectl config use-context tunnel`, then run the same commands with ` -e kubeconfig="$HOME/.kube/config"` appended (see the gotcha "playbooks hardcode the LAN kubeconfig" in that section).

A partial setup (only one of the two variables, or the token-store variables without the three hub variables, or a malformed value) fails in the playbook's Guards section, before any database or Secret task of any service.

**(e) Checks** (read-only):

```bash
kubectl -n apps get secret mcp-hub-secrets -o json --request-timeout=10s | jq -r '.data | keys[]'
# expect additionally: db-password, db-username, outlook-ms-client-id, token-encryption-key
kubectl -n apps exec postgresql-0 -c postgresql --request-timeout=10s -- psql -U postgres -tAc "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname='mcp_hub'"
# expect: mcp_hub|mcp_hub
kubectl -n apps exec postgresql-0 -c postgresql --request-timeout=10s -- psql -U postgres -tAc "SELECT rolcanlogin, rolpassword IS NOT NULL, rolsuper FROM pg_authid WHERE rolname='mcp_hub'"
# expect: t|t|f
```

**(e2) Registry check BEFORE the restart** (spec 080 §9.6, D66). The hub Deployment uses `Recreate`: a fatal registry error in the new pod would stop `icloud` too. The expected hash is computed from the Secret's own `accounts.json`; only the hash is printed:

```bash
S=$(kubectl -n apps get secret mcp-hub-secrets -o jsonpath='{.data.accounts\.json}' --request-timeout=10s | base64 -d | shasum -a 256 | cut -c1-12); echo "expected registry sha: $S"
if [ -z "$S" ] || [ "$S" = e3b0c44298fc ]; then echo 'Secret not read - check the kubectl context (kubectl config current-context)'; else kubectl -n apps exec deploy/mcp-hub -c mcp-hub --request-timeout=30s -- mcp-hub check-registry --expect-sha "$S"; echo "exit $?"; fi
# expect: "registry sha=… projected=…" with the same 12 hex as above, "registry ok", "account icloud mail imap ok",
#         "account icloud calendar caldav ok", "account outlook mail graph ok", "account outlook key ok",
#         "account outlook token none", exit 0.
# "not the expected one yet": the kubelet has not refreshed the volume (up to about 2 min) - wait a minute and repeat.
# Any "registry error …" or "missing …": do NOT delete the pod; fix SOPS ((c)), merge, rerun (d), repeat (e2).
```

Run (e2) **directly after (d)**: it protects only the planned pod deletion. An unplanned restart in between (a Flux image roll, a node reset, a liveness restart) would start on an unchecked registry.

**(f) Restart the hub** (the registry changed): `kubectl -n apps delete pod -l app=mcp-hub`. Wait until the replacement pod is Ready (`kubectl -n apps get pod -l app=mcp-hub`), then about 30 s more: `token_store_migrated` and `token_refresh` `no_token` appear about 30 s after start-up, so an earlier check shows nothing. Then in claude.ai `list_accounts` shows `outlook` mail **auth_expired** (no token yet) — expected. Hub log:

```bash
kubectl -n apps logs deploy/mcp-hub --since=5m --request-timeout=10s | grep -E '"event": "(token_store_migrated|token_refresh)"'
# expect token_store_migrated once and token_refresh with "outcome": "no_token"
```

**(g) Login** (owner's go for the cluster action; the command refuses to run without `-it`):

```bash
kubectl -n apps exec -it deploy/mcp-hub -c mcp-hub -- mcp-hub login outlook
# off-LAN, one shot:
ssh -t -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch 'sudo k3s kubectl -n apps exec -it deploy/mcp-hub -c mcp-hub -- mcp-hub login outlook'
```

- The command prints an address and a code. Open the address in a private browser window, enter the code and sign in with the Outlook.com account.
- **Before you approve:** the app name must be the one you registered, and the list must contain only mail read and "Maintain access to data you have given it access to". Anything else, or a code you did not just see in this terminal → close the window and do not approve.
- Exit 0 = stored; 1 = declined, expired or refused (run again; "Refused host: …" → report the host); 2 = configuration (token-store keys or registry missing, or no terminal).

**(h) Verify.** In claude.ai, ask "What's unread in Outlook since yesterday?". Then open one listed mail (`get_message`, mandatory). Then ask "What's on my calendar tomorrow?": `outlook` is skipped without an error. The hub log shows `token_refresh` with `"outcome": "ok"` and `tool_call` lines with outcome `ok`. `list_accounts` turns `ok` at the next status check (≤ 30 min) or after the call.

**(i) Definition-of-done checks:**

- Daily for 7 days (session lead); the count must be > 0 each day:

  ```bash
  kubectl -n apps logs deploy/mcp-hub --since=24h --request-timeout=10s | grep '"event": "token_refresh"' | grep -c '"outcome": "ok"'
  ```

  Pod logs do not survive a restart or rollout: run the count on each of the 7 days and record it the same day.

- **Mandatory revocation test:**
  0. Record the current count with the daily `grep` (the pod log is lost at step 2).
  1. Remove the app's access in the Microsoft account's app-permissions settings (the account privacy settings list it under apps that can access your data).
  2. Run `kubectl -n apps delete pod -l app=mcp-hub`.
  3. Wait about 60 s: `list_accounts` shows `outlook` mail `auth_expired`, and the log shows `token_refresh` with `"outcome": "invalid_grant"` and an `error_code`.
  4. Restore with (g).

  Observed result (2026-10-27): the removal revokes the refresh token. The first refresh after the pod restart logged `"outcome": "invalid_grant"` with `error_code` 70000, `list_accounts` showed `outlook` mail `auth_expired`, and the login of (g) restored it; its consent page listed no calendar permission.

  If refreshes still succeed after the removal, report it: the cut-off order (spec 080 §4.6, "Cutting off a Graph account") then needs a password change.

  If the log shows `token_refresh` with `"outcome": "error"` and an `error_code` instead (Microsoft answered with a status other than HTTP 400), `list_accounts` shows `outlook` mail `error`, not `auth_expired`: record the status and restore with (g); spec 080 §6.3 "Failure modes" is then amended.
- **Tenant checks** on day 31 and day 35 after the sign-up (session lead), only for a tenant created through a time-limited Azure free subscription (R28); not needed when the registration lives under an existing Azure account. The checks are the same `grep` and `list_accounts`.

**(j) Troubleshooting:**

| Symptom | Meaning | Action |
|---|---|---|
| login exit 2 "token store is not configured" | (c)–(e) not done | Do (c)–(e) |
| login exit 2 "interactive terminal" | `-it` missing | Rerun with `-it` |
| `token_refresh` `no_token` | No login yet | Run (g) |
| `invalid_grant` / `invalid_grant_recorded` | Microsoft rejected the refresh token | Run (g) |
| `upstream_error` with exception `ClientRejected`, or login "Microsoft refused the app registration" | Client id wrong, or public client flows off | Fix (b) |
| `upstream_error` `Forbidden` | Permission or licence on the Microsoft side; a re-login does not help | Check the registration's permissions |
| `persist_failed` (ERROR) | PostgreSQL problem; the previous token normally still works | Check `postgresql-0`, retry |
| `decrypt_failed` | The key changed without (k) | Run (g) |
| `upstream_error` with cause `KeyUnavailable`; `token_refresh` field `exception` = `KeyUnreadable`, `KeyLength` or `SameKey` | The key file is missing, unreadable or not strict base64 (`KeyUnreadable`), the key is not exactly 32 bytes (`KeyLength`), or current = previous (`SameKey`) | Fix SOPS, (d) |
| `upstream_error`; `token_refresh` field `exception` = `OperationalError` | No connection to the token store: the database is missing, the credentials are wrong or PostgreSQL is unreachable (the driver reports all three the same way) | Check `postgresql-0` and (e); a missing database → (m); wrong credentials → (d) |
| `token_refresh` with `outcome=error` and field `exception` = `ConnectError`, `ConnectTimeout`, `TokenEndpointStatus` or similar, or `CallDeadline` / `TokenLock` | Microsoft's token endpoint is unreachable, slow or failing (egress, Microsoft outage); `CallDeadline` / `TokenLock`: the call ran out of time before or while waiting for a refresh | Check egress from the pod and Microsoft's service status; no owner action unless it persists |
| `Throttled` | Microsoft back-off | Wait ≤ 5 min |
| `check-registry` "registry error …" | The registry entry is malformed | Fix SOPS; do not delete the pod |

**(k) Key rotation** (the key id is derived from the key, so the hub manifest does not change):

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch main && git pull --ff-only && F=infra/inventory/group_vars/all.sops.yml
# 0. the kubectl context must be a LAN context (default in ~/.kube/homelab.yaml, or home)
kubectl config current-context
# 1. ONE guarded command — safe to run twice, never drops the original key:
#    previous absent → copy current to previous, then write a new current; previous == current (an interrupted
#    start) → only write a new current; previous present and different → rotation already started, change nothing.
none=$(printf '' | shasum); cur=$(sops decrypt --extract '["mcp_hub_token_encryption_key"]' "$F" 2>/dev/null | shasum); prev=$(sops decrypt --extract '["mcp_hub_token_encryption_key_previous"]' "$F" 2>/dev/null | shasum)
if [ "$cur" = "$none" ]; then echo 'Current key not readable: nothing changed. Stop.'; elif [ "$prev" = "$none" ]; then sops decrypt --extract '["mcp_hub_token_encryption_key"]' "$F" | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_token_encryption_key_previous"]' && openssl rand -base64 32 | tr -d '\n' | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_token_encryption_key"]' && echo 'Rotation started: previous = old key, new current key written.'; elif [ "$prev" = "$cur" ]; then openssl rand -base64 32 | tr -d '\n' | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_token_encryption_key"]' && echo 'Interrupted start completed: new current key written.'; else echo 'Rotation already in progress (previous differs from current): nothing changed. Continue with step 2.'; fi; unset none cur prev
# 2. own branch and PR, merge it in GitHub, then pull and note the time BEFORE playbook 59
git switch -c chore/sops-mcp-hub-key-rotation && git add infra/inventory/group_vars/all.sops.yml && git commit -m "chore(sops): rotate the mcp-hub token encryption key (#171)" && git push -u origin chore/sops-mcp-hub-key-rotation && gh pr create -R doemefu/homelab --fill
```

Merge the PR in GitHub, then:

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch main && git pull --ff-only && F=infra/inventory/group_vars/all.sops.yml && T0=$(date -u +%Y-%m-%dT%H:%M:%SZ) && echo "playbook started at $T0" && ansible-playbook infra/playbooks/59_app_services.yml
# 3. gate on the projection time: the volume must have been refreshed AFTER T0
S=$(kubectl -n apps get secret mcp-hub-secrets -o jsonpath='{.data.accounts\.json}' --request-timeout=10s | base64 -d | shasum -a 256 | cut -c1-12)
if [ -z "$S" ] || [ "$S" = e3b0c44298fc ]; then echo 'Secret not read - check the kubectl context (kubectl config current-context)'; else P=$(kubectl -n apps exec deploy/mcp-hub -c mcp-hub --request-timeout=30s -- mcp-hub check-registry --expect-sha "$S" | sed -n 's/^registry sha=[0-9a-f]* projected=\([^ ]*\)$/\1/p'); if [[ "$P" != 20??-??-??T??:??:??Z ]]; then echo "projected time not readable ($P): wait a minute and repeat this step"; elif [[ "$P" > "$T0" ]]; then echo "projected $P after $T0: continue"; else echo "projected $P not after $T0: wait a minute and repeat this step"; fi; fi
# (the date-format check keeps "projected=unknown" from passing the comparison)
# continue only after "continue"; "token previous" or "token current" are both fine at this point
# 4. force a refresh (drops the cached access token; the first status check 30 s later re-encrypts the row)
kubectl -n apps delete pod -l app=mcp-hub
# 5. about 60 s later, every ENABLED Graph account must show "token current":
kubectl -n apps exec deploy/mcp-hub -c mcp-hub --request-timeout=30s -- mcp-hub check-registry --expect-sha "$S"
# 5b. value-free database gate: check-registry skips disabled accounts and cannot see rows of
#     accounts no longer in the registry. Every stored row must carry the current key's derived id.
E=$(sops decrypt --extract '["mcp_hub_token_encryption_key"]' "$F" | base64 -d | shasum -a 256 | cut -c1-16); echo "current key id: $E"
kubectl -n apps exec postgresql-0 -c postgresql --request-timeout=10s -- psql -U postgres -d mcp_hub -tAc "SELECT account_id, key_id FROM mcp_hub.provider_tokens UNION ALL SELECT '#end', ''" | awk -F'|' -v e="$E" '$1 == "#end" {ok = 1; next} NF == 2 && $2 != e {print "NOT CURRENT: " $1} END {print ok ? "rows checked" : "NO RESULT - check the kubectl context and the database"}'
# expect only "rows checked"; the sentinel row "#end" proves the query ran (a failed kubectl/psql prints NO RESULT)
```

- If step 5 shows `previous`, or step 5b prints a `NOT CURRENT: …` line:
  - an **enabled** account (a recorded invalid grant, no refresh yet) → run (g) for it; the login re-encrypts the row;
  - a **disabled** account or a row of an account no longer in the registry → delete that row (re-enabling the account later needs a login anyway):

    ```bash
    printf 'account id whose row is deleted: '; IFS= read -r A; if printf '%s' "$A" | grep -Eq '^[a-z][a-z0-9-]{1,31}$'; then kubectl -n apps exec postgresql-0 -c postgresql --request-timeout=10s -- psql -U postgres -d mcp_hub -c "DELETE FROM mcp_hub.provider_tokens WHERE account_id='$A'"; else echo 'Not an account id: nothing deleted.'; fi; unset A
    ```

    Then repeat steps 5 and 5b.
- **Only when step 5 shows `current` for every enabled Graph account and step 5b prints only "rows checked":**

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch main && git pull --ff-only && F=infra/inventory/group_vars/all.sops.yml && sops unset "$F" '["mcp_hub_token_encryption_key_previous"]' && git switch -c chore/sops-mcp-hub-key-rotation-done && git add infra/inventory/group_vars/all.sops.yml && git commit -m "chore(sops): finish the mcp-hub token key rotation (#171)" && git push -u origin chore/sops-mcp-hub-key-rotation-done && gh pr create -R doemefu/homelab --fill
```

Merge the PR in GitHub, then (playbook 59 does not delete Secret keys, so the key is removed by hand after a key-name check):

```bash
if [ "$(kubectl -n apps get secret mcp-hub-secrets -o json --request-timeout=10s | jq -r '.data | has("token-encryption-key-previous")')" = true ]; then kubectl -n apps patch secret mcp-hub-secrets --type=json -p '[{"op":"remove","path":"/data/token-encryption-key-previous"}]'; else echo 'token-encryption-key-previous not found (or the Secret was not read): nothing removed.'; fi
kubectl -n apps get secret mcp-hub-secrets -o json --request-timeout=10s | jq -r '.data | keys[]'
# expect: token-encryption-key-previous is gone
```

A rotation protects only ciphertexts written afterwards; it revokes no refresh token (spec 080 §7.2, threat model).

**(l) Turning Outlook off** (guarded like (c)):

```bash
cd /Users/dominic/informatik/homelab/infrastructure && F=infra/inventory/group_vars/all.sops.yml && if [ "$(sops decrypt --extract '["mcp_hub_accounts"]["accounts"]' --output-type json "$F" | jq -c '.[1].id')" = '"outlook"' ]; then sops set "$F" '["mcp_hub_accounts"]["accounts"][1]["enabled"]' 'false'; else echo 'Entry 1 is not outlook: nothing changed.'; fi
```

Then PR + merge, (d), (e2), and the pod delete. The token row stays (ciphertext); to cut the account off for good, follow spec 080 §4.6 "Cutting off a Graph account" (remove consent, which revokes the refresh token as observed in (i); a password change only if a copy of the key and of the ciphertext may have leaked; then delete the row).

**(m) Restore after a PostgreSQL instance loss.**

- Database `mcp_hub` is excluded from the app-data dumps by design ("App-data backups to the operator's Mac (#64)"): a stored ciphertext plus the key is most likely a live mailbox credential.
- While it is missing, the hub answers `upstream_error` for `outlook` (log `token_refresh` with field `exception` = `OperationalError` — the driver reports a missing database like any other failed connection), `list_accounts` shows `outlook` mail `error`, and the login exits 1 ("could not be stored").
- `pg-dumpall.sql.gz` is written with `--clean`; PostgreSQL 17 still emits `DROP DATABASE IF EXISTS mcp_hub` for the excluded database, so restoring it onto a running instance deletes the token store — afterwards run the fix below (playbook 59, then the login).
- Fix: run playbook 59 as in (d), then the login (g). Playbook 59 creates the database (the role comes back with the `pg_dumpall` globals or is created; the password is reset). The first hub use migrates; `list_accounts` then shows `auth_expired` until the login.
- Longhorn snapshots still hold the ciphertext; a snapshot restore brings back an older refresh token that most likely still works (Microsoft does not revoke previous tokens on use). Never store the key next to any copy of the database.

**One client ID for `outlook` and the later `uzh`** (D68). The shared registration has one client ID. It is stored once, as `mcp_hub_credentials["outlook-ms-client-id"]` (the spec 080 §8.1/§8.2 key for `#171`). Playbook 59 writes every key of `mcp_hub_credentials` into `mcp-hub-secrets`, and the registry's `client_id_ref` values are plain file names (§8.2), so a later `uzh` entry can name the same file (`"client_id_ref": "outlook-ms-client-id"`) without a second SOPS value. A neutral key name, or the decision to point `uzh` at the existing key, belongs in `#173`'s spec change; if the key is renamed then, the rename moves the value with `sops set` and changes the `outlook` entry's `client_id_ref` in the same SOPS commit, followed by (e2).

### mcp-hub: Gmail account (#172)

`gmail` (a personal Gmail account, mail only, no calendar) is pure configuration: the hub's IMAP adapter is reused unchanged (spec 080 §6.2) and playbook 59 already writes every `mcp_hub_credentials` key into `mcp-hub-secrets`. No hub image, manifest, egress or Cloudflare change (Gmail IMAP `:993` is already listed in `INTERFACES.md`). Run every command from the repository root unless it starts with `cd`. Every step that changes SOPS or the cluster is an owner action. The account order in the registry (`icloud`, `outlook`, `gmail`) does not matter to the hub. Order: (a) → (b) → (c) → (c2) → (d) → (e) → (e2) → (f) → (g).

**(a) Prerequisites** (owner, in the Google account; never write the address or the app password into the repository):

- A personal Google account (not Workspace) with 2-Step Verification on. App passwords are not offered with Advanced Protection or with security-key-only 2-Step Verification.
- Create an app password at `https://myaccount.google.com/apppasswords` (any name). Google shows 16 letters in groups of four; keep it in the password manager.
- IMAP is always on for personal accounts; there is no setting to switch.
- Changing the Google account password revokes every app password: afterwards create a new one and repeat (c) for the password key only.
- Read-only preconditions:

```bash
kubectl config current-context
# must be a LAN context: default (~/.kube/homelab.yaml) or home. Off-LAN: see (d) and "Off-LAN kubectl / Ansible Access"
kubectl -n apps exec deploy/mcp-hub -c mcp-hub --request-timeout=30s -- mcp-hub check-registry; echo "exit $?"
# expect: "registry ok" and the existing accounts (icloud, outlook), exit 0, no "gmail" line yet
```

**(b) #171 acceptance count first** (only while the 7-day window of the Outlook definition-of-done check (i) is still open, until 2026-10-13). The pod deletion in (f) resets the hub's in-memory state and the 24 h log window shows the restart, so record that day's count before it:

```bash
kubectl -n apps logs deploy/mcp-hub --since=24h --request-timeout=10s | grep '"event": "token_refresh"' | grep -c '"outcome": "ok"'
```

**(c) SOPS values (editor-free).** In your checkout, on `main`, up to date. Paste the commands one at a time (the `if … fi` blocks count as one command each; paste the second block only after the first one answered). The address is read visibly, the app password is not echoed (press Enter after typing it); spaces in the password are removed, and a value that is not 16 characters writes nothing. The registry entry is appended only after both values were written and only if the id `gmail` is not yet in `mcp_hub_accounts.accounts`; the index is the current length, so no list of the other ids is assumed (reuse this guard for `uzh` in #173 with its own id and entry).

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch main && git pull --ff-only
F=infra/inventory/group_vars/all.sops.yml; OK=0
printf 'Gmail address: '; IFS= read -r U
U=$(printf '%s' "$U" | tr -d '[:space:]')
printf 'Gmail app password: '; IFS= read -rs P; printf '\n'; P=$(printf '%s' "$P" | tr -d ' ')
if [ -n "$U" ] && [ "${#P}" = 16 ]; then
  printf '%s' "$U" | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_credentials"]["gmail-username"]' \
    && printf '%s' "$P" | jq -Rs . | sops set --value-stdin "$F" '["mcp_hub_credentials"]["gmail-app-password"]' \
    && OK=1
else
  echo 'Empty address or password that is not 16 characters: nothing written. Run this block again.'
fi
unset U P
```

```bash
if [ "$OK" != 1 ]; then echo 'Credentials not written: nothing appended.'; else
  IDS=$(sops decrypt --extract '["mcp_hub_accounts"]["accounts"]' --output-type json "$F" | jq -c '[.[].id]')
  if [ -z "$IDS" ]; then echo 'Registry not readable: nothing appended. Stop.'
  elif [ "$(printf '%s' "$IDS" | jq 'index("gmail") == null')" != true ]; then echo 'gmail already present: nothing appended. Stop and check the registry.'
  else
    N=$(printf '%s' "$IDS" | jq 'length')
    sops set "$F" "[\"mcp_hub_accounts\"][\"accounts\"][$N]" '{"id":"gmail","label":"Gmail","provider":"google","enabled":true,"capabilities":{"mail":true,"calendar":false},"mail":{"protocol":"imap","host":"imap.gmail.com","port":993,"username_ref":"gmail-username","password_ref":"gmail-app-password","inbox":"INBOX"}}'
  fi; unset IDS N
fi; unset OK
sops decrypt --extract '["mcp_hub_accounts"]["accounts"]' --output-type json "$F" | jq -c '[.[].id]'
# expect: ["icloud","outlook","gmail"]
```

Then commit the SOPS change through a pull request:

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch -c chore/sops-mcp-hub-gmail && git add infra/inventory/group_vars/all.sops.yml && git commit -m "chore(sops): mcp-hub gmail account (#172)" && git push -u origin chore/sops-mcp-hub-gmail && gh pr create -R doemefu/homelab --fill
```

**(c2) Merge the SOPS PR, then check presence (value-free).** Merge the PR in GitHub, then:

```bash
cd /Users/dominic/informatik/homelab/infrastructure && git switch main && git pull --ff-only && F=infra/inventory/group_vars/all.sops.yml && for k in gmail-username gmail-app-password; do sops decrypt --extract '["mcp_hub_credentials"]' --output-type json "$F" | jq -r 'keys[]' | grep -x "$k" || echo "$k MISSING - stop"; done
```

**(d) Playbook 59** — check mode, then twice (LAN; off-LAN use the flags of step (d) in "mcp-hub token store and the Outlook account"):

```bash
cd /Users/dominic/informatik/homelab/infrastructure && ansible-playbook infra/playbooks/59_app_services.yml --check --diff
# expect: the asserts pass; the Secret task shows a hidden (no_log) change
ansible-playbook infra/playbooks/59_app_services.yml
ansible-playbook infra/playbooks/59_app_services.yml
# expect run 1: the Secret task changed; run 2: no mcp-hub task changed
```

**(e) Secret keys** (read-only):

```bash
kubectl -n apps get secret mcp-hub-secrets -o json --request-timeout=10s | jq -r '.data | keys[]'
# expect additionally: gmail-app-password, gmail-username (the existing keys stay)
```

**(e2) Registry check BEFORE the restart** (D66; the Deployment uses `Recreate`, a fatal registry error in the new pod would stop `icloud` and `outlook` too). Run it **directly after (d)**; the expected hash comes from the Secret's own `accounts.json`, only the hash is printed:

```bash
S=$(kubectl -n apps get secret mcp-hub-secrets -o jsonpath='{.data.accounts\.json}' --request-timeout=10s | base64 -d | shasum -a 256 | cut -c1-12); echo "expected registry sha: $S"
if [ -z "$S" ] || [ "$S" = e3b0c44298fc ]; then echo 'Secret not read - check the kubectl context (kubectl config current-context)'; else kubectl -n apps exec deploy/mcp-hub -c mcp-hub --request-timeout=30s -- mcp-hub check-registry --expect-sha "$S"; echo "exit $?"; fi
# expect: "registry sha=… projected=…" with the same 12 hex as above, "registry ok", "account icloud mail imap ok",
#         "account icloud calendar caldav ok", "account outlook mail graph ok", "account outlook key ok",
#         "account outlook token current", "account gmail mail imap ok", exit 0.
# Note: check-registry validates configuration only, it does not log in. It also passes with credentials from the wrong Google account;
#       V3 is the real login test.
# "not the expected one yet": the kubelet has not refreshed the volume (up to about 2 min) - wait a minute and repeat.
# Any "registry error …" or "missing …": do NOT delete the pod; fix SOPS ((c)), merge, rerun (d), repeat (e2).
```

**(f) Restart the hub** (the registry changed, the hub reads it only at start-up; `icloud` and `outlook` are unavailable for the few seconds of the restart): `kubectl -n apps delete pod -l app=mcp-hub`.

**(g) Verify** (in claude.ai; V1 is (e2)):

- **V2** `list_accounts` shows `gmail` with `mail` only. Its status is `unknown` until the first background check about 30 s after the pod start, then `ok`.
- **V3** Ask "What's unread in Gmail since yesterday?" (`list_unread account=gmail`), then open one listed mail (`get_message`, mandatory). The hub log shows `tool_call` lines with `account` `gmail` and outcome `ok`, no ERROR line, only the spec 080 §9.7 fields:

  ```bash
  kubectl -n apps logs deploy/mcp-hub --since=10m --request-timeout=10s | grep gmail
  ```

- **V4** `get_events` without `account` skips `gmail` with no `account_errors` entry; `get_events account=gmail` returns `capability_unavailable`.
- **V5** After `get_message`, the mail is still unread in the Gmail web interface (`BODY.PEEK`, no `\Seen`).
- Passing V2–V5 confirms the host `imap.gmail.com:993`; nothing more to record in the spec.

Notes: Gmail's INBOX over IMAP includes every category tab (Promotions, Social, Updates), so `list_unread` returns promotional mail too (bounded by the output budget); the filtering belongs to the morning-brief prompt (#174). A later `X-GM-RAW category:primary` filter would need a spec change.

**Troubleshooting:**

| Symptom | Meaning | Action |
|---|---|---|
| `gmail` shows `error` right after onboarding, hub log `status_check_failed` / `provider_call_failed` with `LoginError` | Google refused the login: the normal account password was used (`[ALERT] Application-specific password required`), or Google wants a browser sign-in (`[ALERT] … web browser`, suspicious-login protection). The hub maps these to `upstream_error` (status `error`, not `auth_expired`; follow-up `doemefu/homelab-mcp-hub#29`) | Sign in at gmail.com in a browser, check the Google account's Security alerts, create a new app password (a), repeat (c) for the password key, (d), (e2); no restart is needed |
| `gmail` shows `auth_expired` | The app password was revoked, or the Google account password changed | New app password into `gmail-app-password` in SOPS, merge, playbook 59 (d); the key name stays the same, so no restart; the status returns to `ok` at the next check (≤ 30 min) |
| `auth_expired` right after onboarding | The app password was created under a different Google account than the one in `gmail-username` | Create the app password while signed in to the account whose address is `gmail-username`, update SOPS, merge, playbook 59 (d); no restart needed |
| `upstream_timeout` on the first calls (`list_unread`, `get_message`) | Gmail is slow on the first IMAP access to a large, long-unused mailbox (observed 2026-10-07: several seconds for single commands, normal after about 30 minutes) | Retry after some minutes; it settles. Nothing to change |
| `gmail` shows `disabled` | A credential key is missing from the Secret, or the registry entry has `"enabled": false` | Missing key: check (e), redo (c)–(d); no pod restart needed, the credential files are read on every call. `"enabled": false`: fix the registry entry in SOPS, run playbook 59 and restart the hub, since the registry is read only at start-up |
| `check-registry` "registry error …" | The registry entry is malformed | Fix SOPS; do not delete the pod |

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

**L4 — Revoke the consents and authorizations of `claude-mcp-hub`** (`registered_client_id` holds the internal id, not the client id). auth-service stores consent in the database, so the consent rows are deleted first, then the authorizations, in one transaction (the block's own `BEGIN;` … `COMMIT;`; with `ON_ERROR_STOP=1` a failing statement aborts before `COMMIT`, so both or neither). The next refresh fails and claude.ai asks for a new login; access tokens already issued expire within 10 minutes. **Check that it worked:** the next login shows the consent page again. L4 takes effect when the access token already issued expires — at most 10 minutes (measured at the stage-a drill on 2026-10-01); for an immediate cut use L2 or L1 first.

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

Order: (1) cut the hub off with L2 step 1; (2) remove both SOPS variables of the client and run playbook 59; (3) remove the two keys from `homelab-auth-secrets` by hand, one JSON patch per key — playbook 59 only skips them once the variables are gone and never deletes a key; (4) run the client-removal SQL, only after a check that the Secret was read and neither key is left in it (`KEYS_GONE=yes`); (5) check that the row is gone; (6) only then merge the auth-service revert or configuration change (in `homelab-auth-service`, not in this repository). The keys are removed **before** the SQL on purpose: auth-service seeds the client only at start-up and only while the secret is set, so a restart of auth-service between the two steps cannot create the client again. `mcp-hub-secrets` and the hub deployment are independent of this procedure; they can stay or be removed separately (L3).

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
# Gate for step 4: KEYS_GONE=yes only if the Secret was read and neither key is in it (a failed read or patch leaves it at no).
KEYS_GONE=no
kubectl -n apps get secret homelab-auth-secrets --request-timeout=10s -o json | jq -e '.kind == "Secret" and ((.data // {}) | (has("claude-mcp-hub-client-secret") or has("claude-mcp-hub-allowed-users")) | not)' >/dev/null && KEYS_GONE=yes
echo "KEYS_GONE=$KEYS_GONE"   # no: STOP, fix step 3 first; step 4 below does not run

# 4. Client-removal SQL (consents, authorizations, registered-client row; one transaction). Runs only with KEYS_GONE=yes.
[ "$KEYS_GONE" = yes ] && kubectl -n apps exec -i postgresql-0 -c postgresql -- psql -U postgres -d homelabdb -v ON_ERROR_STOP=1 <<'SQL'
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
# Gate for step 4, as on the LAN: KEYS_GONE=yes only if the Secret was read and neither key is in it.
KEYS_GONE=no
ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
  'sudo k3s kubectl -n apps get secret homelab-auth-secrets -o json' | jq -e '.kind == "Secret" and ((.data // {}) | (has("claude-mcp-hub-client-secret") or has("claude-mcp-hub-allowed-users")) | not)' >/dev/null && KEYS_GONE=yes
echo "KEYS_GONE=$KEYS_GONE"   # no: STOP, fix step 3 first; step 4 below does not run
# 4. Client-removal SQL (same block, read from stdin). Runs only with KEYS_GONE=yes.
[ "$KEYS_GONE" = yes ] && ssh -i ~/.ssh/homelab -o IdentitiesOnly=yes -o ProxyCommand="cloudflared access ssh --hostname %h" ansible@ssh.furchert.ch \
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

Stage-a drill results (2026-10-01):

| Lever | Result |
|-------|--------|
| L2 step 1 (kill switch) | 76 s from the patch to the first refused call (target ≤ 120 s); restore through playbook 59 without a new login |
| L1 (edge block rule) | the call was refused while the rule existed and worked again after it was deleted |
| L4 | the next call asked for a new login, and the consent page appeared again |

---

### club-mcp (Pattern B, read-only MCP connector for the club assistant)

`club-mcp` is the server behind the claude.ai custom connector `https://club-mcp.furchert.ch/mcp` (club-assistant repo, package `mcp/club-mcp/`, decision D67). It answers two read-only tools (`memory_search`, `corpus_search`) by calling the n8n gateway workflow `m6_mcp_gateway` in-cluster. It follows Pattern B like n8n and LiteLLM: raw manifests in `cluster/apps/club-mcp/`, applied by `infra/playbooks/55_club_mcp.yml`, **not** Flux (the image is built from the private club-assistant monorepo; a Flux deploy key would hold write access to that repo's `main`). A merge alone does not deploy it: run the playbook.

| Item | Value |
|------|-------|
| Image | `ghcr.io/doemefu/club-assistant-mcp:main-<YYYYMMDDTHHMMSS>@sha256:<index digest>` — private package, built by the club-assistant repo's `club-mcp-build.yml` on push to `main`. The manifest ships an unresolved placeholder; playbook 55 refuses to run until it is bumped. |
| Ports | `mcp` 8083 (routed through the tunnel), `metrics` 8084 (`/healthz`, `/readyz`, `/metrics`; never routed) |
| Secrets | `club-mcp-secrets` (files `allowed-subjects`, `gateway-key`, mounted read-only at `/etc/club-mcp/secrets`), `ghcr-pull` (docker-registry), two keys in `homelab-auth-secrets` — all written by playbook 59 |
| Resources | 50m/128Mi requests, 500m/256Mi limits, uid 10001, read-only root filesystem, no capabilities |
| Route | `cf_ingress_body` in `40_platform.yml`: `club-mcp.furchert.ch` → `http://club-mcp.apps.svc.cluster.local:8083`; plus a rule that answers 404 for any `webhook*` path variant of `n8n.furchert.ch/…/club-mcp-gateway` (regex in `40_platform.yml`, case-insensitive, tolerates extra slashes; placed before the n8n entry; the server calls that webhook in-cluster) |
| Monitoring | ServiceMonitor `club-mcp` in `monitoring` (port `metrics`); no alert rules yet |
| NetworkPolicy | Ingress only: 8083 from the cloudflared pods, 8084 from Prometheus |

#### Onboarding (owner steps; the order matters)

1. **SOPS** (`sops infra/inventory/group_vars/all.sops.yml`, owner only): add `club_mcp_allowed_subjects` (list of auth-service usernames; `[]` = nobody), `club_mcp_gateway_key` (`openssl rand -hex 32`), `auth_service_claude_club_mcp_client_secret` (`{bcrypt}` cost-10 hash of a fresh 32-byte hex secret; keep the plaintext in the password manager, it is entered only in claude.ai), `auth_service_claude_club_mcp_allowed_users`, and `ghcr_pull_token` (fine-grained or classic PAT with `read:packages` only). The four `club_mcp_*`/`auth_service_claude_club_mcp_*` variables are all-or-none; the playbook fails on a partial set.
2. **n8n credential** `club-mcp-webhook` (header auth, header `X-Club-MCP-Key`, value = the same string as `club_mcp_gateway_key`), created in the n8n UI.
3. **Image**: after the first club-assistant CI build, bump `cluster/apps/club-mcp/deployment.yaml` by PR (`image` and `CLUB_MCP_VERSION` — always both, `CLUB_MCP_VERSION` = the image tag; playbook 55 refuses to run if they differ — from the build's merge job: tag + multi-arch index digest, `linux/amd64` + `linux/arm64`). Verify the digest with `docker buildx imagetools inspect <image>` before merging.
4. **Cloudflare dashboard**: a proxied CNAME `club-mcp` → the same `<tunnel-id>.cfargotunnel.com` target as `auth` (never in the Zero Trust UI). The WAF rule `mcp-hub: only Anthropic egress` is edited **after the first successful production connection from claude.ai** to the host set `(http.host in {"mcp.furchert.ch" "club-mcp.furchert.ch"} and not ip.src in {160.79.104.0/21})`; this uses no extra custom-rule slot. Note that the reserved `mcp-hub: incident block` rule matches only the hub host; broaden its expression to the host set too, or use the L1 fallback below. The token/login rate limit is path-based and already covers the new client.
5. **Verify the NetworkPolicy selector** before the first run of 55 (home network or tunnel context): `kubectl -n platform get pods --show-labels` must show `pod=cloudflared` on the cloudflared pod (verified 2026-10-27; re-check after a cloudflared chart bump). If the label differs, fix `cluster/apps/club-mcp/networkpolicy.yaml` first, otherwise the public route is cut off from the pod.
6. **Playbook order**: `59_app_services.yml` → delete the auth-service pod (`kubectl -n apps delete pod -l app=auth-service`; it reads the client keys at start-up and seeds the `claude-club-mcp` client from the auth-service release that contains it) → `40_platform.yml` (route; briefly restarts cloudflared and drops an off-LAN SSH forward, run it on the home network, see "Off-LAN kubectl") → `55_club_mcp.yml`. Confirm: `kubectl -n apps rollout status deploy/club-mcp`, then `curl -si https://club-mcp.furchert.ch/mcp` answers 401 and `https://n8n.furchert.ch/webhook/club-mcp-gateway`, `…/webhook/club-mcp-gateway/`, `…/Webhook/Club-MCP-Gateway` and `…/webhook-test/club-mcp-gateway` all answer 404.
7. Enabling the tools is a separate `config` change in the club-assistant database (`mcp_limits.enabled`, `mcp_limits.allowed_subjects`), made on the owner's explicit go.

#### Image bump

PR against `cluster/apps/club-mcp/deployment.yaml` (`image` + `CLUB_MCP_VERSION`, bumped together; 55 asserts they match), merge, then `ansible-playbook infra/playbooks/55_club_mcp.yml`. Rule from the club-assistant side: the red-team protocol RT-M passes before merging any PR that changes the connector's tool texts or snapshots. Dependabot does not watch this image (private package, other repository); the Dockerfile base-image digests are tracked by Dependabot in the club-assistant repo.

#### Rotating `club_mcp_gateway_key`

The key is shared between the server and the n8n credential, so rotate all three in this order, accepting a short window of `upstream_failed` answers: (1) set the new value in SOPS, (2) update the n8n credential `club-mcp-webhook` to the same value, (3) `ansible-playbook infra/playbooks/59_app_services.yml`, (4) `kubectl -n apps rollout restart deploy/club-mcp` (the server also re-reads the key file within about 60 s). Whoever holds the key can assert any allowed subject towards the gateway, so rotate it on any suspicion of exposure.

#### club-mcp incident runbook — cutting access

Every lever except L0 and L1 changes the cluster or the database and needs the owner's go. Removing the connector in claude.ai is not a lever; its refresh token stays valid until L4/L5 of the mcp-hub runbook above (same auth-service client mechanism, client id `claude-club-mcp`).

| # | Lever | Effect | Speed |
|---|-------|--------|-------|
| L0 | `UPDATE config SET value = jsonb_set(value, '{enabled}', 'false') WHERE key = 'mcp_limits'` in the club-assistant database (owner-run) | the gateway refuses every call; read per call | immediate, **try this first** |
| L1 | Cloudflare block rule on `club-mcp.furchert.ch` | nothing reaches the server | seconds; works without cluster access |
| L2 | Empty allowlist, two steps | every token gets 401 | at most 2 minutes |
| L3 | Stop the server | server down | seconds |

**L2.** Step 1 (immediate), then step 2 (persistent — the next playbook-59 run reverts step 1 otherwise):

```bash
kubectl -n apps patch secret club-mcp-secrets --type merge -p '{"stringData":{"allowed-subjects":""}}'
kubectl -n apps delete pod -l app=club-mcp
# Step 2: set  club_mcp_allowed_subjects: []  in SOPS (owner), then run 59.
```

**L3.** Pattern B, no Flux: `kubectl -n apps scale deploy/club-mcp --replicas=0` (a later run of 55 restores the replica count from the manifest).

Decommission: `scale --replicas=0`, delete the club-mcp route from `cf_ingress_body` and re-run 40, remove the CNAME, delete the `claude-club-mcp` client authorizations, then remove the manifests. **Remove the `claude-club-mcp` client before any auth-service rollback** to a release that does not know it, exactly as for the hub.

### Growing the PostgreSQL volume (data-postgresql-0, homelab#359)

Owner decision 2026-11-09 (homelab-data-service#57): the shared PostgreSQL volume `data-postgresql-0` (namespace `apps`) grows from 5 GiB to 10 GiB before the web analytics go-live (Epic #348). All steps here change the live cluster and are the owner's (or the main session's with an explicit go).

**Facts.** PostgreSQL is a raw StatefulSet `postgresql` applied by `infra/playbooks/50_apps_infra.yml` (not a Helm release). Its `volumeClaimTemplates` are immutable, and a StatefulSet never resizes existing PVCs, so the size is changed in two parts: the PVC is patched (Longhorn expands the attached volume online, no pod restart expected), then the StatefulSet object is re-created from its live state with the new template size and the pod is adopted. The pod template is not touched, so the pod is not restarted. Longhorn cannot shrink a volume: the expansion is one-way. Replication is 2.

**Window.** Between 09:00 and 00:30 Europe/Zurich: after the mba morning reboots (06:10 and 07:40) and the replica rebuilds that follow, and clear of the 02:00 snapshot and 03:00 backup. A full run of playbook 50 from `main` fails at the StatefulSet task (Forbidden, immutable field) between the merge of the size change and step S below: do not run it in that gap.

**Shell.** Paste each block into a `bash` subshell (type `bash` first): the blocks use shell functions. macOS bash 3.2 has no bracketed paste, so a failing line does not stop the lines pasted after it: **no block uses `exit` in the local shell**, and step S puts all of its guards and the delete into one compound command. Brackets appear only as the `[ ... ]` test command or inside quotes, and there are no unquoted globs, so the blocks are safe in zsh too. Off the LAN, use the `tunnel` kubectl context or the one-shot SSH forward from "Off-LAN kubectl / Ansible Access" for `kc`, and the off-LAN SSH config (`-F ~/.ssh/homelab-offlan.conf`) for the node commands.

#### P. Prechecks (read-only)

```bash
kc() { kubectl --request-timeout=20s "$@"; }
WORK=$(mktemp -d)
echo "scratch directory: $WORK"

# P1: the StorageClass allows expansion (must print true)
kc get sc longhorn -o jsonpath='{.allowVolumeExpansion}{"\n"}'

# P2: the Longhorn volume is attached and healthy, size 5368709120
VOL=$(kc -n apps get pvc data-postgresql-0 -o jsonpath='{.spec.volumeName}')
echo "volume: $VOL"
kc -n longhorn-system get volumes.longhorn.io "$VOL" -o jsonpath='{.status.state} {.status.robustness} {.spec.size}{"\n"}'

# P3: replica nodes and their headroom (the expansion adds 5 GiB per replica)
kc -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,VOLUME:.spec.volumeName | grep "$VOL"
kc -n longhorn-system get nodes.longhorn.io -o json | python3 -c 'import sys,json
for n in json.load(sys.stdin)["items"]:
    for name, d in n["status"].get("diskStatus", {}).items():
        gib = 2**30
        print(n["metadata"]["name"], name, "max %.1f avail %.1f scheduled %.1f reserved %.1f GiB" % (d["storageMaximum"]/gib, d["storageAvailable"]/gib, d["storageScheduled"]/gib, d.get("storageReserved", 0)/gib))'
```

Stop rule P3: both replica nodes must keep `scheduled + 5` within the schedulable maximum (maximum minus reserved, times the over-provisioning percentage, default 100) and `available − 5` above the minimal-available percentage (default 25) of the maximum. Reading on 2026-11-09 11:20: mba1 max 456.5 / avail 347.5 / scheduled 47.0 / reserved 137.0 GiB, mba2 max 109.6 / avail 44.7 / scheduled 5.0 / reserved 32.9 GiB; both pass (mba2: 39.7 > 27.4 and 10 ≤ 76.7). Re-read the numbers right before the expansion, and stop if a replica sits on an SD-card node close to its DiskPressure threshold.

```bash
# P4: usage for the record (filesystem, database sizes)
kc -n apps exec postgresql-0 -c postgresql -- df -h /var/lib/postgresql/data
kc -n apps exec postgresql-0 -c postgresql -- psql -U postgres -t -A -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;"

# P5: the StatefulSet and the pod belong together; record the pod uid
kc -n apps get sts postgresql -o jsonpath='{.status.currentRevision} {.status.updateRevision} collision={.status.collisionCount}{"\n"}'
kc -n apps get pod postgresql-0 -L controller-revision-hash
kc -n apps get pod postgresql-0 -o jsonpath='uid={.metadata.uid} restarts={.status.containerStatuses[?(@.name=="postgresql")].restartCount}{"\n"}'
kc -n apps get sts postgresql -o jsonpath='template annotations: {.spec.template.metadata.annotations}{"\n"}'
```

P5 reading: `collisionCount` empty or 0, the template annotations empty, and the pod's `controller-revision-hash` equal to the StatefulSet's `updateRevision`. `currentRevision` differing from `updateRevision` is harmless as long as the pod carries the `updateRevision`. Eyeball `kc -n apps get sts postgresql -o yaml` against the StatefulSet task in `50_apps_infra.yml` (image digests, resources). Write down the pod uid.

```bash
# P6: drift check BEFORE the size change is merged (from a checkout of the PR branch or main with the tag).
# Expect: the StatefulSet task is ok, changed=0
ansible-playbook infra/playbooks/50_apps_infra.yml --tags postgresql-statefulset -e postgresql_storage_size=5Gi --check --diff
```

After the size change is merged, the same command without `-e` is expected to fail with Forbidden (immutable field): that is the reason for step S.

**P7: engine start versus the newest `iscsid` on its node (read-only, homelab#362).** Each Longhorn engine caches the host process id of `iscsid` when its frontend starts (go-iscsi-helper, `NewNamespaceExecutor("iscsid", "/host/proc")`). If `iscsid` restarts afterwards on that node (for example through unattended upgrades and needrestart), the engine is **stale**: it fails every frontend refresh with `nsenter: cannot open /host/proc/<pid>/ns/mnt`, and an expansion hangs at the very end (see "If the expansion gets stuck"). A k3s restart alone does not change the `iscsid` pid, and the age of the instance-manager pod is not a usable signal. Upstream: longhorn/longhorn#10544, fixed in Longhorn 1.13.0 and backported to 1.11.3 and 1.12.1 (nothing for 1.7.x). Check right before the expansion:

```bash
ENG_NODE=$(kc -n longhorn-system get engines.longhorn.io -l longhornvolume="$VOL" -o jsonpath='{.items[0].spec.nodeID}')
NODE_IP=$(kc get node "$ENG_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "engine node: $ENG_NODE ($NODE_IP)"
nodesh() { ssh "ansible@$NODE_IP" "bash -s -- $1"; }
# off the LAN instead: nodesh() { ssh -F ~/.ssh/homelab-offlan.conf "ansible@$NODE_IP" "bash -s -- $1"; }
nodesh "$VOL" <<'REMOTE'
vol=$1
now=$(date +%s); newest=0
for p in $(pgrep -x iscsid); do
  s=$(( now - $(ps -o etimes= -p "$p") ))
  [ "$s" -gt "$newest" ] && newest=$s
done
if [ "$newest" -gt 0 ]; then
  echo "newest iscsid started $(date -d @"$newest" -Is)"
else
  echo "iscsid is not running: every engine on this node counts as STALE"
fi
ps -eo pid=,etimes=,args= | while read -r pid et args; do
  case " $args " in *" controller $vol "*) ;; *) continue ;; esac
  st=$(( now - et ))
  if [ "$newest" -eq 0 ] || [ "$st" -lt "$newest" ]; then v=STALE; else v=ok; fi
  echo "$vol engine pid $pid started $(date -d @"$st" -Is) $v"
done
REMOTE
```

P7 reading: `ok` = the engine started after the newest `iscsid`: continue. `STALE` = the engine started before it, or `iscsid` is not running at all (the block then prints every engine as `STALE` and says so): refresh the engine first (sub-step P7m). No engine line at all = the engine process was not found on that node: stop and look (`ps -eo pid,lstart,args | grep '[c]ontroller pvc-'` on the node, check the exact arguments).

**P7m: refresh a stale engine (MUTATION, only if P7 printed STALE; P itself is read-only).** Scale the workload to 0 so that the volume really detaches, then back to 1; the next attach starts a fresh engine. The outage is the same as the offline fallback: about 1 to 3 minutes without a database for every app. A plain `kubectl delete pod` is not enough: the volume may stay attached on the same node with the same engine.

```bash
kc -n apps scale sts postgresql --replicas=0
kc -n longhorn-system get volumes.longhorn.io "$VOL" -o jsonpath='{.status.state}{"\n"}'
# repeat the line above until it prints detached, then
kc -n apps scale sts postgresql --replicas=1
```

Afterwards run P7 again (it must print `ok`) and P2.

#### B. Backup first

1. `scripts/backup-app-data.sh` (see "App-data backups to the operator's Mac (#64)"), started after 03:45 and finished with "Backup complete". restic does not hold PostgreSQL data; the Mac dump is the off-cluster copy (the `mcp_hub` database is excluded from it by design).
2. **Mandatory manual Longhorn snapshot** (it is the only pre-change copy of `mcp_hub`). In the Longhorn UI (`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`, then `http://localhost:8080`): Volume `pvc-…` of `data-postgresql-0` → Take Snapshot, name `pre-expand-359`. Check:

```bash
kc -n longhorn-system get snapshots.longhorn.io -o json | python3 -c 'import sys,json
ok = False
for s in json.load(sys.stdin)["items"]:
    if s["spec"].get("volume") == "'"$VOL"'":
        print(s["metadata"]["name"], s.get("status", {}).get("readyToUse"))
        if s["metadata"]["name"] == "pre-expand-359" and s.get("status", {}).get("readyToUse") is True:
            ok = True
print("pre-expand-359 ready" if ok else "STOP: pre-expand-359 is missing or not ready")
sys.exit(0 if ok else 1)'
```

Stop before the PVC patch unless this prints `pre-expand-359 ready` (an older ready snapshot does not count; it is the only pre-change copy of `mcp_hub`).

The snapshot is deleted a few days after step V (UI → Snapshots → Delete) so that it does not hold blocks for good.

#### E. Expand (online)

```bash
# P2 again right before the patch: robustness must be healthy
kc -n longhorn-system get volumes.longhorn.io "$VOL" -o jsonpath='{.status.state} {.status.robustness}{"\n"}'

# 9: patch the PVC
kc -n apps patch pvc data-postgresql-0 --type merge -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'

# 10: watch until the capacity shows 10Gi (a FileSystemResizePending condition may appear briefly)
kc -n apps get pvc data-postgresql-0 -w

# 11: verify the filesystem, the database and the pod
kc -n apps get pvc data-postgresql-0 -o jsonpath='{.status.capacity.storage}{"\n"}'
kc -n longhorn-system get volumes.longhorn.io "$VOL" -o jsonpath='{.spec.size} {.status.robustness}{"\n"}'
kc -n apps exec postgresql-0 -c postgresql -- df -h /var/lib/postgresql/data
kc -n apps exec postgresql-0 -c postgresql -- psql -U postgres -t -A -c "SELECT pg_size_pretty(pg_database_size('data_service'));"
kc -n apps get pod postgresql-0 -o jsonpath='uid={.metadata.uid} restarts={.status.containerStatuses[?(@.name=="postgresql")].restartCount}{"\n"}'
```

Stop rule E: **do not start step S unless step 10 shows `10Gi` capacity** and the filesystem shows about 9.8G; the pod uid and restart count are unchanged. After the offline fallback (scale to 0 replaces the pod) or a recovery, take the replacement pod's uid and restart count after verifying it as the new baseline; step S compares against the uid recorded at step 12.

**If the expansion gets stuck** (the PVC stays at `5Gi` capacity with a resize condition, or Longhorn reports an expansion error): `kc -n apps describe pvc data-postgresql-0` and the Longhorn UI event log name the cause. A PVC request cannot go back to `5Gi` (Kubernetes only allows lowering a request to a value above the current capacity, `RecoverVolumeExpansionFailure`), so there is no revert; nothing else has changed and the data is unaffected.

- **Disk space or a rebuilding replica:** fix that and wait, Longhorn retries.
- **Stale engine (homelab#362).** Symptom: the PVC stays `Resizing`, the Longhorn event or the engine log shows `Failed to expand the frontend … nsenter: cannot open /host/proc/<pid>/ns/mnt: No such file or directory`, the replicas and the backend already show the new size, and the Longhorn attachment ticket `volume-expansion-controller` may keep the volume attached. A pod that is scaled down or restarted then cannot attach again (`volume attachment is being deleted`). Cause: the engine started before the newest `iscsid` on its node (precheck P7; the trigger is an `iscsid` restart, for example by unattended upgrades; upstream longhorn/longhorn#10544). Recovery is to delete the **instance-manager pod on that node**, which is costly:
  1. List what runs on that node first: `kc -n longhorn-system get engines.longhorn.io,replicas.longhorn.io -o custom-columns=KIND:.kind,NAME:.metadata.name,NODE:.spec.nodeID,VOLUME:.spec.volumeName | grep "$ENG_NODE"` (the instance-manager pod deletion kills **all engines and all replica processes** on the node).
  2. Every affected volume needs a healthy replica on another node, and no other node may be down or rebuilding. Expect replica rebuilds afterwards.
  3. `kc -n longhorn-system get pods -o wide | grep instance-manager` finds the pod on the engine node; delete it with `kc -n longhorn-system delete pod <that pod>`. Workload pods restart through Longhorn's "delete workload pod when volume detaches unexpectedly" (only controller-managed pods); the stuck expansion then completes and the volume attaches.
  4. Restart DB clients that crash-loop: `kc -n apps delete pod -l app=<name>` (auth-service, data-service, device-service, others that lost their connection). Worst case observed on 2026-11-09: about 6 minutes without the database.
- **Longhorn refuses an online expansion altogether:** fallback in a quiet hour: `kc -n apps scale sts postgresql --replicas=0`, wait for the volume to detach, expand, `scale ... --replicas=1` (about 1 to 3 minutes without a database for every app).

If the pod or the replicas were scaled or restarted during E (recovery), the StatefulSet template is unchanged and the live-object re-create of step S stays valid, but the pod has a new uid: take the current uid right before step 12, not the one from P5.

#### Merge, then S: align the StatefulSet with git

Merge the PR (size `10Gi` in the playbook) only after P, B and E. Then do S right away, because a full run of playbook 50 fails at the StatefulSet task until S is done.

```bash
kc() { kubectl --request-timeout=20s "$@"; }
WORK=$(mktemp -d)
set -o pipefail
echo "scratch directory: $WORK"

# 12: save the live object (no secret values in a StatefulSet) and record the CURRENT pod facts (a recovery during E changes the uid)
kc -n apps get sts postgresql -o yaml > "$WORK/sts-before.yaml"
kc -n apps get pod postgresql-0 -L controller-revision-hash
POD_UID=$(kc -n apps get pod postgresql-0 -o jsonpath='{.metadata.uid}')
POD_RESTARTS=$(kc -n apps get pod postgresql-0 -o jsonpath='{.status.containerStatuses[?(@.name=="postgresql")].restartCount}')
POD_HASH=$(kc -n apps get pod postgresql-0 -o jsonpath='{.metadata.labels.controller-revision-hash}')
STS_REV=$(kc -n apps get sts postgresql -o jsonpath='{.status.updateRevision}')
echo "pod uid=$POD_UID restarts=$POD_RESTARTS revision-hash=$POD_HASH, statefulset updateRevision=$STS_REV"

# 13: ONE compound command: the manifest is built and every guard is checked first, and the StatefulSet is deleted only if all of them passed (the delete runs without the 20 s request timeout of kc). It re-creates the StatefulSet from the LIVE object with the new size: the pod template stays byte-identical, so the pod is adopted and not restarted. Keep the window between delete and create short.
if [ -n "$POD_UID" ] && [ -n "$POD_HASH" ] && [ "$POD_HASH" = "$STS_REV" ] \
   && kc -n apps get sts postgresql -o json | python3 -c 'import sys,json
o = json.load(sys.stdin)
if o["spec"].get("replicas") != 1:
    sys.exit("replicas is not 1")
o["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] = "10Gi"
for k in ("uid", "resourceVersion", "creationTimestamp", "generation", "managedFields"):
    o["metadata"].pop(k, None)
o["metadata"].get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
o.pop("status", None)
json.dump(o, sys.stdout)' > "$WORK/sts-new.json" \
   && [ -s "$WORK/sts-new.json" ]; then
  kubectl -n apps delete sts postgresql --cascade=orphan && kc -n apps create -f "$WORK/sts-new.json" && RECREATED=1
else
  echo "STOP: a guard failed (no pod uid or revision hash, pod revision differs from updateRevision, replicas is not 1, or the manifest was not built); nothing was deleted"
fi

# 14: verify adoption automatically: same pod uid and restart count as recorded at step 12 (not as in P5), template 10Gi, StatefulSet ready
kc -n apps get sts postgresql -o jsonpath='{.status.readyReplicas}/{.spec.replicas} {.spec.volumeClaimTemplates[0].spec.resources.requests.storage}{"\n"}'
NOW_UID=$(kc -n apps get pod postgresql-0 -o jsonpath='{.metadata.uid}')
NOW_RESTARTS=$(kc -n apps get pod postgresql-0 -o jsonpath='{.status.containerStatuses[?(@.name=="postgresql")].restartCount}')
if [ -z "$RECREATED" ]; then
  echo "NOT RECREATED (STOP above): nothing was changed or the re-create failed, check the StatefulSet before anything else"
elif [ "$NOW_UID" = "$POD_UID" ] && [ "$NOW_RESTARTS" = "$POD_RESTARTS" ]; then
  echo "ADOPTED: same pod, no restart (uid $NOW_UID, restarts $NOW_RESTARTS)"
else
  echo "CHANGED: uid or restart count differs (was $POD_UID/$POD_RESTARTS, now $NOW_UID/$NOW_RESTARTS): the pod was rolled or the delete did not run, check the StatefulSet and that all apps reconnect"
fi
kc -n apps get pod postgresql-0 -o jsonpath='owner={.metadata.ownerReferences[0].kind}{"\n"}'
kc -n apps get sts postgresql -o jsonpath='{.status.currentRevision} {.status.updateRevision}{"\n"}'
```

Step 15 (from an up-to-date checkout of `main` after the merge, not from the PR branch):

```bash
ansible-playbook infra/playbooks/50_apps_infra.yml --tags postgresql-statefulset --check --diff
# off the LAN (context tunnel, see "Off-LAN kubectl / Ansible Access"):
ANSIBLE_SSH_ARGS="-F $HOME/.ssh/homelab-offlan.conf -o IdentitiesOnly=yes -o ControlMaster=auto -o ControlPersist=60s" \
  ansible-playbook infra/playbooks/50_apps_infra.yml --tags postgresql-statefulset --check --diff -e kubeconfig="$HOME/.kube/config"
```

Step 15 reading: the check may show a diff only in `metadata.managedFields` (the field owner is now `kubectl-create`); that is not drift. **Any diff under `spec` is drift: stop and compare with `$WORK/sts-before.yaml`; do not run the tagged task for real.** No `--save-config` is needed while the task uses a strategic-merge patch; revisit this if the task ever switches to apply or server-side apply.

If the pod was rolled anyway (the uid changed), PostgreSQL restarts from the same volume within a minute or two; check that all apps reconnect.

**If step 13 printed STOP:** nothing was deleted; fix the cause and rerun steps 12 and 13.

**If step 13 fails after the orphan delete:** the pod keeps running (orphaned). If the delete itself timed out, check `kc -n apps get sts postgresql`: while it still exists wait; once it is `NotFound`, run `kc -n apps create -f "$WORK/sts-new.json"` (or the tagged playbook run, `ansible-playbook infra/playbooks/50_apps_infra.yml --tags postgresql-statefulset`). While the StatefulSet is missing nobody restarts a crashed pod, so do not leave this state.

#### V. Verify and record

`kc -n apps get pods`, data-service `/actuator/health`, the PostgreSQL panels in Grafana, no new alerts. Record the sizes, the P3 headroom and the timeline in homelab#359 and homelab-data-service#57, delete the `pre-expand-359` snapshot a few days later, and update the spec wording (docs/100-web-analytics.md §7.3 and R6 still say "5 Gi").

**Residual risks.** (1) If an mba node is lost for a long time, Longhorn rebuilds the second replica, possibly onto an SD-card node (raspi5 or raspi4) with little headroom; node or disk tags for Longhorn are a separate issue. (2) Block-level usage is larger than the filesystem usage because the 7 daily snapshots keep their blocks and trim never touches valid snapshots; the size reduction work is homelab-data-service#57. (3) Follow-up (checkbox on homelab#359): a PVC filesystem alert keyed on `kubelet_volume_stats_*`, not on the Longhorn actual size.

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

The v0.11.0/v0.11.1 regressions noted here earlier (Admin > Models toggle deleting a model,
open-webui#29036; Workspace > Knowledge page hang, #29104) were fixed in v0.11.2 (2026-08-31).

`54_club_assistant.yml` refuses an Open WebUI image change (upgrade, or rollback from an older checkout)
unless run with `-e open_webui_image_change_ack='<exact image string from the manifest>'` — take this
backup first.

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

#### App database CONNECT restriction (#163)

`59_app_services.yml` revokes CONNECT from PUBLIC on `homelabdb`, `litellm`, `data_service` and
`mcp_hub` (task "App databases — revoke CONNECT from PUBLIC (#163)"). The owning role and superusers
can still connect; every other role gets `permission denied`. The task fails if one of these databases
is owned by a superuser: a database recreated without `OWNER <role>` would otherwise lock its app out.
Sessions that were already open stay connected, so restart the clients after the first run.

```bash
# expect t only for each role on its own database
kubectl -n apps exec postgresql-0 -c postgresql -- psql -U postgres -tAc "SELECT r.rolname, d.datname, has_database_privilege(r.rolname, d.datname, 'CONNECT') FROM pg_roles r CROSS JOIN pg_database d WHERE r.rolname IN ('homelab','litellm','data_service','mcp_hub','club_assistant') AND d.datname IN ('homelabdb','litellm','data_service','mcp_hub') ORDER BY 1,2"
# a real cross-database attempt must fail with "permission denied for database"
kubectl -n apps exec postgresql-0 -c postgresql -- psql -U litellm -d homelabdb -c 'select 1'
```

Rollback: revert the change in `59_app_services.yml` first, otherwise the next run revokes again. Then
run `GRANT CONNECT ON DATABASE <db> TO PUBLIC` as `postgres` for each database.

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

`mcp_hub` is left out by design (#171, D65): the token store is re-created by a login, and a dump copy would be a live credential.

```bash
kubectl -n apps exec postgresql-0 -c postgresql -- pg_dumpall -U postgres --exclude-database=mcp_hub > ~/homelab-backups/$(date +%F)/pg-all.sql
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
  A database recreated with `CREATE DATABASE`, or restored from a `pg_dumpall` taken before #163, gets the
  default ACL back, with CONNECT for PUBLIC:
  re-run `ansible-playbook infra/playbooks/59_app_services.yml` afterwards (#163, "App databases").
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
| `postgresql` | `pg-dumpall.sql.gz` plus one `pg-<db>.dump` per database — the list comes from the server at run time (today: `homelabdb`, `n8n`, `litellm`, `club_assistant`; `mcp_hub` excluded by design, #171: restore = playbook 59 + `mcp-hub login`, see "mcp-hub token store and the Outlook account" (m)). `pg-dumpall.sql.gz` is written with `--clean`; PostgreSQL 17 still emits `DROP DATABASE IF EXISTS mcp_hub` for the excluded database, so restoring it onto a running instance deletes the token store — afterwards run (m) (playbook 59, then the login) | application-consistent (`pg_dumpall --clean --if-exists --exclude-database=mcp_hub`, `pg_dump -Fc`) |
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

After a complete, successful run (all six components) the script records the run on raspi5 with
`homelab-backup-mark app-data` over SSH (#301, "Backup freshness and integrity signals (#301)");
`--mark-host USER@HOST` and `--ssh-config FILE` change how it gets there, `--no-mark` skips it. A
failed mark only warns.

`--quiesce` scales `open-webui` and `n8n` to 0 replicas for the duration of their PVC archive and
always scales them back to the previous replica count — on success, on failure and on Ctrl-C.
Both store SQLite databases, so without it those two archives are only crash-consistent.

**Where it lands:** `~/informatik/homelab/backups/<YYYY-MM-DD_HHMMSS>/` (override
with `--dest`). That folder is the parent workspace directory, outside every git repo — the
dumps contain credentials and PII and must never be committed or uploaded. Run directories are
created mode 700 and artifacts mode 600. `--retain N` (default 5) deletes the oldest run
directories after a successful run; it only ever considers directories whose name matches
`YYYY-MM-DD_HHMMSS` **and** that contain `SHA256SUMS`, so anything else in the folder (for
example `backups/restic/`, where `scripts/copy-restic-repo.sh` keeps its copies — see "Off-node
copy to the operator's Mac (#91)") is never touched, and pruning is skipped entirely when the run had a
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
cat "$RUN/MANIFEST.txt"                        # every row must read OK, except pg-mcp_hub.dump EXCLUDED (#171)
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
flux check   # Flux CLI >= 2.10 wants Kubernetes >= 1.35: until then it prints ✗ for the Kubernetes version and exits 1
             # even with healthy controllers; check them with `kubectl -n flux-system get deploy -o wide` + `flux get all -A`
flux get sources git -n flux-system
flux get kustomizations -n flux-system
flux get image repositories -n flux-system
flux get image policy -n flux-system
flux get image update -n flux-system
```

#### Stored API versions (before a Flux minor upgrade)

Flux minor upgrades drop old API versions from the CRDs (2.9 drops `image.toolkit.fluxcd.io/v1beta2` and
`notification.toolkit.fluxcd.io/v1beta2`; [upgrade procedure](https://github.com/fluxcd/flux2/discussions/5572)). The
CRD apply fails if a Flux CRD's `status.storedVersions` lists a version the new CRDs no longer serve, and a Kustomization
fails if one of its manifests uses a dropped version. Run both checks after an API migration of the manifests (#288)
and before every Flux minor upgrade (#292, #296).

1. Git, on the Mac, from the repo root (`flux migrate -f` resolves the path against the working directory), no cluster
   access. Use `-f cluster`, never `-f .`: the tool reads every YAML file under the path, and the repo root holds
   encrypted secret files (`cluster/` holds none). The dry run exits 0 either way, so read its output; the `rg` line is
   the scriptable check (it exits 1 when clean, so negate it in a script: `! rg …`).

   ```bash
   KUBECONFIG=/dev/null flux migrate -v 2.9 -f cluster --dry-run   # -v <target minor>; expect "no custom resources found that require migration"
   rg -n --glob '!*.sops.*' 'toolkit\.fluxcd\.io/v[0-9]+(alpha|beta)[0-9]*' cluster/   # expect no output (an Alert/Provider on v1beta3 is still fine on 2.9)
   ```

2. Cluster, on the Mac with `kubectl`, `jq` and Flux CLI >= 2.9.0 (cluster-mode `flux migrate` reads each CRD's storage
   version from the cluster, so a newer CLI is fine). LAN: default `KUBECONFIG`; off-LAN: the `tunnel` context, see
   "Off-LAN kubectl / Ansible Access". Only when the cluster is healthy and the Kustomization `apps` is Ready at the
   commit that carries the manifest change.

   ```bash
   # Stored versions vs storage version of every Flux CRD
   kubectl get crd -o json | jq -r '.items[] | select(.spec.group | endswith(".fluxcd.io"))
     | [.metadata.name, (.status.storedVersions | join(",")), ([.spec.versions[] | select(.storage) | .name] | join(","))]
     | @tsv' | column -t

   flux migrate   # rewrites every Flux object in its storage version, then trims storedVersions; idempotent, needs cluster-admin

   # Pass/fail: errors on an empty list and names every CRD left to migrate; -e also fails on no input (failed kubectl)
   kubectl get crd -o json | jq -e -r '[.items[] | select(.spec.group | endswith(".fluxcd.io"))] as $crds
     | [$crds[] | select(.status.storedVersions != [.spec.versions[] | select(.storage) | .name]) | .metadata.name] as $bad
     | if ($crds | length) == 0 then error("no Flux CRDs found")
       elif ($bad | length) > 0 then error("storedVersions not migrated: \($bad | join(", "))")
       else "OK: \($crds | length) Flux CRDs store only their storage version" end'

   # The image objects' managedFields name only the v1 API (flux migrate rewrites them too)
   kubectl get imagerepositories,imagepolicies,imageupdateautomations -A --show-managed-fields -o json \
     | jq -e '[.items[].metadata.managedFields[]?.apiVersion] | unique == ["image.toolkit.fluxcd.io/v1"]'
   ```

   Expected on Flux 2.8.5: `OK: 14 Flux CRDs`, with source (6 CRDs) `v1`, `kustomizations` `v1`, `helmreleases` `v2`,
   `alerts` and `providers` `v1beta3`, `receivers` `v1`, `imagepolicies`, `imagerepositories` and
   `imageupdateautomations` `v1`. Each is the only version its CRD serves in Flux 2.9.6. If the managedFields check
   prints `false`: confirm `apps` is Ready at the commit with the v1 manifests, run `flux migrate` again (it rewrites
   managedFields), then repeat the check.

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
# Off-node copies on the Mac (#91): newest MANIFEST.txt — see "Off-node copy to the operator's Mac (#91)"
#   tail -n +2 "$(ls -d ~/informatik/homelab/backups/restic/2*/ | tail -n 1)MANIFEST.txt"

# List snapshots
ssh raspi5 "sudo restic snapshots \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"

# Integrity check (structure only; add --read-data to read back every pack — the nightly run
# already reads one seventh of them, see "Backup freshness and integrity signals (#301)")
ssh raspi5 "sudo restic check \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"
```

#### Manual Backup

```bash
ssh raspi5 "sudo /usr/local/bin/homelab-backup.sh"
```

A manual run exits with "another backup run is active" while the 03:00 cron or a
`scripts/copy-restic-repo.sh` copy holds `/var/lock/homelab-backup.lock` — wait and run it again.

#### Backup log and restic version (#94)

The cron appends each run's output to `/var/log/homelab-backup.log` on raspi5;
`/etc/logrotate.d/homelab-backup` rotates it weekly and keeps 8 rotated weeks, compressed from the second one on.

restic comes from the Ubuntu 24.04 archive: `storage_restic_version` (`0.16.4-2ubuntu0.24.04.*`, an fnmatch
pattern) in `infra/roles/storage/defaults/main.yml`, installed on every node. Every Ubuntu security rebuild of
0.16.4 matches and needs no bump; the release-pocket build `0.16.4-2` does not. The pattern is stricter than the
range the owner approved (`0.16.4-*`, 2026-11-07, an exception to the exact-pin rule). If Ubuntu moves restic to a
new upstream version (0.16.5, 0.17, ...), unattended-upgrades installs it and `10_base.yml` then fails at
"Restic installieren" on every node: the installed version no longer matches and apt refuses the downgrade. A fresh
node fails the same way once no matching build is left in the index. Fix: a deliberate bump:

```bash
ssh raspi5 "apt-cache policy restic"          # Installed / Candidate
# set storage_restic_version to the new pattern (e.g. "0.17.0-1ubuntu0.24.04.*"), then (off-LAN: ANSIBLE_SSH_ARGS prefix, see "Off-LAN kubectl / Ansible Access")
ansible-playbook infra/playbooks/10_base.yml --tags storage --check --diff
ansible-playbook infra/playbooks/10_base.yml --tags storage
ssh raspi5 "sudo logrotate -d /etc/logrotate.d/homelab-backup"   # dry run of the snippet
ssh raspi5 'sudo logrotate -d /etc/logrotate.conf >/dev/null 2>&1; echo rc=$?'   # full config incl. all snippets: rc=0
```

Check the pattern against `apt-cache policy restic` before rebuilding a node (`docs/090-disaster-recovery.md` §3).

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

#### Off-node copy to the operator's Mac (#91)

The repository lives on raspi5's root SD card — the disk it protects. `scripts/copy-restic-repo.sh`
pulls a byte-identical copy into the Mac backup folder, next to the app-data dumps. Interim until
an external SSD or an off-site target exists (#161; owner decision 2026-11-02: Mac folder for now).

- **Read-only on the repository.** rsync runs on raspi5 as the sender only (`sudo`, because the
  repository is root-only), under a **shared** `flock` on `/var/lock/homelab-backup.lock` — the lock
  `homelab-backup.sh` takes exclusively. A copy never overlaps a backup or `forget --prune`, and a
  backup never starts in the middle of a copy. The only node writes are the empty lock file
  (tmpfs, after a reboot) and, after a successful copy, the freshness marker
  (`homelab-backup-mark restic-copy`, #301; `--no-mark` skips it).
- **No password.** The repository is encrypted by restic and copied as is. The copy still holds
  the k3s datastore with every cluster Secret (restic-encrypted): directories mode 700, files 0400,
  outside every git repo, never uploaded.
- **Independent copies.** Every run writes a complete copy (no hard links); 5 copies of today's
  ≈ 270 MB repository need ≈ 1.35 GB.

```bash
./scripts/copy-restic-repo.sh --help
./scripts/copy-restic-repo.sh --dry-run     # every check + totals, copies nothing
./scripts/copy-restic-repo.sh               # on the LAN (ansible@192.168.1.61)
./scripts/copy-restic-repo.sh --ssh-config ~/.ssh/homelab-offlan.conf   # off-LAN (untested)
```

**Layout:** `~/informatik/homelab/backups/restic/<YYYY-MM-DD_HHMMSS>/repo/` (the repository,
`locks/` empty) plus `MANIFEST.txt` (first line `homelab restic repo copy`, totals, newest snapshot
file, verification results). `.in-progress/` is a copy that has not finished verification; the next
run resumes it (rsync only fetches what is missing). Copy directories never contain `SHA256SUMS`,
so `backup-app-data.sh`'s retention never counts or deletes them.

**Verification (every run):** the source file list with sizes is taken under the lock before and
after the copy; both must equal the copy (file count + bytes). Every file under `data/`, `index/`,
`keys/` and `snapshots/` must hash to its own name — restic names them by the SHA-256 of their
content — and `config` must hash like the source. This proves the copy equals the source byte for
byte; it does not prove the source is intact (`restic check --read-data` does, below). A file that
fails its hash is removed from `.in-progress/` and fetched again by the next run; if the same file
fails again, the file on raspi5 is damaged — run the "Integrity check" under "Status" with
`--read-data`.

**It refuses** when the node clock reads 02:00–03:44 (restic cron at 03:00; the remote side is
capped at one hour), when the backup holds the lock (exit 75, try later), when restic holds a lock
younger than 60 min, when the repository has no key or no snapshot file, and when `--dest`
contains a `YYYY-MM-DD_HHMMSS` directory that is not a restic copy (for example the app-data
folder itself).

**Retention:** `--retain N` (default 5) deletes the oldest complete copies, only after a fully
verified run. **Shrink guard:** if the source lost more than 3 snapshot files or half its bytes
since the last good copy, the new copy is kept, nothing is pruned and the script exits 2 — on every
run until you check the repository on the node and re-run with `--accept-shrink`.

**Re-check a copy later** (no password, no network; the hashed file count must be `files` from
`MANIFEST.txt` minus 1 for `config`, because a missing file cannot fail a hash):

```bash
COPY="$(ls -d ~/informatik/homelab/backups/restic/2*/ | tail -n 1)"
tail -n +2 "${COPY}MANIFEST.txt"     # note the "files" line
(cd "${COPY}repo" && find data index keys snapshots -type f -exec shasum -a 256 {} + \
  | awk '{ n = split($2, p, "/"); if (p[n] != $1) { print "BAD " $2; bad++ } }
         END { print NR " files, " bad + 0 " bad"; exit bad > 0 }')
```

**Restore test from the copy (owner).** There is no restic on the Mac and the password stays on
raspi5 (`/etc/restic-password`, written by the storage role from the encrypted variable
`restic_password`): push the copy into a root-only scratch path on raspi5 and run restic there
against it — never into the live repository.

```bash
COPY="$(ls -d ~/informatik/homelab/backups/restic/2*/ | tail -n 1)repo"
# start from empty scratch paths (an aborted earlier test must not be merged in)
ssh ansible@192.168.1.61 "sudo -n rm -rf /var/lib/backup/copy-check /var/lib/backup/restore-test && sudo -n install -d -m 0700 /var/lib/backup/copy-check /var/lib/backup/restore-test"
rsync -rlpt --rsync-path="sudo -n rsync" "$COPY/" ansible@192.168.1.61:/var/lib/backup/copy-check/
# The copy opens with the live password and every pack reads back
# (for a large repository use --read-data-subset=1/10 instead of --read-data)
# --no-cache: the copy has the live repository's ID, so it would share root's restic cache
ssh ansible@192.168.1.61 "sudo -n restic --no-cache --repo /var/lib/backup/copy-check --password-file /etc/restic-password snapshots"
ssh ansible@192.168.1.61 "sudo -n restic --no-cache --repo /var/lib/backup/copy-check --password-file /etc/restic-password check --read-data"
# Restore the newest snapshot from the copy and check the datastore copy (expect ('ok',))
ssh ansible@192.168.1.61 "sudo -n restic --no-cache --repo /var/lib/backup/copy-check --password-file /etc/restic-password restore latest --target /var/lib/backup/restore-test"
ssh ansible@192.168.1.61 "sudo -n python3 -c \"import sqlite3; print(sqlite3.connect('/var/lib/backup/restore-test/var/lib/backup/k3s-state.db').execute('PRAGMA integrity_check').fetchone())\""
# Cleanup — MANDATORY, restore-test holds every cluster Secret in plaintext
ssh ansible@192.168.1.61 "sudo -n rm -rf /var/lib/backup/copy-check /var/lib/backup/restore-test"
```

Record the result in the restore-test log below.

**Restore-test log:**

| Date | Copy | Result |
|------|------|--------|
| 2026-11-03 00:04 | first real copy `2026-11-03_000410` (63 files, 269 636 649 bytes, 25 snapshot files, newest 2026-11-02 03:00) | copy verified (file list + sizes before/after, 62/62 SHA-256 names, `config`); one-off cross-check: `sha256sum` of every file on raspi5 under the lock equals `shasum -a 256` of the copy (63/63). restic restore test from the copy: **pending (owner)** |

#### Full Restore (Disaster Recovery)

The order of a whole rebuild (which playbook, which restore, what is not recoverable) is in
`docs/090-disaster-recovery.md`; the blocks below are its restic steps.

**raspi5's disk is lost** (the repository went with it): restore the newest Mac copy (#91) onto the
new disk **before** the storage role runs. `10_base.yml` runs `restic init` unless
`/var/lib/backup/restic-repo/config` exists, and a freshly initialised repository has a different
key — never copy into one, and never use `--delete` for this push.

```bash
# after 00_bootstrap.yml on the new SD card, ideally before 10_base.yml
COPY="$(ls -d ~/informatik/homelab/backups/restic/2*/ | tail -n 1)repo"
# 1) only if 10_base.yml already ran: move its freshly initialised repository aside. Only a
#    repository WITHOUT snapshots is moved (restic init writes none); anything else stops here.
ssh ansible@192.168.1.61 'if sudo -n test -e /var/lib/backup/restic-repo/config; then
  if [ -z "$(sudo -n find /var/lib/backup/restic-repo/snapshots -type f -print -quit)" ]; then
    sudo -n mv /var/lib/backup/restic-repo "/var/lib/backup/restic-repo.fresh-$(date +%Y%m%d%H%M%S)"
  else
    echo "STOP: /var/lib/backup/restic-repo holds snapshots — not a fresh repository; inspect it (restic snapshots) before going on"; exit 1
  fi
fi'
# 2) empty target directory; the push runs only if it really is empty
ssh ansible@192.168.1.61 "sudo -n install -d -m 0750 /var/lib/backup && sudo -n install -d -m 0700 /var/lib/backup/restic-repo"
if ssh ansible@192.168.1.61 'sudo -n test ! -e /var/lib/backup/restic-repo/config && test -z "$(sudo -n find /var/lib/backup/restic-repo -mindepth 1 -print -quit)"'; then
  rsync -rlpt --rsync-path="sudo -n rsync" "$COPY/" ansible@192.168.1.61:/var/lib/backup/restic-repo/
else
  echo "NOT pushed: /var/lib/backup/restic-repo on raspi5 is not empty (or not reachable)"
fi
```

Then `10_base.yml` (writes `/etc/restic-password`, skips `restic init`) and the steps below. A
moved-aside `restic-repo.fresh-*` directory holds no snapshots; delete it once the restore worked.

**New SD card** (k3s not installed yet — nothing to stop or start; `20_k3s.yml` starts k3s on the
restored datastore afterwards). Pick the newest snapshot taken **before** the failure:

```bash
ssh raspi5 "sudo restic snapshots --repo /var/lib/backup/restic-repo --password-file /etc/restic-password"
ssh raspi5 "sudo restic restore <snapshot-id> \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /"
# restic recreates server/ (for server/token) but not server/db/
ssh raspi5 "sudo install -d -m 0700 /var/lib/rancher/k3s/server/db"
ssh raspi5 "sudo cp /var/lib/backup/k3s-state.db /var/lib/rancher/k3s/server/db/state.db"
ssh raspi5 "sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal /var/lib/rancher/k3s/server/db/state.db-shm /var/lib/backup/k3s-state.db"
# then: ansible-playbook infra/playbooks/20_k3s.yml -l raspi5   (same k3s_token as before)
```

**Same card, k3s installed** (e.g. a damaged datastore; never a new card on which `20_k3s.yml`
already ran):

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

# 20_k3s.yml: --check only, no --diff. Before #156 k3s-agent.service.j2 embedded K3S_TOKEN;
# the token-bearing tasks now run with diff: false, but keep --diff off for this playbook.
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
ansible-playbook infra/playbooks/10_base.yml -l <node> --tags mac_tweaks -e '{"mac_tweaks_reboot_enabled": false}'
ansible-playbook infra/playbooks/20_k3s.yml  -l <node> -e '{"k3s_graceful_shutdown_enabled": false}'
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
kubectl -n platform logs -l pod=cloudflared --prefix --tail=100

# Verify ingress config
# no ConfigMap: the tunnel is remotely managed — routes = cf_ingress_body in infra/playbooks/40_platform.yml

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

# Check for a fail2ban ban (see "fail2ban (#98)"). A banned client cannot run this from its own
# address: go through the tunnel (ssh raspi5) or another node (both are in ignoreip), then
# sudo fail2ban-client set sshd unbanip <ip>
ssh ansible@<node> "sudo fail2ban-client status sshd"

# Check SSH hardening
ssh ansible@<node> "sudo cat /etc/ssh/sshd_config.d/99-hardening.conf"
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
| Check backup status | Daily | Primarily automatic since #92 — `ResticBackupFailed` / `ResticBackupStale` / `LonghornRecurringJob*` alert to Discord. A failed nightly `restic check` (#301) sets `homelab_backup_integrity_check_failed` — **not alerted** until `ResticIntegrityCheckFailed` is live, so keep the `-p err` check below. Manual cross-check: `ssh raspi5 "journalctl -t homelab-backup --since '24 hours ago'"` + `ssh raspi5 "journalctl -t homelab-backup -p err --since '24 hours ago'"` |
| Verify Flux reconciliation | Daily | `flux check` |
| Restart degraded Longhorn volumes | Weekly | Check Longhorn UI for degraded volumes |
| Verify Longhorn recurring snapshot jobs fired | Weekly | `kubectl -n longhorn-system get recurringjobs.longhorn.io daily-snapshot metrics-snapshot-cleanup metrics-filesystem-trim` + `kubectl -n longhorn-system get snapshots.longhorn.io` (see "Recurring Snapshots (#63)" and "Excluded volumes: the metrics group (#101)" above) |
| Verify the metrics-group trim is still working | Weekly | `kubectl -n longhorn-system get volumes.longhorn.io <prometheus-volume> -o jsonpath='{.status.actualSize}'` (flat, not trending towards 40 G) + `kubectl -n longhorn-system logs <latest metrics-filesystem-trim pod>` showing `Finished recurring filesystem trim` — a deleted trim job fires `LonghornRecurringJobMissing` (#239), but a run that skips or no-ops is silent |
| Run the app-data backup script | Monthly and before every image bump | `./scripts/backup-app-data.sh` on the Mac (see "App-data backups to the operator's Mac (#64)" above) |
| Test backup restore | Monthly | App-data restore tests (see "App-data backups to the operator's Mac (#64)") + restic non-destructive restore test (see "Backup (Restic)") |
| Copy the restic repository to the Mac | Monthly, with the app-data dumps, and before SD-card or node work | `./scripts/copy-restic-repo.sh` on the Mac, outside 02:00–03:44 (see "Off-node copy to the operator's Mac (#91)") |
| Check restic repository size | Monthly | `ssh raspi5 "sudo du -sh /var/lib/backup/restic-repo"` |
| Check app-data dump and restic copy freshness | At least every 4 weeks | `ls -lt ~/informatik/homelab/backups/ ~/informatik/homelab/backups/restic/` on the Mac; the runs mark `homelab_backup_offnode_last_success_timestamp_seconds{kind}` on raspi5 (#301) — alerted only once the off-node rule is live (see "Backup alerting (#92)") |
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
| `10_base.yml` | Base packages, hardening, UFW, fail2ban, watchdog, netmon node metrics (`--tags netmon_node`); UFW, fail2ban and sshd alone: `--tags hardening` | 3-5 min | Yes |
| `20_k3s.yml` | k3s installation and configuration | 5-10 min | Yes |
| `30_longhorn.yml` | Longhorn storage system, default StorageClass, and daily recurring snapshot job | 3-5 min | Yes |
| `40_platform.yml` | cert-manager, Cloudflare Tunnel, Traefik (`--tags cloudflared`: no ingress PUT, restart task or Traefik values, #322) | 3-5 min | Yes |
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
