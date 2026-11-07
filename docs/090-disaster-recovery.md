# 090 — Disaster Recovery: rebuild the cluster from git and backups

**Status:** Draft (2026-11-03). **Never rehearsed.** The estimates below are educated guesses
until the game day of `doemefu/homelab#265` has timed a real rebuild.
**Runbooks this document orders (do not duplicate them here):** `DEPLOYMENT.md` "Deployment Order
(Step-by-Step)", "Backup (Restic)" (incl. "Off-node copy to the operator's Mac (#91)" and "Full
Restore (Disaster Recovery)"), "App-data backups to the operator's Mac (#64)", "Restore paths",
"k3s datastore (kine/SQLite) maintenance" and the per-app onboarding sections (Flux deploy keys,
mcp-hub).

## 1. What the backups are

| Data | Backup | Where it lives | RPO (worst case today) | Off-node? |
|------|--------|----------------|------------------------|-----------|
| k3s cluster state (every Kubernetes object incl. Secrets, and the cluster certificates k3s keeps in its datastore), `/etc/rancher/k3s` | restic, 03:00 daily (`homelab-backup.sh`) | raspi5 root SD card `/var/lib/backup/restic-repo` | 24 h | only via `scripts/copy-restic-repo.sh` → Mac `backups/restic/` (manual) |
| PostgreSQL (all DBs except `mcp_hub`), InfluxDB, n8n, Open WebUI, mosquitto, Grafana | `scripts/backup-app-data.sh` (manual) | Mac `backups/<YYYY-MM-DD_HHMMSS>/` | age of the newest run whose `MANIFEST.txt` row for that component reads `OK` | yes (Mac) |
| Every Longhorn volume except the Prometheus TSDB | `daily-snapshot`, 02:00, retain 7 | inside the volume's replicas, on the node disks | 24 h | **no** |
| Infrastructure code, manifests, encrypted variables (incl. the k3s join token `k3s_token`) | git | GitHub + local clones on the Mac | last push | yes |
| App images | GHCR (first-party), Docker Hub / other registries (third-party) | registries + node image caches | — | yes |
| Encryption key for the repository's encrypted variables (age) | **one copy on the Mac** (see §5) | Mac | — | **no** |

Not backed up at all: the Prometheus TSDB (by design, metrics only), the `mcp_hub` token store (by
design: re-created by `mcp-hub login`, DEPLOYMENT.md "mcp-hub token store and the Outlook account"
(m)), and the Home Assistant configuration volume outside its local Longhorn snapshots (§4).

**Picking dumps:** app-data runs can be partial (a component `FAILED` or missing). For each
component use the newest run whose `MANIFEST.txt` row reads `OK`, after
`(cd <run> && shasum -a 256 -c SHA256SUMS)` passes — a restore may combine several runs.

## 2. Scenarios

| # | Scenario | What is lost | Recovery path | RTO (estimate) | Data loss |
|---|----------|--------------|---------------|----------------|-----------|
| S1 | One worker disk dies (raspi4, mba1 or mba2) | that node's OS and Longhorn replicas | §3.1 | 1–2 h | none (replication 2) |
| S2 | raspi5's SD card dies, workers intact | control plane, datastore, restic repo, raspi5's Longhorn replicas (the join token survives: it comes from the encrypted variable `k3s_token`) | §3.2 | 2–4 h | cluster state back to the last Mac restic copy (or the last 03:00 run if the card is still readable) |
| S3 | Whole cluster lost, Mac intact (e.g. all disks wiped) | everything in the cluster | §3.3 | about 1 day | app data back to the newest `OK` dump per component; Home Assistant config lost |
| S4a | A Longhorn volume is damaged, at least one replica intact | that volume's current data | revert to a Longhorn snapshot of that volume (Longhorn UI → Volume → Snapshots) | < 1 h | back to the snapshot (≤ 24 h) |
| S4b | A Longhorn volume loses both replicas (and with them its snapshots) | that volume | the app's dump restore in `DEPLOYMENT.md` "Restore paths" where one exists (InfluxDB, Open WebUI, n8n); PostgreSQL (and with it LiteLLM, whose data is the `litellm` database), mosquitto, Grafana and Home Assistant have no live-volume runbook (§4) | 1 h per app, longer without a runbook | back to the newest `OK` dump; Home Assistant lost |
| S5 | The Mac is lost | app-data dumps, restic copies, local clones incl. the untracked `infra/inventory/hosts.yml` and `infra/inventory/local.yml`, kubeconfigs, SSH keys, **the age key** | cluster keeps running; new Mac per `CONTRIBUTING.md`; age key from escrow (§5); new SSH keys need console access on each node (password SSH is off) | hours with escrow; without it the running cluster still holds most values, but every encrypted variable must be re-created by hand (days) | dumps and copies until the next run |
| S6 | GitHub or GHCR unavailable | pushes, Flux sync, image pulls on new nodes | running workloads continue (cached images); rebuilds wait, or use the local clones | outage-bound | none |
| S7 | Cloudflare account locked out | public hostnames, SSH via Access, DNS-01 certificates | LAN access keeps working; account recovery with Cloudflare | outage-bound | none |
| S8 | Fire, flood or theft (cluster **and** Mac) | everything except GitHub (and an off-site age-key copy, if one exists) | **not recoverable today** — code only, no data (§4) | — | all data |

## 3. Rebuild order

Prerequisites for every path (owner): the age key (§5), a Mac with the tooling from
`DEPLOYMENT.md` "Pre-Flight Checklist", SSH keys accepted by the nodes, GitHub access, and an
up-to-date clone of this repository with `infra/inventory/hosts.yml`.

**Run S2 and S3 on the LAN.** The off-LAN path (`ssh.furchert.ch`) runs through the in-cluster
cloudflared, so it is gone until `40_platform.yml` has run again. A reinstalled node has a new SSH
host key: `ssh-keygen -R <node IP>` on the Mac, then accept the new key on the LAN once and compare
its fingerprint on the node's console.

`00_bootstrap.yml` needs the initial user of the fresh install:
`ansible-playbook infra/playbooks/00_bootstrap.yml -e ansible_user=<initial-node-user> -l <node> --become`.

`10_base.yml` installs restic matching `storage_restic_version`
(`infra/roles/storage/defaults/main.yml`, #94), currently the pattern `0.16.4-2ubuntu0.24.04.*`, so Ubuntu
security rebuilds of 0.16.4 install without a change. If Ubuntu has moved restic to a new upstream version (0.16.5,
0.17, ...) since, no build matches and the install fails: run `sudo apt-get update && apt-cache policy restic` on the
fresh node and bump the pattern first.

### 3.1 S1 — a worker

1. Reinstall Ubuntu 24.04 on the node (MacBooks: `docs/ubuntu_on_mac.md`).
2. `kubectl delete node <node>` for the dead node object.
3. `00_bootstrap.yml -l <node>`, `10_base.yml -l <node>`, `20_k3s.yml -l <node>`.
4. Longhorn rebuilds the missing replicas on its own (replication 2); watch
   `kubectl -n longhorn-system get volumes.longhorn.io` until every volume is `healthy`. Whether
   Longhorn accepts the reinstalled node's disk without manual cleanup is unverified — check it on
   the game day.

### 3.2 S2 — raspi5 (control plane)

1. New SD card, Ubuntu 24.04, same IP (192.168.1.61). `00_bootstrap.yml -l raspi5`.
2. **Before `10_base.yml`:** push the newest restic copy back — `DEPLOYMENT.md` "Full Restore
   (Disaster Recovery)", first block. `10_base.yml` would otherwise initialise a new, empty
   repository with a different key.
3. `10_base.yml -l raspi5` (writes the restic password file, skips `restic init`).
4. Restore the newest snapshot taken **before** the failure (`restic snapshots`) and put the
   datastore copy in place — `DEPLOYMENT.md` "Full Restore (Disaster Recovery)", the **new SD card**
   block (k3s is not installed yet, so nothing is stopped or started) — then `20_k3s.yml -l raspi5`.
   k3s starts on the restored datastore with the same `k3s_token`, so the cluster certificates and
   the workers' membership come back without reinstalling the workers. A changed `k3s_token` makes
   every older datastore snapshot unusable.
5. Check: `kubectl get nodes`, `kubectl get pods -A`. Re-run only the **playbooks** whose objects
   may have changed since the snapshot — `30_longhorn.yml` (recurring jobs live in the datastore),
   `40_platform.yml`, `41_monitoring.yml`,
   `50_apps_infra.yml`, `59_app_services.yml`, `51_homeassistant.yml` … `55_club_mcp.yml` — **no
   data restores** (the volumes on the workers are newer than any dump). Flux restores its own apps.
6. Longhorn: the restored datastore can describe replicas that the workers have rebuilt since the
   snapshot. Check `kubectl -n longhorn-system get volumes.longhorn.io` and
   `kubectl -n longhorn-system get orphans.longhorn.io`; a volume that stays `faulted` goes the S4b
   way. Unverified until the game day.
7. Take a fresh restic copy to the Mac once the 03:00 run has written a new snapshot.

### 3.3 S3 — the whole cluster

A restored datastore would point at Longhorn volumes that no longer exist, so build a **fresh**
cluster and restore application data from the Mac dumps.

1. Reinstall all four nodes; `00_bootstrap.yml` per node.
2. `10_base.yml`, `20_k3s.yml`, `30_longhorn.yml`.
3. `40_platform.yml`, `41_monitoring.yml`.
4. `50_apps_infra.yml` (PostgreSQL, InfluxDB, mosquitto) — then restore their data **before** any
   app starts writing: PostgreSQL from `pg-dumpall.sql.gz` (all roles and databases; untested on
   a fresh server, see §4), InfluxDB from `influxdb2-backup.tgz` (`DEPLOYMENT.md` "Restore
   paths", "InfluxDB restore"), mosquitto from `mosquitto.db` (copy it into the `mosquitto` data
   volume while the pod is scaled to 0, like the PVC archives).
5. `59_app_services.yml` (app Secrets, databases, roles; recreates the empty `mcp_hub` database).
6. `51_homeassistant.yml`, `52_n8n.yml`, `53_litellm.yml`, `54_club_assistant.yml`,
   `55_club_mcp.yml`; restore the n8n and Open WebUI PVC archives (`DEPLOYMENT.md` "Restore
   paths") and the Grafana archive (same helper-pod pattern as "App-data backups to the operator's
   Mac (#64)", restore test (b), but into the live volume — no runbook yet, §4).
7. Flux — nothing about it survives (its own deploy key and Secret died with the cluster):
   1. `kubectl apply -f cluster/flux-system/gotk-components.yaml`, wait until the `flux-system`
      Deployments are available.
   2. `flux create secret git flux-system -n flux-system --url=ssh://git@github.com/doemefu/homelab --ssh-key-algorithm=ed25519`,
      add its public key as a deploy key on `doemefu/homelab` (read-only is enough: every
      `ImageUpdateAutomation` pushes to an app repository, none to this one), then
      `kubectl apply -k cluster/flux-system/`.
   3. One write-access key per app (`auth-service-flux-auth`, `device-service-flux-auth`,
      `data-service-flux-auth`, `furchert-ch-flux-auth`, `mcp-hub-flux-auth`) — the same commands
      as `DEPLOYMENT.md` "data-service (Flux, NM-0 onboarding)" (b) and "mcp-hub (Flux, #170
      onboarding)" (a).
   4. Delete the old deploy keys on GitHub (their private halves are still in older restic
      copies), and re-add any ruleset bypass entry that pointed at an old key.
8. `40_platform.yml` again (all tunnel routes), then the mcp-hub login (`DEPLOYMENT.md` "mcp-hub
   token store and the Outlook account" (m)).
9. Verify every public hostname and the backup jobs (restic run, Longhorn recurring jobs), then
   take a fresh app-data dump and restic copy.

## 4. Gaps — not recoverable today

| Gap | Effect | Fix (owner decision / follow-up) |
|-----|--------|----------------------------------|
| Nothing is off-site | S8 loses every byte of data | #161 (SSD + off-site target) |
| The age key has one copy (on the Mac) | S5 without escrow = every encrypted variable re-created by hand, all credentials rotated | §5, owner step |
| Home Assistant's config volume is not in `backup-app-data.sh` | S3/S4b lose the Home Assistant setup; only local Longhorn snapshots exist | add a `homeassistant` component to the script (follow-up) |
| App-data dumps are manual and can be partial | RPO for S3/S4b is weeks; a component may have no recent `OK` dump | run at least every 4 weeks (with `--quiesce`); freshness alert of #301 |
| The restic copy on the Mac is manual | RPO for S2 is the age of the last copy | run at least every 4 weeks; freshness alert of #301 |
| Longhorn snapshots are local only | they die with the replicas | none planned (no BackupTarget, owner decision 2026-09-08) |
| No documented Flux bootstrap before this document | S3 step 7 is improvised | verify step 7 on the game day |
| No runbook for a full `pg_dumpall` restore onto a fresh server, for `mosquitto.db`, or for Grafana into a live volume | S3 steps 4 and 6 and S4b are improvised | write them during the game day |
| No rebuild has ever been rehearsed | every RTO above is a guess | game day, #265 |
| RTO targets per service (e.g. mcp-hub mail access vs. IoT) are not decided | no priority order inside S3 | owner decision, #265 |

## 5. Owner step: a second copy of the age key

The key that decrypts the repository's encrypted variables exists only on the Mac. Losing the Mac
(S5) or its disk without a second copy means every encrypted value has to be re-created.

- Make a second copy that does not live on the Mac: for example as a secure note in the password
  manager, printed on paper in a safe place, or on an encrypted USB stick. Only a copy kept
  **away from the flat** (paper or stick elsewhere, or the password manager's cloud vault) also
  survives S8. Never in git, never in a cloud folder that syncs in plain text.
- Check the copy by deriving its public key with `age-keygen -y` and comparing it with the recipient
  in `.sops.yaml` — without printing the private key.
- Note in your own records where the copy lives and when it was last checked (yearly).
- Agents never read, copy or move this key.

## 6. Rehearsal

`doemefu/homelab#265`: one timed rebuild following only this document — ideally S2 on a spare SD
card (the cheapest realistic disaster) — then correct this document and replace the RTO guesses
with measured times.
