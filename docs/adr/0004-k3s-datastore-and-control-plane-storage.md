# ADR 0004 — k3s Datastore and Control-Plane Storage: Stay on SQLite/kine (Upgraded); Moving raspi5 off the SD Card Is Wanted but Postponed

**Status:** Accepted (2026-11-07)
**Decider:** the owner, 2026-11-07: option A accepted; D1 wanted but postponed (see "Decision"). Draft of 2026-11-03, updated to the post-hop state on 2026-11-07
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
- container images and the root file system,
- the k3s audit log, about 2 MB/h (≈ 48 MB/day, `#340`), which is a steady write load on the same card.

The 03:00 `state.db` online backup adds a long read transaction on this card (see "What went wrong"). The audit log is a steady write load and the backup a latency source; both support D1.

If the card fails, the cluster state and its only backup are gone together. `#91` and `#161` track the backup side of that problem.

### What went wrong (#129)

- **2026-09-23:** kine's online compactor had stopped about 5 days earlier. `state.db` reached 5.02 GB and 1.79 M rows, the apiserver timed out, and Flux and the Longhorn CSI sidecars crash-looped on lease renewals. The fix was an offline compaction with 22 minutes of API downtime.
- **2026-09-30:** the same stall came back (2.9 GB, about 1.24 M revisions behind) and was fixed with another offline compaction. At ≈ 0.25–0.3 M revisions/day the stall began around 2026-09-25/26, not on 2026-09-30. The Mac node resets that evening triggered the symptoms, not the stall.
- **Since then:**
  - The `K3sDatastoreLarge` alert (> 500 MB, `#150`) has existed since 2026-10-28.
  - The apiserver etcd health and ready timeouts are raised to 20 s (PR #151).
  - The offline compaction runbook is in `DEPLOYMENT.md` § "k3s datastore (kine/SQLite) maintenance".

### Measured after the hop (24-h check, 2026-11-06 18:07 CET)

k3s `v1.32.13+k3s1` (kine `v0.14.12`, containerd 2.1.5) has been live on all 4 nodes since 2026-11-05.

| Signal | Value |
|---|---|
| Compaction lag (`max_id − compact_rev`) | 1,008 revisions (≈ the compact-min-retain window) |
| Compactions in 24 h | 287 (≈ 288 expected at the 5-min apiserver interval) |
| `Compact failed` lines | 0 |
| `state.db` size | 59 MB (≈ 110 MB before the hop) |

The size drop is not evidence that compaction shrank the file: SQLite does not shrink a file without `VACUUM`, and kine `v0.14.12` has no startup `VACUUM`. The likely explanation is WAL checkpoint/truncation on the restart; the cause is not established.

### Baseline before the hop (read-only, 2026-11-03 00:00 CET, `v1.32.2+k3s1` / kine `v0.13.9`)

Historical. These measurements are kept as the pre-hop baseline.

| Signal | Value | Source |
|---|---|---|
| k3s / kine | `v1.32.2+k3s1` on all 4 nodes / kine `v0.13.9` (pre-hop) | `kubectl get nodes`; k3s `go.mod` at that tag |
| `state.db` + WAL on disk | 109.7 MB, flat from 2026-10-28 11:41 to now | `homelab_k3s_state_db_bytes` (14-day range query, textfile 56 s fresh) |
| Logical datastore size | 30.4 MB | `apiserver_storage_size_bytes` |
| All apiserver writes | 3.47 /s (≈ 300 k revisions/day), 7-day average 3.40 /s | `apiserver_request_total{verb=~"PUT\|POST\|PATCH\|DELETE"}`, `job="apiserver"` |
| Lease `PUT`s | 2.62 /s (≈ 226 k/day) = **75 % of all writes** | same, `resource="leases"` |

Note on the measurements:
- In k3s the kubelet's `/metrics` endpoint exposes the apiserver series too, so every `apiserver_*` series exists twice in Prometheus (`job="apiserver"` and `job="kubelet"`). Any sum without a `job` filter doubles. The values above use `job="apiserver"`.
- Over the whole 14-day Prometheus window, `homelab_k3s_state_db_bytes` stayed at or below 109.7 MB. v0.13.9 has therefore run at least two weeks without a stall, so a stall-free period alone proves little (see the exit criteria).

Every lease renewal is one new kine row. The 17 renewing leases in the cluster (plus one idle Longhorn upgrade lock) explain the measured rate:

| Lease holders (live) | Renew interval (default) | ≈ PUT/s | Share |
|---|---|---|---|
| 6 Flux controllers (`flux-system`) | `--leader-election-retry-period` 5 s | 1.2 | 46 % |
| 4 Longhorn CSI leases (`driver-longhorn-io`, external-attacher/resizer/snapshotter) | CSI sidecar default 5 s | 0.8 | 30 % |
| 4 node leases (`kube-node-lease`) | 10 s (kubelet) | 0.4 | 15 % |
| cert-manager (2), apiserver identity (1) | 15 s / 10 s | ≈ 0.2 | 8 % |

k3s with a single SQLite server already runs kube-controller-manager and kube-scheduler without leader election (no leases exist for them), so the remaining churn comes from add-ons.

### Finding (pre-hop, fixed by the hop): kine `v0.13.9` had a known compactor bug

- **kine `v0.13.9` contains kine#414** (the version that ran until 2026-11-05). If a compaction iteration fails before any batch succeeds (for example a 5 s batch timeout or `database is locked` under load), the compactor's target revision is reset to 0 and compaction stops **for good** until kine restarts.
  - The bug was introduced in `v0.13.4` and fixed in `v0.13.10` (2025-02-19). The kine maintainer's advice on the matching report kine#489 (reported against v0.13.9): "Please upgrade to at least v0.13.10".
  - The strongest evidence comes from 2026-09-23 itself. After the 15:53 restart, compaction resumed. At 17:20 it wedged again, and it logged no further COMPACT attempt until 21:43 (#129, mitigation 3).
  - Both stalls followed a latency event:
    - the Longhorn rebuild loop on 2026-09-17;
    - for the second stall (≈ 2026-09-25/26), probably the k3s restart for PR #151 on 2026-09-25, a Mac node reset, or the nightly datastore backup.
  - **The nightly backup is a known latency source.** At 03:00 the `storage` role copies `state.db` with sqlite3's online backup API (`backup(pages=-1)`). That is one long read transaction on the same SD card. #129 recorded 735 `Slow SQL` lines in that hour, against a baseline of 30–90.
  - The note in `DEPLOYMENT.md` ("the compactor stalls permanently instead of retrying") describes exactly this behaviour.
  - **Historical interim remedy (no longer applies; v1.32.2 is gone, see "Rollback"):** a plain `sudo systemctl restart k3s` (≈ 1 min API blip; containers keep running) restarts the compactor, provided the backlog is small enough for online compaction. Offline compaction is needed only for a multi-GB backlog.
- **From k3s `v1.32.9+k3s1` on (live: `v1.32.13+k3s1`), compaction works differently.**
  - k3s starts kine with `--compact-interval=0s` (`pkg/etcd/etcd.go` `DefaultEndpointConfig`). kine's own timer is off, and compaction is driven by kube-apiserver through the etcd `Compact` API, every `--etcd-compaction-interval` (default 5 m).
  - kine's handler (`SQLLog.Compact`, kine v0.14.12) re-reads the compact revision **from the database on every call**. A failed run therefore no longer leaves the compactor stuck: the next apiserver call starts again from the stored revision.
  - The interval can be set with `--kube-apiserver-arg=etcd-compaction-interval=<duration>`.

kine and etcd versions per k3s release (read from each tag's `go.mod`):

| k3s | kine | relevant kine fixes included | embedded etcd |
|---|---|---|---|
| v1.32.2+k3s1 (until 2026-11-05) | v0.13.9 | none of the below | v3.5.18 |
| v1.32.13+k3s1 (live since 2026-11-05) | v0.14.12 | kine#414 (stall fix), kine#464/#490 (configurable compaction, apiserver-driven compaction) | v3.5.26 |
| v1.33.13+k3s2 (current 1.33 build; partial index from v1.33.10, startup `VACUUM` from v1.33.11) | v0.16.3 | + kine#613 (partial index: faster SQLite compaction), kine#623 (`VACUUM` at startup) | v3.6.14 |
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

Keep the default datastore. Fix the cause with the k3s patch hop (done 2026-11-05) and add the mitigations M1–M7 below.

- **Pros:**
  - The probable root cause (kine#414) is fixed by a hop that was planned anyway (`#139` hop 1).
  - No migration and no new component.
  - SQLite on a single node is the configuration k3s is tuned for.
  - The offline compaction runbook keeps working as a fallback.
- **Cons:**
  - kine still runs compaction as `DELETE` statements against a single SQLite file, so a large backlog can still be slow.
  - No built-in snapshot tooling. Backups stay the restic copy via sqlite3's online backup API.
  - The SD-card risk stays until the storage move (D) happens.
  - Recovery is forward-only, so A no longer fully meets driver 5 (reversibility): the old `v1.32.2` binaries were removed on 2026-11-06, and `v1.32.2` would reintroduce kine#414. The fallbacks are a `state.db` copy and the offline compaction (see Consequences).

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
| D1 | Whole root file system to an NVMe drive (Pi 5 M.2 HAT) or a USB 3 SSD; boot order via the Pi 5 bootloader. Hardware choice open. | Migration method to be decided when D1 is scheduled. Information: cloning the card with k3s stopped is one maintenance window, with playbooks 10/20 re-run for drift | Moves datastore, Longhorn replicas and images in one step. Best wear and latency result. A fresh re-image instead of a clone loses the cluster CA, token and datastore unless `/var/lib/rancher/k3s/server` and `/etc/rancher/k3s` are restored, so re-imaging carries more risk. Neither method is decided. |
| D2 | Keep booting from SD; mount an SSD at `/var/lib/rancher` and `/var/lib/longhorn` | Smaller change; data copy with k3s stopped | Root file system (logs, journald) stays on SD. Two media to manage. |
| D0 | Stay on SD | none | Accepts the single-medium risk. |

Whichever variant: **the datastore and its backup must end up on different media.** The SSD that `#161` plans as the restic target must not be the same device that holds the live datastore. If D1 uses the only SSD, the restic repository goes off-node (`#91`'s copy to the Mac, or `#161`'s second target).

## Decision (accepted by the owner, 2026-11-07)

1. **Datastore: option A, accepted.** Stay on SQLite/kine and fix the cause by upgrading, together with the mitigations below. Do **not** migrate to embedded etcd now. Embedded etcd only if an exit criterion trips, and only on an SSD.
2. **Storage: D1 is wanted but postponed.** There is no hardware choice yet (NVMe HAT with an NVMe drive, or a USB 3 SSD) and the migration method is to be decided when D1 is scheduled. Do it in its own maintenance window, not together with a k3s hop. D1 does **not** block the minor upgrades in `#65`. Until then D0 stays, and the off-node backup work (`#91`/`#161`) carries the whole recovery risk. The datastore SSD must not be the restic SSD of `#161`.
3. **Embedded etcd (B)** is re-evaluated only when an exit criterion below trips, and only after D1. etcd on the SD card is ruled out.
4. **M4 (Flux leader-election patch)** is folded into `#65` (the Flux upgrade), after the duplicate `cluster/flux-system/flux-system/gotk-components.yaml` is removed as the first PR under `#65`. It is not a separate change.

### Mitigations for option A

| # | Mitigation | Where | Tracking |
|---|---|---|---|
| M1 | **DONE (2026-11-05).** k3s patch hop `v1.32.2+k3s1` → `v1.32.13+k3s1` (kine v0.14.12: kine#414 fixed, apiserver-driven compaction). | `infra/roles/k3s/defaults/main.yml` `k3s_version`, playbook 20 | `#139` hop 1 |
| M2 | Continue the minor hops at least to `v1.34.12` (kine v0.16.5): partial index, startup `VACUUM`, cheaper compaction deletes. Order and target are in `#65`/`#139`. Startup `VACUUM` needs about 2× the database size free on disk and lengthens restarts of a large file; the DSN flag `_kine_disable_startup_vacuum` turns it off if ever needed. | same | `#139`, `#65` |
| M3 | **DONE. Compaction-lag gauge and alert.** The `netmon_node` textfile script on raspi5 (`infra/roles/netmon_node/files/homelab-netmon-collect.py`) exports the lag as one gauge, `homelab_k3s_kine_compaction_lag_revisions` (`MAX(id) − compact_rev_key`, index-only, read-only query; no separate `max_id` gauge). Alerts `K3sKineCompactionLagging` (lag > 50 k revisions for 2 h) and `K3sKineCompactionLagMissing` are in `cluster/values/kube-prometheus-stack.yaml` (applied by playbook 41); promtool test `cluster/values/tests/k3s-datastore.test.yml`. **Runbook:** read the journal first (`journalctl -u k3s`, `Compact failed` / `COMPACT compacted`); the break-glass is the offline compaction. | `netmon_node` role; rules in `cluster/values/kube-prometheus-stack.yaml` + promtool test | see "Follow-ups" |
| M4 | **Folded into `#65`** (the Flux upgrade), after removing the duplicate `cluster/flux-system/flux-system/gotk-components.yaml`; not a separate change. **Cut lease churn by about a third.** Raise the Flux controllers' leader-election timing from 35 s / 30 s / 5 s to e.g. 60 s / 40 s / 15 s via a kustomize patch on the Flux bootstrap manifests. This removes ≈ 0.8 PUT/s, which is −31 % of lease writes and −23 % of all writes. A failover then takes up to about 60 s instead of 35 s, which does not matter for single-replica controllers. Longhorn's CSI sidecars are created by longhorn-manager, and their leader-election flags are not exposed in the chart as far as checked; leave them. Disabling Flux leader election entirely (single replicas) would remove 1.2 PUT/s, but risks two active controllers during a rollout; not recommended. **Recovery:** if the patch breaks kustomize-controller, a git revert cannot heal it, because nothing applies the revert. The recovery is an owner-run `kubectl apply -k cluster/flux-system` from a fixed checkout. | `cluster/flux-system/` kustomization | `#65` (was `#129` (a)) |
| M5 | **Keep the offline compaction runbook** as break-glass, and update its kine references now that M1 is live (the "not tunable via k3s flags" note is true only for kine v0.13.9; on v1.32.13+ the compaction interval is `--kube-apiserver-arg=etcd-compaction-interval`). No scheduled offline compaction: it would cost API downtime for no gain. **Status:** DONE: `DEPLOYMENT.md` § "k3s datastore (kine/SQLite) maintenance" limits the "not tunable" note to kine v0.13.9 and describes the apiserver-driven compaction since v1.32.13. | `DEPLOYMENT.md` | with M1 |
| M6 | **Datastore backup off the node.** The restic repository holding the nightly `state.db` copy must leave raspi5's SD card. **Status:** partly done. `scripts/copy-restic-repo.sh` (`#91`) copies the repository, and a freshness marker with an alert exists (`#301`). The copy is still manual. A restore test and `#161` (SSD and offsite target) are open. | `scripts/`, `storage` role | `#91`, `#161` |
| M7 | **Gentler nightly datastore copy.** Change the `storage` role's `backup(pages=-1)` to stepped pages with short pauses, so the 03:00 copy no longer holds one long read transaction against kine on the same card. Small change; verify with the `Slow SQL` count at 03:00 before and after. | `storage` role | new task |

Not part of this decision:
- Tuning kine's batch size and timeout. k3s does not expose them. kine reads `KINE_COMPACT_TIMEOUT` and `KINE_COMPACT_BATCH_SIZE` from the environment when k3s builds its config through kine's CLI parser, so `/etc/default/k3s` *might* set them. This is inferred from source only and unverified at runtime; revisit only if M1–M3 are not enough.
- `--etcd-compaction-interval` changes. Keep the 5 m default unless the lag gauge shows a reason.

### Exit criteria: when to re-open option B

A quiet month alone proves little: v0.13.9 has already gone two weeks without a stall. The review therefore needs **positive evidence** that the new compaction path recovers. It takes place at the end of the 2-week observation step (order below) and again after 30 days. The evidence is at least one `Compact failed` line in `journalctl -u k3s` (or a lag spike in M3) that is followed by recovery within one or two apiserver compaction calls (5–10 min). If no failure happens in that time, extend the observation; do not declare success.

**Open item (2026-11-07):** the 30-day window started 2026-11-05. The positive check has **not** happened yet: "0 failures" in the 24-h check is not proof, because no failure occurred that could have recovered.

Re-evaluate embedded etcd (on SSD only) if **any** of these happens within 30 days after M1 and M3 are live (window start 2026-11-05; M4 is folded into `#65` and no longer a precondition):
- the compaction-lag alert fires twice, or stays firing for more than 24 h;
- an offline compaction is needed again;
- `apiserver_storage_size_bytes` grows steadily for 7 days with a flat write rate.

If a criterion trips while raspi5 is still on SD, D1 comes first, and B is evaluated only afterwards. Until then the M3 runbook (journal first, offline compaction as break-glass) remains the remedy. If no criterion trips and the positive evidence exists, close `#129`'s datastore follow-ups and keep A.

## Consequences

- **Positive:**
  - The fix rode on the `#139` hop that was due anyway: no extra migration window and no new component.
  - M3 turns a silent stall into an alert within hours.
  - M4 (when done with `#65`) cuts the dominant write source by about a third, which also reduces SD-card writes until D1 happens.
- **Negative / risks:**
  - The diagnosis "kine#414 is the root cause" is strong but not proven on this cluster. M3 is the check. If the lag grows on v1.32.13, the exit criteria apply.
  - **Rollback is forward-only.** The old `v1.32.2` binaries were removed on 2026-11-06, and `v1.32.2` would reintroduce kine#414. If the datastore misbehaves, the break-glass is the offline compaction (`scripts/kine-offline-compact.sh`, `DEPLOYMENT.md` § "k3s datastore (kine/SQLite) maintenance"), or restoring a `state.db` copy.
  - Until D1 (postponed, owner hardware decision pending), one SD card still carries the control plane. The upgrade does not change that.
  - M4 changes Flux's bootstrap manifests. Any later `flux bootstrap` or `flux install` regeneration (Flux 2.9/2.10 in `#65`) must keep the patch. It belongs as a `patches:` entry in `cluster/flux-system/kustomization.yaml`, not inside `gotk-components.yaml`. The Flux sync path (`gotk-sync.yaml` → `./cluster` → `cluster/kustomization.yaml` → `flux-system/`) references only `cluster/flux-system/gotk-components.yaml`. The second copy at `cluster/flux-system/flux-system/gotk-components.yaml` is not referenced by any kustomization. Flux itself committed it (commit 794ebaa), most likely during a bootstrap with a different `--path`. Confirm that before patching, and remove it as the first PR under `#65`; M4 follows inside `#65`.
- **Order relative to `#139` / `#65`** (one change per window):
  1. M3 lag gauge (no restart; playbooks 10 and 41). Done.
  2. M6 off-node copy of the datastore backup (`#91`). Partly done (manual copy script, freshness alert).
  3. M1 hop to v1.32.13 (+ `#158` checksum). Done 2026-11-05; 24-h cleanup done 2026-11-06.
  4. M4 Flux lease patch, folded into `#65` after the duplicate manifest is removed; M7 when convenient.
  5. Observe 2 weeks (from 2026-11-05), then the first exit-criteria review.
  6. D1 storage move (own window, postponed until the owner picks hardware; it does not block step 7).
  7. Minor hops per `#65`.
  8. Exit-criteria review after 30 days.

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

## Follow-ups

- Done: kine compaction-lag gauge + lag alerts + promtool test (M3); `#139` hop 1 (M1); `DEPLOYMENT.md` kine paragraphs updated for v1.32.13 (M5).
- New task: stepped online backup of `state.db` in the `storage` role (M7).
- Optional: the `job="kubelet"` scrape duplicates every `apiserver_*` series. Any rule or panel that sums apiserver metrics needs a `job` filter.
- `#65`: Flux leader-election kustomize patch (M4), after removing the unreferenced `cluster/flux-system/flux-system/gotk-components.yaml`.
- Open exit-criteria item: the positive recovery check (see "Exit criteria"); the 30-day review is due after 2026-12-05.
- Owner: D1 is postponed. Decide on hardware (NVMe HAT + drive, or USB 3 SSD) when scheduling it; the datastore SSD must not be `#161`'s restic SSD. Migration method is decided then.
- `#70`: decide where ADRs live. This ADR is accepted, so add it to the parent `docs/INDEX.md` table either way.

## Results note: k3s patch hop (2026-11-03 to 2026-11-06)

- **Pre-flight (read-only, 2026-11-02 23:51 CET):** cluster healthy; kine 2,621 rows, compaction lag 1,164 revisions (`max_id − compact_rev`), `state.db` 74 MB. The online compactor is keeping up on v0.13.9 right now, which matches the reading that the bug needs a trigger.
- **Hop 1 (M1) was merged 2026-11-03 and rolled out on 2026-11-05** (post-hop readings: "Measured after the hop").
  - PR #304 (merged 2026-11-03 08:37 UTC) pins `v1.32.13+k3s1` with sha256-verified binaries (#158) and the Traefik chart 39 key move. It also updates the kine paragraphs in `DEPLOYMENT.md`: `--compact-interval=0s`, and compaction driven by the apiserver's `--etcd-compaction-interval`. That covers M5.
  - The rollout is an owner step, using the owner runbook from the overnight run (local, not in git).
  - An independent SRE review rated it **GO WITH CHANGES, on the LAN only**. Off-LAN, steps 2–8 are NO-GO as written: the runbook's gates assume LAN addresses, the interactive offline compaction is fragile over an unstable link, and nothing can recover from a lockout.
- **Source facts the SRE review confirmed (kine v0.14.12):**
  - The apiserver-driven path logs `COMPACT compacted` and retries every interval, so it does not stall for good. This is the kine#414 fix this ADR relies on.
  - It adds a key `compact_rev_key_apiserver`, which is only relevant for a rollback, which is no longer possible (recovery is forward-only, see "Consequences").
  - The first apiserver-driven compaction comes about 10 min after an apiserver start.
- **Post-rollout check (exit-criteria input):**
  - `journalctl -u k3s | grep -c 'Compact failed'` = 0.
  - `compact_rev` read twice, 10 min apart (`mode=ro`), must advance.
  - After 24 h, the kine row count must be below 10 k.
  - Outcome of the 24-h check (2026-11-06): 0 `Compact failed` lines, lag 1,008, 287 compactions in 24 h. The kine row count was not taken in that check, so the < 10 k criterion is still to be read. See "Measured after the hop".
