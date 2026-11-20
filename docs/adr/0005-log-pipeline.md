# ADR 0005 — Log Pipeline: VictoriaLogs (single node) with Fluent Bit, Phased

**Status:** Proposed (draft for the owner, 2026-11-03). Not accepted until the owner merges it. Nothing here is deployed, and no dependency is added by this document.
**Scope:** `homelab` (infrastructure): a new platform component in `monitoring`, Grafana datasource, playbook 41. Phase 2 touches app repos (access logs).
**Tracking:** `doemefu/homelab#120` (Idea, Epic #251 follow-up of network monitoring #114)
**Relates to:** ADR 0002 (one store and one owner for analytical data; Prometheus as transport), ADR 0004 draft (#276, raspi5 storage), `#122` (Mosquitto auth), `#121` (Cloudflare Access), `auth#104` (login throttling)

---

## Context

### Today

- Logs exist only as container stdout files on each node, rotated by the kubelet, and in each node's journald. They are read with `kubectl logs` or `journalctl` over SSH.
- A pod restart loses the history. In practice, `kubectl logs --since=24h` returned only 19.2 MB for the whole cluster, while 24 × the measured hourly rate is about 35 MB: several pods (the five Flux-deployed apps among them) restarted that night. Kubelet rotation (10 Mi per container) is not reached at this volume.
- Nothing searches across pods or nodes, nothing keeps logs past an incident, and nothing can feed a later CrowdSec-style response.
- Network monitoring (ADR 0002, live since 2026-09-24) deliberately chose metrics and the Cloudflare API over logs ("Variante A"). It parked this pipeline as follow-up `#120`.

### Measured volume (read-only, 2026-11-03 ≈ 00:40 CET, `kubectl logs --since=1h --all-containers` over all 80 running pods)

| Namespace | Bytes/h | Lines/h | Top producers |
|---|---|---|---|
| monitoring | 571,703 | 4,127 | coroot-node-agent (three nodes 112–250 KB/h each) |
| flux-system | 468,308 | 1,066 | kustomize-controller 206 KB/h, source-controller 161 KB/h |
| longhorn-system | 226,560 | 961 | csi-snapshotter 100 KB/h, instance-manager 85 KB/h |
| kube-system | 104,065 | 970 | coredns (Traefik writes no access log) |
| apps | 94,103 | 1,142 | litellm 62 KB/h, device-service 12 KB/h, auth-service 9 KB/h; **mosquitto 0** |
| homeassistant | 15,480 | 90 | home-assistant |
| platform | 715 | 4 | cloudflared |
| **Total** | **1.48 MB/h** (≈ 35 MB/day) | **8,360** | |

- **Caveats.** This is one night hour, so daytime use of LiteLLM, n8n and Open WebUI adds to it. Node journald (sshd, UFW blocks, k3s including kine `Slow SQL` lines) is **not** measured; the owner or a devops run can measure it on each node with `journalctl --since '-1h' -o cat | wc -c`.
- **Daytime is higher.** The per-pod 24 h figures, scaled for pods that restarted, give a floor of about 38 MB/day; LiteLLM logs about 2× and Grafana about 9× more by day than in the measured night hour.
- **Planning figure:** 50–150 MB/day raw once journald and app access logs are added.

### Cluster constraints

- **Nodes:** raspi5 (8 GB, 66 % memory used), **raspi4 (4 GB, 50 % used)**, mba1 / mba2 (8 GB, 55 % / 28 %).
- **Architectures:** arm64 and amd64, so every image must be multi-arch.
- **Storage:** Longhorn (replica 2) sits on SD cards on the Pis and on SSDs on the Macs.
- **Mac nodes:** they hard-reset every 5 days (T2 timer), so a collector must buffer.
- **Grafana:** 11.5.1, from kube-prometheus-stack.
- **Alerting:** stays in Prometheus/Alertmanager → Discord (ADR 0002 §5).

## Decision drivers

1. Small footprint, especially per node: a DaemonSet costs memory on raspi4 four times over.
2. Few moving parts: one store process, one collector, filesystem storage, no object storage.
3. Multi-arch images, pinned versions, a Helm chart that fits the Ansible-applied platform pattern (playbook 41).
4. Covers pod logs **and** node journald, the latter later.
5. Short retention by design. Logs are operational data, not a system of record: per ADR 0002, anything analytical extracted from logs goes to data-service.
6. Grafana as the single UI.

## Options

### Store

| | **VictoriaLogs single node** (chart `victoria-logs-single` 0.13.11, app v1.53.0) | **Loki** single-binary mode (chart `grafana/loki` 7.5.0, app v3.7.9) |
|---|---|---|
| Moving parts | One binary and one PVC; retention by flag | One binary in `SingleBinary` mode with filesystem storage. The chart's default modes expect object storage, and its caches and compactor need tuning for small installs |
| Memory (planning estimate, verify in the pilot) | ≈ 100–250 MiB at this volume | ≈ 300–600 MiB |
| Query model | LogsQL, full-text search on all fields, no label-cardinality design needed | LogQL; label cardinality must be designed, and full-text search is a scan |
| Grafana | Datasource plugin `victoriametrics-logs-datasource` (needs Grafana ≥ 10.4; an extra plugin, new dependency, to pin) | Built-in datasource |
| Alerting on logs | Needs `vmalert` (an extra component); not planned (see below) | Built-in ruler |
| Ingestion | Loki push, Elasticsearch bulk, JSON lines, OpenTelemetry, syslog, journald (`systemd-journal-upload`) | Loki push, OpenTelemetry |
| CrowdSec (phase 3) | CrowdSec has a `victorialogs` acquisition module (crowdsec repo, `pkg/acquisition/modules/victorialogs`) | CrowdSec has a `loki` acquisition module |

### Collector (one DaemonSet, 4 pods)

| | Footprint (planning estimate) | Pod logs | journald | Notes |
|---|---|---|---|---|
| **Fluent Bit** (app v5.1.5; chart `fluent-bit` 0.58.3 ships 5.1.3, so the image tag is overridden) | ≈ 15–40 MiB | yes (tail + Kubernetes filter) | yes (`systemd` input with `/var/log/journal` mounted) | One agent for both sources; outputs to Loki, VictoriaLogs (HTTP JSON lines or Loki protocol) and Elasticsearch |
| vlagent (chart `victoria-logs-collector` 0.3.8, app v1.53.0) | small (vendor claim, not measured) | yes, with Kubernetes metadata | no; journald would go through `systemd-journal-upload` on each node (Ubuntu package, Ansible) | Same vendor as VictoriaLogs; on-disk buffer |
| Grafana Alloy (v1.21.3) | ≈ 100–200 MiB | yes | yes | The practical collector for Loki: Promtail was **removed** in Loki 3.7.3 |
| Vector (v0.61.0) | ≈ 50–100 MiB | yes | yes | Strong transforms, which are not needed here |

## Decision (proposed)

1. **Store: VictoriaLogs single node.** It has the smallest footprint and the fewest knobs, needs no label design, and its ingestion paths include Loki push and journald, so the collector choice stays open.
2. **Collector: Fluent Bit DaemonSet.** It covers pod logs in phase 1 and journald in phase 3 with the same agent. Its expected per-node cost is low (estimate; vlagent was not measured either). Its filesystem buffer covers the Mac resets and store restarts.
   - The buffer and position files write to the Pi SD cards, so keep the buffer small.
   - Its Kubernetes filter uses `Use_Kubelet On`, so metadata comes from the local kubelet instead of the kine-backed API server.
   - Output: the `http` output with `json_lines` to VictoriaLogs' `/insert/jsonline`.
   - Fallback: vlagent, if the Fluent Bit Kubernetes metadata or the VictoriaLogs output turns out awkward in the pilot.
3. **Retention 14 days for everything**, the same as Prometheus.
   - VictoriaLogs single node has one global retention, so a split such as 30 days in general with ≤ 14 days for IP-bearing logs would need a second instance or a delete job; it is not proposed.
   - Add a disk cap (`-retention.maxDiskSpaceUsageBytes`) below the PVC size.
   - Logs that carry client IPs are personal data. They stay in this store only and are never copied to the Mac app-data dumps.
4. **Storage:** a 5 Gi Longhorn PVC. Expected use at 150 MB/day raw, compressed at least 5× (planning assumption) over 14 days, is about 420 MB per replica.
   - **The PVC carries the Longhorn `metrics` group labels**, like the Prometheus PVC (`recurring-job.longhorn.io/source: enabled`, `recurring-job-group.longhorn.io/metrics: enabled`; `41_monitoring.yml`). It therefore gets the nightly filesystem trim instead of the `default` group's daily snapshots (7 kept). Without the labels it would repeat the snapshot bloat of #101/#106, and keep IP-bearing logs in snapshots for about 21 days, breaking the 14-day promise.
   - Prefer replicas on the Mac SSDs (Longhorn node tag and a dedicated StorageClass), and schedule the pod on the Macs as well. This keeps continuous small writes off the SD cards (see ADR 0004 draft); logs tolerate the 5-day Mac resets. Owner decision D4.
   - **Access:** the VictoriaLogs HTTP API (:9428) has no authentication. A NetworkPolicy admits only Fluent Bit (ingest), Grafana (query) and Prometheus (scrape). Every Grafana user can query the logs; today that is the owner only.
5. **No log-based alerting in phase 1.** Alerts stay metric-based in Prometheus (ADR 0002 §5). Health of the pipeline itself means collector and store up, ingestion rate > 0, and disk usage. It is scraped with ServiceMonitors and alerted in the existing rules, with promtool tests. `vmalert` is reconsidered only if a concrete log-only alert appears.
6. **Relation to ADR 0002.** VictoriaLogs is operational transport with 14-day retention, never the system of record for per-IP or analytical data. Apps never read from it. If an analysis needs log-derived data, data-service pulls it into its own store (ADR 0002 "producers emit, data-service keeps"). CrowdSec (phase 3) keeps its own per-IP decision store; that needs its own ADR or an explicit carve-out from ADR 0002 before phase 3.
7. **Not Loki**, for this cluster, because of the heavier collector (Alloy, now that Promtail is removed), the more complex small-scale configuration, and the larger memory budget. Loki stays the alternative if Grafana-native integration becomes more important than footprint.

## Phases (each its own child issue and PR, after acceptance and dependency approval)

| Phase | Content | Unlocks |
|---|---|---|
| 1 | VictoriaLogs + Fluent Bit (pod logs only) in `monitoring`; pinned charts and images; resource limits; Grafana datasource plugin; ServiceMonitors + health alerts; DEPLOYMENT.md runbook (query examples, retention, disk, rollback = uninstall, which loses only logs) | Cross-pod search, history past restarts, faster incident forensics (Flux, Longhorn, LiteLLM) |
| 2 | App and broker logging: Mosquitto `log_dest stdout` + `connection_messages true` (it logs nothing today); access logs carrying `CF-Connecting-IP` in furchert-ch and auth-service, one issue per app repo, with a privacy note. Rules: log the **path only**, with no query string (OAuth `code`/`state` live there), no request bodies, tokens or usernames; trust `CF-Connecting-IP` only when the request comes from cloudflared | Who connects to the LAN-only anonymous broker (`#122`); per-request client IPs behind the tunnel |
| 3 | Node journald (sshd, UFW blocks, k3s) through Fluent Bit's `systemd` input, after measuring the volume per node; then a CrowdSec evaluation (acquisition from VictoriaLogs, bouncer placement still open) | SSH and UFW visibility, k3s/kine log history; active response later |

What it does **not** replace:
- data-service's netmon store (ADR 0002) stays the place for analytical and per-IP history: login events (NM-4), Cloudflare inbound, egress and LAN.
- Login brute-force detection stays with `auth#104` and auth-service metrics (`auth#80`).

## Consequences

- **Positive:**
  - Logs survive restarts for 14 days and can be searched across the cluster.
  - The groundwork for Mosquitto, SSH and CrowdSec visibility exists.
  - It needs one PVC and an estimated 4 × 30 MiB + 250 MiB of memory (to be measured in phase 1).
- **Negative:**
  - It adds three dependencies: the VictoriaLogs chart and image, the Fluent Bit chart and image, and a Grafana plugin. The Grafana plugin is downloaded at Grafana start unless vendored, which is a supply-chain point to pin. Its version must be re-checked when #290 moves Grafana to a new major.
  - It adds one more stateful component to back up (no backup planned: logs are expendable).
  - IP-bearing access logs (phase 2) need a privacy note and the short retention.
- **Risks:**
  - Memory on raspi4. Set strict limits and measure in phase 1 before adding journald.
  - Log volume growth from a chatty component (coroot and Flux already dominate). Set Fluent Bit filters and per-namespace drop rules if needed.

## Owner decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Store: VictoriaLogs or Loki | VictoriaLogs |
| D2 | Collector: Fluent Bit, vlagent, Alloy or Vector | Fluent Bit |
| D3 | Retention: 14 days for all logs, or 30 days with a second instance or delete job for the IP-bearing logs | 14 days |
| D4 | Pin the store's Longhorn replicas to the Mac SSDs | yes |
| D5 | Dependency approval for phase 1 (charts, images, Grafana plugin). Per the house rule this needs your explicit go, or an independent go/no-go quoted in the PR | — |
| D6 | Phase 2 access logs with client IPs: acceptable with 14-day retention? | yes, with the privacy note |

## Open questions

- O1: the journald volume per node (measure before phase 3).
- O2: daytime pod-log volume. The 24 h data already shows a floor of about 38 MB/day; re-measure at a busy hour before sizing the disk cap.
- O3: whether to vendor the Grafana plugin or let Grafana download a pinned version at start.
- O4: CrowdSec bouncer placement (Traefik plugin versus host firewall) — only in phase 3, and the tunnel routes bypass Traefik.
