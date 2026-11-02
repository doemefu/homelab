# ADR 0004 — k3s Datastore and Control-Plane Storage: Stay on SQLite/kine (Upgraded), Move raspi5 off the SD Card

**Status:** Proposed (draft for the owner, 2026-11-03). Not accepted until the owner merges it.
**Scope:** `homelab` (infrastructure) only — k3s role, `netmon_node` role, Flux bootstrap manifests, `DEPLOYMENT.md`; hardware on `raspi5`
**Tracking:** `doemefu/homelab#129` (kine compaction stalls; this ADR answers its "evaluate embedded etcd" and "reduce lease churn" follow-ups), `#139` (k3s upgrade), `#65` (platform upgrade epic), `#161` (external SSD), `#91` (restic repo copy off the node)
**Location note:** this is the second ADR in `docs/adr/` of this repository. ADRs 0001 and 0002 still live only in the parent workspace, outside git; where ADRs live long-term is the open question in `#70`.

---

## Context

### The control plane today

`raspi5` (Raspberry Pi 5, 8 GB) is the only k3s server. Its root file system is an SD card. That card holds:

- the k3s datastore: kine on SQLite, `/var/lib/rancher/k3s/server/db/state.db`,
- the Longhorn replicas that are scheduled on raspi5 (`/var/lib/longhorn`),
- the restic repository (`/var/lib/backup/restic-repo`), which includes the nightly copy of `state.db`,
- container images and the root file system.

If the card fails, the cluster state and its only backup are gone together. `#91` and `#161` track the backup side of that problem.

### What went wrong (#129)

- **2026-09-23:** kine's online compactor had stopped about 5 days earlier. `state.db` reached 5.02 GB and 1.79 M rows, the apiserver timed out, and Flux and the Longhorn CSI sidecars crash-looped on lease renewals. The fix was an offline compaction with 22 minutes of API downtime.
- **2026-09-30:** the same stall came back after 7 days (2.9 GB, about 1.24 M revisions behind) and was fixed with another offline compaction.
- **Since then:**
  - The `K3sDatastoreLarge` alert (> 500 MB, `#150`) has existed since 2026-10-28.
  - The apiserver etcd health and ready timeouts are raised to 20 s (PR #151).
  - The offline compaction runbook is in `DEPLOYMENT.md` § "k3s datastore (kine/SQLite) maintenance".

### Measured now (read-only, 2026-11-03 00:00 CET)

| Signal | Value | Source |
|---|---|---|
| k3s / kine | `v1.32.2+k3s1` on all 4 nodes / kine `v0.13.9` | `kubectl get nodes`; k3s `go.mod` at that tag |
| `state.db` + WAL on disk | 109.7 MB, flat from 2026-10-28 11:41 to now | `homelab_k3s_state_db_bytes` (14-day range query, textfile 56 s fresh) |
| Logical datastore size | 30.4 MB | `apiserver_storage_size_bytes` |
| All apiserver writes | 3.47 /s (≈ 300 k revisions/day), 7-day average 3.40 /s | `apiserver_request_total{verb=~"PUT\|POST\|PATCH\|DELETE"}`, `job="apiserver"` |
| Lease `PUT`s | 2.62 /s (≈ 226 k/day) = **75 % of all writes** | same, `resource="leases"` |

Note on the measurements: in k3s the kubelet's `/metrics` endpoint exposes the apiserver series too, so every `apiserver_*` series exists twice in Prometheus (`job="apiserver"` and `job="kubelet"`). Any sum without a `job` filter doubles. The values above use `job="apiserver"`.

Every lease renewal is one new kine row. The 16 leases in the cluster explain the measured rate:

| Lease holders (live) | Renew interval (default) | ≈ PUT/s | Share |
|---|---|---|---|
| 6 Flux controllers (`flux-system`) | `--leader-election-retry-period` 5 s | 1.2 | 46 % |
| 4 Longhorn CSI leases (`driver-longhorn-io`, external-attacher/resizer/snapshotter) | CSI sidecar default 5 s | 0.8 | 30 % |
| 4 node leases (`kube-node-lease`) | 10 s (kubelet) | 0.4 | 15 % |
| cert-manager (2), apiserver identity (1) | 15 s / 10 s | ≈ 0.2 | 8 % |

k3s with a single SQLite server already runs kube-controller-manager and kube-scheduler without leader election (no leases exist for them), so the remaining churn comes from add-ons.

### New finding: the live kine has a known compactor bug

- **kine `v0.13.9` contains kine#414.** If a compaction iteration fails before any batch succeeds (for example a 5 s batch timeout or `database is locked` under load), the compactor's target revision is reset to 0 and compaction stops **for good** until kine restarts.
  - The bug was introduced in `v0.13.4` and fixed in `v0.13.10` (2025-02-19). The kine maintainer's advice on the matching report kine#489 (reported against v0.13.9): "Please upgrade to at least v0.13.10".
  - This matches both incidents: the stall followed an API-latency spike (the Longhorn rebuild loop on 2026-09-17, the Mac node resets on 2026-09-30), and compaction never resumed on its own.
  - The note in `DEPLOYMENT.md` ("the compactor stalls permanently instead of retrying") describes exactly this behaviour.
- **From k3s `v1.32.13+k3s1` on, compaction works differently.**
  - k3s starts kine with `--compact-interval=0s` (`pkg/etcd/etcd.go` `DefaultEndpointConfig`). kine's own timer is off, and compaction is driven by kube-apiserver through the etcd `Compact` API, every `--etcd-compaction-interval` (default 5 m).
  - kine's handler (`SQLLog.Compact`, kine v0.14.12) re-reads the compact revision **from the database on every call**. A failed run therefore no longer leaves the compactor stuck: the next apiserver call starts again from the stored revision.
  - The interval can be set with `--kube-apiserver-arg=etcd-compaction-interval=<duration>`.

kine and etcd versions per k3s release (read from each tag's `go.mod`):

| k3s | kine | relevant kine fixes included | embedded etcd |
|---|---|---|---|
| v1.32.2+k3s1 (live) | v0.13.9 | none of the below | v3.5.18 |
| v1.32.13+k3s1 | v0.14.12 | kine#414 (stall fix), kine#464/#490 (configurable compaction, apiserver-driven compaction) | v3.5.26 |
| v1.33.13+k3s1 | v0.16.1 | + kine#613 (partial index: faster SQLite compaction), kine#623 (`VACUUM` at startup) | v3.6.12 |
| v1.34.12 / v1.35.9 / v1.36.5 | v0.16.5 | + kine#762/#765 (cheaper compaction delete set, bounded batches) | v3.6.14 |
| v1.37.1+k3s1 | v0.17.1 | same as v0.16.5 for compaction | v3.7.1 |

Note on `VACUUM` at startup: from k3s 1.33.13 on, a plain k3s restart reclaims free pages. The offline compaction script stays the break-glass tool for a big backlog. On a multi-GB file, the startup `VACUUM` lengthens the restart, and the 2026-09-23 open already took 64 s.

## Decision drivers

1. **No recurring incident.** The weekly stall must stop without a person in the loop.
2. **Recoverability.** A datastore backup that survives the loss of raspi5's storage, and a restore that is documented and tested.
3. **Storage wear and latency** on raspi5. Today one SD card carries all of the control plane's writes.
4. **Operator effort.** One person runs this cluster. Prefer changes that ride on work that is already planned (`#139` hops), and avoid new components.
5. **Reversibility.** Prefer steps that can be undone within one maintenance window.
6. **No new dependencies** without approval (house rule). Hardware purchases are the owner's call.

## Options

### A. Stay on SQLite/kine, upgraded, with mitigations

Keep the default datastore. Fix the cause with the k3s patch hop and add the mitigations M1–M6 below.

- **Pros:**
  - The probable root cause (kine#414) is fixed by a hop that is planned anyway (`#139` hop 1).
  - No migration, no new component, and every step is reversible: a k3s binary rollback within a minor, or restoring a `state.db` copy.
  - SQLite on a single node is the configuration k3s is tuned for.
  - The offline compaction runbook keeps working as a fallback.
- **Cons:**
  - kine still runs compaction as `DELETE` statements against a single SQLite file, so a large backlog can still be slow.
  - No built-in snapshot tooling. Backups stay the restic copy via sqlite3's online backup API.
  - The SD-card risk stays until the storage move (D) happens.

### B. Embedded etcd, single member (`--cluster-init`)

k3s documents converting an existing single-node SQLite cluster by restarting the server with `--cluster-init` ("Existing single-node clusters", k3s docs `datastore/ha-embedded.md`).

- **Pros:**
  - etcd's MVCC compaction is driven by the apiserver and is a mature code path.
  - Built-in `k3s etcd-snapshot` with a schedule (`--etcd-snapshot-schedule-cron`), retention and an optional S3 target.
  - Opens the path to more servers later (needs three for quorum, which this cluster does not have).
- **Cons:**
  - **etcd on an SD card is explicitly discouraged.** k3s's requirements say: "etcd is write intensive; SD cards and eMMC cannot handle the IO load", and the HA docs warn of performance issues on Raspberry Pis with SD cards.
  - etcd syncs its WAL to disk on every commit. At about 300 k writes a day, that means continuous small synced writes, and slow syncs turn directly into apiserver latency.
  - The conversion is one-way in place. The way back is restoring the pre-migration `state.db` backup, which loses every change made after the migration.
  - A single member has no HA, so it gains no availability over SQLite.
  - etcd adds a defragmentation and quota concern (default backend quota 2 GiB).
  - A migration window is needed on top of the `#139` hops.

### C. External datastore (kine on PostgreSQL or MySQL)

- **Rejected.**
  - The only PostgreSQL is the platform Postgres *inside* this cluster, which is circular: the cluster cannot start without the database it hosts.
  - An external host would be a new always-on machine.
  - kine on Postgres uses the same compaction code as on SQLite, so it fixes nothing the upgrade does not.

### D. Storage axis (independent of A/B): move raspi5 off the SD card

| Variant | What moves | Effort | Notes |
|---|---|---|---|
| D1 | Whole root file system to an NVMe drive (Pi 5 M.2 HAT) or a USB 3 SSD; boot order via the Pi 5 bootloader | Re-image raspi5 or clone the card; one maintenance window; playbooks 10/20 re-run | Moves datastore, Longhorn replicas and images in one step. Best wear and latency result. |
| D2 | Keep booting from SD; mount an SSD at `/var/lib/rancher` and `/var/lib/longhorn` | Smaller change; data copy with k3s stopped | Root file system (logs, journald) stays on SD. Two media to manage. |
| D0 | Stay on SD | none | Accepts the single-medium risk. |

Whichever variant: **the datastore and its backup must end up on different media.** The SSD that `#161` plans as the restic target must not be the same device that holds the live datastore. If D1 uses the only SSD, the restic repository goes off-node (`#91`'s copy to the Mac, or `#161`'s second target).

## Decision (proposed)

1. **Datastore: option A.** Stay on SQLite/kine and fix the cause by upgrading, together with the mitigations below. Do **not** migrate to embedded etcd now.
2. **Storage: option D1**, owner hardware permitting: a Pi 5 NVMe HAT with an NVMe drive, or a USB 3 SSD. Do it in its own maintenance window, not together with a k3s hop. If no hardware is bought, D0 stays, and the off-node backup work (`#91`/`#161`) carries the whole recovery risk.
3. **Embedded etcd (B)** is re-evaluated only when an exit criterion below trips, and only after D1. etcd on the SD card is ruled out.

### Mitigations for option A

| # | Mitigation | Where | Tracking |
|---|---|---|---|
| M1 | k3s patch hop `v1.32.2+k3s1` → `v1.32.13+k3s1` (kine v0.14.12: kine#414 fixed, apiserver-driven compaction). Back up `state.db` first (offline compaction if the backlog is large, since kine opens a large file slowly). | `infra/roles/k3s/defaults/main.yml` `k3s_version`, playbook 20 | `#139` hop 1 |
| M2 | Continue the minor hops at least to `v1.34.12` (kine v0.16.5): partial index, startup `VACUUM`, cheaper compaction deletes. Order and target are in `#65`/`#139`. | same | `#139`, `#65` |
| M3 | **Compaction-lag gauge and alert.** Export `max_id − compact_rev` (the read-only query already in `DEPLOYMENT.md` § "Read-only diagnostics") as `homelab_k3s_compaction_lag_revisions` from the `netmon_node` textfile script on raspi5, and alert when it stays above about 100 k revisions (≈ 8 h of writes at today's rate) for 1 h. This catches a stall within hours, long before `K3sDatastoreLarge` (> 500 MB) fires. The read must use `mode=ro` and a short timeout, so it never blocks kine. | `netmon_node` role, `41_monitoring.yml` rules + promtool test | new task (see "Follow-ups") |
| M4 | **Cut lease churn by about half.** Raise the Flux controllers' leader-election timing from 35 s / 30 s / 5 s to e.g. 60 s / 40 s / 15 s via a kustomize patch on the Flux bootstrap manifests. This removes ≈ 0.8 PUT/s (≈ 23 % of all writes). A failover then takes up to about 60 s instead of 35 s, which does not matter for single-replica controllers. Longhorn's CSI sidecars are created by longhorn-manager, and their leader-election flags are not exposed in the chart as far as checked; leave them. Disabling Flux leader election entirely (single replicas) would remove 1.2 PUT/s, but risks two active controllers during a rollout; not recommended. | `cluster/flux-system/` kustomization | `#129` (a) |
| M5 | **Keep the offline compaction runbook** as break-glass, and update its kine references once M1 is live (the "not tunable via k3s flags" note is true only for kine v0.13.9; on v1.32.13+ the compaction interval is `--kube-apiserver-arg=etcd-compaction-interval`). No scheduled offline compaction: with M1 it would cost API downtime for no gain. | `DEPLOYMENT.md` | with M1 |
| M6 | **Datastore backup off the node.** The restic repository holding the nightly `state.db` copy must leave raspi5's SD card (`#91` interim copy to the Mac, `#161` SSD and offsite target). | `scripts/`, `storage` role | `#91`, `#161` |

Not part of this decision:
- Tuning kine's batch size and timeout. k3s does not expose them. kine reads `KINE_COMPACT_TIMEOUT` and `KINE_COMPACT_BATCH_SIZE` from the environment when k3s builds its config through kine's CLI parser, so `/etc/default/k3s` *might* set them. This is inferred from source only and unverified at runtime; revisit only if M1–M3 are not enough.
- `--etcd-compaction-interval` changes. Keep the 5 m default unless the lag gauge shows a reason.

### Exit criteria: when to re-open option B

Re-evaluate embedded etcd (on SSD only) if **any** of these happens within 30 days after M1, M3 and M4 are live:
- the compaction-lag alert fires twice, or stays firing for more than 24 h;
- an offline compaction is needed again;
- `apiserver_storage_size_bytes` grows steadily for 7 days with a flat write rate.

Otherwise, close `#129`'s datastore follow-ups and keep A.

## Consequences

- **Positive:**
  - The fix rides on the `#139` hop that is due anyway: no extra migration window and no new component.
  - M3 turns a silent stall into an alert within hours.
  - M4 halves the dominant write source, which also reduces SD-card writes until D1 happens.
- **Negative / risks:**
  - The diagnosis "kine#414 is the root cause" is strong but not proven on this cluster. M3 is the check. If the lag still grows on v1.32.13, the exit criteria apply.
  - Until D1, one SD card still carries the control plane. The upgrade does not change that.
  - M4 changes Flux's bootstrap manifests. Any later `flux bootstrap` or `flux install` regeneration (Flux 2.9/2.10 in `#65`) must keep the patch. It belongs as a `patches:` entry in `cluster/flux-system/kustomization.yaml`, not inside `gotk-components.yaml`. The Flux sync path (`gotk-sync.yaml` → `./cluster` → `cluster/kustomization.yaml` → `flux-system/`) references only `cluster/flux-system/gotk-components.yaml`. The second copy at `cluster/flux-system/flux-system/gotk-components.yaml` is not referenced by any kustomization and looks like a leftover. Confirm that before patching, and remove it in its own PR.
- **Order relative to `#139` / `#65`** (one change per window):
  1. M3 lag gauge (no restart; playbooks 10 and 41).
  2. M1 hop to v1.32.13 (+ `#158` checksum).
  3. M4 Flux lease patch (Flux applies on merge).
  4. Observe 2 weeks.
  5. D1 storage move (own window).
  6. Minor hops per `#65`.
  7. Exit-criteria review.

## If option B is ever chosen (for the record)

1. Prerequisites:
   - D1 done (datastore on SSD or NVMe).
   - k3s on the target minor.
   - Offline-compacted and `VACUUM`ed `state.db` plus a `cp -a` backup.
   - restic run, Longhorn snapshot, `scripts/backup-app-data.sh`.
2. Add `--cluster-init` to `k3s-server.service.j2` (role variable, server only), plus `--etcd-snapshot-schedule-cron`, `--etcd-snapshot-retention` and `--etcd-snapshot-dir` on a different medium than the etcd data. The `#157` secrets-at-rest question applies to etcd snapshots exactly as it does to `state.db` copies.
3. Restart k3s; k3s converts SQLite to etcd. Verify: nodes Ready, `kubectl get --raw /readyz?verbose`, Flux reconciles, Longhorn volumes healthy, `k3s etcd-snapshot save` works.
4. Rollback: stop k3s, remove `--cluster-init` and `server/db/etcd`, restore the pre-migration `state.db`, start k3s. This loses every change since the migration.
5. Replace the kine sections in `DEPLOYMENT.md` and the restic datastore copy with etcd snapshot handling.

## Follow-ups (to file or fold in once accepted)

- New task: kine compaction-lag gauge + alert + promtool test (M3).
- `#129`: Flux leader-election kustomize patch (M4), plus removal of the unreferenced `cluster/flux-system/flux-system/gotk-components.yaml`.
- `#139` hop 1: after the hop, update the kine paragraphs in `DEPLOYMENT.md` (M5).
- Owner: decide on D1 hardware (NVMe HAT + drive, or USB 3 SSD) and how it relates to `#161`'s SSD.
- `#70`: decide where ADRs live. If this ADR is accepted, add it to the parent `docs/INDEX.md` table either way.

## Results note: k3s patch hop (2026-11-03 overnight run)

*Pending.* The overnight run's k3s upgrade work package will report here whether hop 1 (v1.32.13) was prepared or applied, and the first compaction readings after it.
