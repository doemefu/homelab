# 060 — Network Monitoring: Cross-Repo Contract

> Canonical copy (infrastructure repo). The parent workspace file `docs/060-network-monitoring.md` forwards here (since homelab PR #126). Relative `adr/` links refer to the parent workspace's `docs/adr/` (not in this repo).

**Status:** NM-0 implemented 2026-09-23; NM-1 in implementation
**Epic:** `doemefu/homelab#114` · **ADR:** [`adr/0002-network-telemetry-ownership.md`](adr/0002-network-telemetry-ownership.md)
**Canonical location:** this file (`infrastructure/docs/060-network-monitoring.md`). The parent workspace file `docs/060-network-monitoring.md` is a forwarder (since `homelab#126`), following the `052` precedent.
**Conventions:** "(assumption)" = a design choice made here that the implementer may revisit in its plan. "(unverified)" = a fact not confirmed against a live system or upstream docs, which the implementing sub-project must confirm in its Phase 1.

---

## 1. Purpose, scope, principle, sub-projects

**Purpose.** Answer three questions from one admin page:

1. Who calls the public services, and was the call legitimate?
2. What do cluster workloads talk to?
3. Which LAN hosts touch cluster ports?

**In scope**

- Public inbound through Cloudflare for auth, device, furchert.ch, club, n8n, ai and grafana. That covers client IP, country, ASN, host, path, status and WAF/Bot outcome.
- Cluster egress and east-west traffic: per workload, the destination IP:port, FQDN, bytes, and new destinations.
- LAN access to cluster ports: 1883, 22, 8123, 6443 and 10250 by source IP, plus UFW blocks and SSH auth outcomes on the nodes.
- Legitimacy signals:
  - geo and ASN from Cloudflare;
  - the Spamhaus DROP and FireHOL level1 blocklists;
  - AbuseIPDB on demand;
  - Cloudflare WAF/Bot actions;
  - auth-service login outcomes per source IP.

**Out of scope**

- The home LAN at large: Shellys, laptops and the router WAN.
- A static egress allowlist, which the owner rejected as too rigid.
- A log pipeline with VictoriaLogs/Loki, CrowdSec, Cloudflare Access, local AI classification, and mosquitto hardening. These are follow-up issues.

**Central-data principle** (owner, 2026-09-23, verbatim):

> "der datenhaushalt sollte möglichst einheitlich an einem zentralen ort bleiben (maintainability und nachvollziehbarkeit) und nicht gesplittert an verschiedenen orten in verschiedenen services aufbewahrt werden"

Consequences, which bind every section below:

- **One store with one owner.** That is data-service's Postgres DB `data_service`, schema `netmon`.
- **Producers emit and do not keep.** Prometheus is transport with 14 d retention, and auth-service's buffer holds at most 72 h.
- **data-service pulls, and every collector is idempotent.**
- **furchert-ch reads only data-service.**

**Sub-projects** (order NM-0 → NM-1 → NM-3 → NM-2 → NM-4)

| ID | Goal | Lead repo | Other repos | Depends on |
|---|---|---|---|---|
| NM-0 | Bootstrap data-service with the Spring Boot 4.1 skeleton, Flyway `netmon` baseline, JWT resource server, actuator, CI multi-arch image, `k8s/` and Flux. Add the platform DB/role/Secret. Commit this spec and ADR 0002. | data-service | infrastructure, auth-service (`netmon:read` for the `furchert-ch` client) | — |
| NM-1 | Inbound: Cloudflare collector, IP enrichment, blocklists, AbuseIPDB, read API, and the UI inbound section with Subnav tab and NoAccess | data-service | furchert-ch, infrastructure (CF token Secret) | NM-0, Cloudflare token (owner) |
| NM-3 | LAN: node role that writes textfile metrics, data-service snapshot collector and API, and the UI LAN section | infrastructure | data-service, furchert-ch | NM-0, `homelab` PR #109 (textfile collector) |
| NM-2 | Egress: coroot-node-agent spike, then DaemonSet, ServiceMonitor, rules, data-service collector and API, and the UI egress section | infrastructure | data-service, furchert-ch | NM-0, spike go |
| NM-4 | Logins: auth-service outbox and pull endpoint, data-service puller and API, and the UI logins section | auth-service | data-service, furchert-ch, infrastructure (secrets) | NM-0 |

---

## 2. Topology

```
 SOURCES                         COLLECTION (all in data-service)          STORE              READ               UI
 ───────                         ────────────────────────────────          ─────              ────               ──
 Cloudflare edge ── HTTPS ─────► CloudflareCollector  (5 min)  ─┐
  api.cloudflare.com/client/v4/graphql                          │
 Spamhaus / FireHOL ── HTTPS ──► BlocklistCollector   (daily)  ─┤
 AbuseIPDB ── HTTPS ───────────► ReputationCollector  (30 min) ─┤
                                                                │    ┌────────────────────┐
 coroot-node-agent (DS, ns monitoring, :80/metrics) ─┐          ├──► │ PostgreSQL         │   data-service       furchert-ch
 node scripts ─► textfile ─► node-exporter :9100 ────┼► Prometheus    │ ns apps            │◄─ REST :8082  ◄─── SSR server
                                                     │  (ns monitoring│ svc postgresql:5432│   /api/netmon/*    component
                                                     │   :9090, 14 d) │ DB  data_service   │   (JWT, scope      /[locale]/dashboard/network
                     PrometheusCollector (15 min/1 h)◄┘               │ schema netmon      │    netmon:read)    (ADMIN only)
 auth-service :8080 /api/v1/login-events ◄── LoginEventCollector (1 min)  └────────────────────┘        ▲
   (outbox ≤ 72 h, ns apps)                                                                          │ client_credentials
                                                                     auth-service /oauth2/token ─────┘ (furchert-ch client)
 Alerts: Prometheus rules ─► Alertmanager ─► Discord (existing route)
```

| Endpoint | Namespace | FQDN : port | Used by |
|---|---|---|---|
| data-service | apps | `data-service.apps.svc.cluster.local:8082` | furchert-ch (read API) |
| PostgreSQL | apps | `postgresql.apps.svc.cluster.local:5432` | data-service only (for `data_service`) |
| Prometheus | monitoring | `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` | data-service (instant queries) |
| auth-service | apps | `auth-service.apps.svc.cluster.local:8080` | data-service (JWKS, token, login events), furchert-ch (token) |
| Cloudflare GraphQL | external | `https://api.cloudflare.com/client/v4/graphql` | data-service |
| coroot-node-agent | monitoring | pod `:80/metrics` (v1.35.10 default `0.0.0.0:80`, verified in source) | Prometheus |
| node-exporter | monitoring | host `:9100` | Prometheus |

data-service has **no** public tunnel route. It is not added to `cf_ingress_body`.

---

## 3. Data model (PostgreSQL, owned by data-service)

### 3.1 Naming (decided)

| Item | Value | Rationale |
|---|---|---|
| Database | `data_service` | Follows the existing DB-per-app names `litellm` and `club_assistant`, where DB name = role name = snake_case app name. The brief proposed `dataservice`, and that proposal is superseded here. |
| Role | `data_service` (LOGIN, owner of the DB) | Same pattern as `litellm` and `club_assistant` (`59_app_services.yml`, `54_club_assistant.yml`) |
| Schema | `netmon` | One schema per data domain. Future sensor-history tables would get their own schema. |
| Flyway history | `public.flyway_schema_history_data` | Mirrors `flyway_schema_history_auth` and `flyway_schema_history_device`. History lives in `public` so later schemas do not depend on `netmon`. |
| Flyway files | `src/main/resources/db/migration/V<n>__netmon_<topic>.sql` | See 3.4 |

auth-service and device-service share `homelabdb`/`homelab`. data-service deliberately does **not** join that database.

### 3.2 Common rules for every table

- Every timestamp is `timestamptz` in UTC. Every window is half-open `[window_start, window_end)`.
- Every row has `source text NOT NULL` and `ingested_at timestamptz NOT NULL DEFAULT now()`. The `source` values are `cloudflare-graphql`, `spamhaus`, `firehol`, `abuseipdb`, `prometheus-coroot`, `prometheus-textfile` and `auth-service`.
- IPs are `inet` where they are real addresses. Node-script labels that can be buckets, such as `10.42.0.0/16` or `other`, are `text`.
- Surrogate keys are `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`. Tables with a natural key use it as a `UNIQUE` constraint.
- **Idempotency:** each collector either upserts on the natural key (`INSERT … ON CONFLICT … DO UPDATE`) or replaces a whole window in one transaction (`DELETE … WHERE window_start = ?` then `INSERT`). The column "Write mode" states which.
- Free-text fields from the internet are truncated before insert: `path` to 1024 chars and `user_agent` to 512. **Truncation happens before natural-key aggregation.** Any write that sums or upserts per natural key (for example §4.2's slice-summing) must truncate first and aggregate in memory afterwards, because two distinct raw values that truncate to the same natural key would otherwise violate the table's UNIQUE constraint on the second insert.

### 3.3 Tables

**`netmon.collector_state`** (NM-0). This holds one row per collector and drives catch-up and the status API.

| Column | Type | Null | Notes |
|---|---|---|---|
| collector | text | no | PK. Values: `cloudflare-requests`, `cloudflare-firewall`, `blocklists`, `reputation`, `lan`, `egress`, `login-events`, `retention` |
| last_window_end | timestamptz | yes | High-water mark of fully collected data |
| cursor | text | yes | Opaque, e.g. the last login-event id |
| last_attempt_at / last_success_at | timestamptz | yes | |
| consecutive_failures | int | no | default 0 |
| last_error | text | yes | Exception class and short message. **Never** a URL with a query string, a header or a token. `last_error` carries a message only for collector-authored `CollectorException`s; for any other exception only the class name is stored (no payload, no IPs) (amended 2026-09-23, NM-0: data-service PR #18). |
| last_error_code | text | yes | CHECK constraint restricts values to `credentials`, `rate_limited`, `upstream`, `truncated`, `internal` (the §7.2 status error-code enum) (amended 2026-09-23, NM-0: data-service PR #18) |

**`netmon.inbound_request_groups`** (NM-1). Source: `httpRequestsAdaptiveGroups`. Granularity is 1 h. Write mode: replace per window. Retention: 90 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| window_start, window_end | timestamptz | no | Hour-aligned (`window_end = window_start + 1h`) |
| is_final | boolean | no | `true` once re-collected ≥ 15 min after `window_end` |
| client_ip | inet | no | `clientIP` |
| country | char(2) | yes | `clientCountryName`. It is an ISO alpha-2 code (unverified). |
| host | text | no | `clientRequestHTTPHost` |
| method | text | no | `clientRequestHTTPMethodName` |
| path | text | no | `clientRequestPath`, which excludes the query string |
| status | smallint | no | `edgeResponseStatus` |
| request_count | bigint | no | `count` (sample-adjusted) |
| sample_interval | real | no | `avg.sampleInterval`. A value of 1 means unsampled. |
| sampled | boolean | no | Generated as `sample_interval > 1` |

- UNIQUE `(window_start, client_ip, host, method, path, status)`
- Indexes: `(window_start)`, `(client_ip, window_start)`, `(host, window_start)`
- No `asn`/`asn_org` columns: `httpRequestsAdaptiveGroups` does not offer `clientAsn` or `clientASNDescription` on this zone (§4.2 probe). ASN comes only from `firewallEventsAdaptive` and reaches `ip_enrichment` from there (amended 2026-09-24, NM-1: data-service PR #19).

**`netmon.firewall_events`** (NM-1). Source: `firewallEventsAdaptive`, with raw events. Write mode: upsert, do nothing on conflict. Retention: 180 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| occurred_at | timestamptz | no | `datetime` |
| ray_name | text | no | `rayName` |
| client_ip | inet | no | |
| country, asn, asn_org | char(2), integer, text | yes | `clientCountryName`, `clientAsn`, `clientASNDescription` |
| action | text | no | e.g. `block`, `managed_challenge`, `skip`, `log` |
| security_source | text | no | Cloudflare's `source`, e.g. `firewallManaged`, `botFight`. It is renamed to avoid clashing with the common `source` column. |
| rule_id | text | yes | `ruleId` |
| host, method, path | text | yes | |
| user_agent | text | yes | truncated to 512 chars |

- UNIQUE `(ray_name, security_source, coalesce(rule_id,''), action)`, as an expression index. One request can trigger several events.
- Indexes: `(occurred_at)`, `(client_ip, occurred_at)`

**`netmon.ip_enrichment`** (NM-1). One row per public IP seen by any data set. Write mode: upsert. Retention: delete when `last_seen` is older than 180 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| ip | inet | no | PK. Only public addresses (see 4.3). |
| first_seen, last_seen | timestamptz | no | min/max over all data sets |
| seen_in | text[] | no | Subset of `{inbound, firewall, login, lan, egress}` |
| country, asn, asn_org | char(2), integer, text | yes | Latest Cloudflare value. ASN only from `firewall_events` (amended 2026-09-24, NM-1: data-service PR #19) |
| blocklist_hits | jsonb | no | Default `[]`. Array of `{"list":"spamhaus-drop-v4","cidr":"x.x.x.x/nn","fetchedAt":"…Z"}`, recomputed on every blocklist refresh |
| blocklisted | boolean | no | Default false; true iff `blocklist_hits` is non-empty. Maintained together with it. |
| abuseipdb_score | smallint | yes | `abuseConfidenceScore` from 0 to 100 |
| abuseipdb_reports | integer | yes | `totalReports` |
| abuseipdb_checked_at | timestamptz | yes | null means never checked |

- Indexes: `(last_seen)`, a partial index on `(blocklisted) WHERE blocklisted`, and `(abuseipdb_checked_at)`

**`netmon.blocklist_snapshots`** (NM-1). One row per fetch attempt. Write mode: insert. Retention: 30 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| list_name | text | no | `spamhaus-drop-v4` or `firehol-level1` |
| fetched_at | timestamptz | no | |
| source_url | text | no | |
| outcome | text | no | `applied`, `unchanged` (etag or sha match) or `failed` |
| entry_count | integer | yes | Entries after filtering |
| etag | text | yes | |
| sha256 | char(64) | yes | Of the raw body |
| error | text | yes | |

**`netmon.blocklist_entries`** (NM-1). This holds the current entries only. Write mode: replace per `list_name` in one transaction, and only after a successful parse. It is not subject to retention.

| Column | Type | Null | Notes |
|---|---|---|---|
| list_name | text | no | |
| cidr | cidr | no | |
| snapshot_id | bigint | no | FK to `blocklist_snapshots.id` |

- PK `(list_name, cidr)`
- GiST index on `cidr inet_ops`, used for `ip <<= cidr` matching

**`netmon.lan_connection_snapshots`** (NM-3). Source: `homelab_lan_connections`. Granularity is 15 min. Write mode: replace per `(window_start, node)`. Retention: 30 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| window_start, window_end | timestamptz | no | Aligned to :00, :15, :30 and :45 UTC |
| node | text | no | |
| dport | integer | no | |
| src_ip | text | no | A LAN IP, or `10.42.0.0/16`, or `other` (see §5) |
| state | text | no | conntrack TCP state |
| peak_connections | integer | no | `max_over_time` over the window |

- UNIQUE `(window_start, node, dport, src_ip, state)`
- Index `(src_ip, window_start)`

**`netmon.ufw_block_snapshots`** (NM-3). Source: `homelab_ufw_blocks_bucket`, 15 min. Write mode: replace per `(window_start, node)`. Retention: 90 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| window_start, window_end, node | as above | no | |
| src_ip | text | no | IP, or `other` |
| dport | integer | no | 0 for protocols without ports, e.g. ICMP |
| proto | text | no | `TCP`, `UDP`, `ICMP` or `OTHER` |
| blocks | integer | no | Logged blocks in the bucket. This is a **lower bound** (see §5.4). |

- UNIQUE `(window_start, node, src_ip, dport, proto)`

**`netmon.ssh_auth_snapshots`** (NM-3). Source: `homelab_sshd_auth_bucket`, 15 min. Write mode: replace per `(window_start, node)`. Retention: 90 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| window_start, window_end, node | as above | no | |
| src_ip | text | no | For tunnelled SSH this is the cloudflared pod or node IP, not the client (§10) |
| outcome | text | no | `accepted`, `failed` or `invalid_user` |
| attempts | integer | no | |

- UNIQUE `(window_start, node, src_ip, outcome)`

**`netmon.egress_flow_snapshots`** (NM-2). Source: coroot metrics via Prometheus. Granularity is 1 h. Write mode: replace per `window_start`. Retention: 30 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| window_start, window_end | timestamptz | no | Hour-aligned |
| node | text | no | From the ServiceMonitor relabel (§6) |
| container_id | text | no | Raw coroot label: `/k8s/<ns>/<pod>/<container>`, `/k8s-cronjob/<ns>/<cronjob>/<container>` (coroot collapses CronJob pods scheduled within ±7 d to their CronJob), or a systemd cgroup path such as `/system.slice/k3s.service` for host processes (amended 2026-09-24, NM-2: data-service#22, homelab#118) |
| namespace, pod, container | text | yes | Parsed from the `/k8s…` forms; `pod` is null for CronJob rows. Host processes: `container` = the unit name, `namespace` and `pod` null (amended 2026-09-24, NM-2: data-service#22, homelab#118). |
| workload | text | yes | The pod name with its ReplicaSet/DaemonSet hash suffix removed, regex `(?:-[bcdfghjklmnpqrstvwxz2456789]{6,10})?-[bcdfghjklmnpqrstvwxz2456789]{5}$` (the §6.4 k8s alphabet). StatefulSet pods keep their full name; CronJob rows carry the CronJob name; null for host processes (amended 2026-09-24, NM-2: data-service#22, homelab#118) |
| workload_key | text | no | `<ns>/<workload>/<container>` for pods (the §6.4 `<W>` format), else the raw `container_id`. The `is_new` identity (amended 2026-09-24, NM-2: data-service#22, homelab#118) |
| destination | text | no | Pre-NAT `ip:port`, or `<fqdn>:<port>` for destinations coroot reports by name only (§4.6). `destination_port` is the port after the last `:`, and the name is `destination` with that `:<port>` stripped |
| actual_destination | text | no | Post-NAT `ip:port`; `''` for name-only destinations and for unjoined failed-connect rows (§4.6) |
| destination_ip | inet | yes | From `actual_destination`, else `destination`; NULL for destinations coroot reports by name only (amended 2026-09-24, NM-2: data-service#22, homelab#118) |
| destination_host | text | no | Generated: `coalesce(host(destination_ip), fqdn)`. Keys aggregation and `is_new` |
| destination_port | integer | no | |
| destination_scope | text | no | `pod` (10.42.0.0/16), `service` (10.43.0.0/16), `lan` (192.168.1.0/24), `loopback`, or `external`. The CIDRs come from config. |
| fqdn | text | yes | From `ip_to_fqdn`; for name-only destinations, the name from `destination` |
| bytes_sent, bytes_received, connects, failed_connects | bigint | no | `increase()` over the window, rounded |
| is_new | boolean | no | True if `(workload_key, destination_host, destination_port)` does not occur in the previous 30 d. `workload_key` = `<ns>/<workload>/<container>` (the §6.4 `<W>` format), else the raw `container_id`; a bare `coalesce(workload, container_id)` would merge equal owner names across namespaces (amended 2026-09-24, NM-2: data-service#22, homelab#118) |

- UNIQUE `(window_start, node, container_id, destination, actual_destination)`
- Indexes (as shipped in data-service `V4__netmon_egress.sql`): `(window_start)`, `(workload, window_start)`, `(destination_ip)`, and `(workload_key, destination_host, destination_port, window_start)` for `is_new` and the read API (amended 2026-09-24, NM-2: data-service#22, homelab#118)

**`netmon.login_events`** (NM-4). Source: the auth-service outbox. Write mode: upsert, do nothing on `event_id`. Retention: 180 d.

| Column | Type | Null | Notes |
|---|---|---|---|
| event_id | uuid | no | UNIQUE; generated by auth-service |
| occurred_at | timestamptz | no | |
| outcome | text | no | `success`, `failure` or `locked` |
| client_ip | inet | yes | |
| ip_source | text | no | `cf-connecting-ip` or `remote-addr` |
| username_hmac | char(64) | no | Hex HMAC-SHA256 (§7.6) |
| subject | text | yes | Set **only** for `success` |
| user_agent | text | yes | truncated to 512 chars |
| source_service | text | no | `auth-service` |

- Indexes: `(occurred_at)`, `(client_ip, occurred_at)`, `(username_hmac, occurred_at)`

### 3.4 Flyway files

| File | Sub-project | Content |
|---|---|---|
| `V1__netmon_baseline.sql` | NM-0 | `CREATE SCHEMA IF NOT EXISTS netmon`, plus `collector_state` only |
| `V2__netmon_inbound.sql` | NM-1 | `inbound_request_groups`, `firewall_events`, `ip_enrichment`, `blocklist_snapshots` and `blocklist_entries` |
| `V3__netmon_lan.sql` | NM-3 | `lan_connection_snapshots`, `ufw_block_snapshots`, `ssh_auth_snapshots` |
| `V4__netmon_egress.sql` | NM-2 | `egress_flow_snapshots` |
| `V5__netmon_login_events.sql` | NM-4 | `login_events` |

The NM-1 tables moved out of `V1` (an earlier draft bundled them in): the Cloudflare field probe (§4.2) that fixes their NOT NULL columns runs only in NM-1's own Phase 1, after `V1` is already merged and immutable, and the `CLOUDFLARE_API_TOKEN` this needs may not exist at NM-0 time. **Rule:** the version number is the next free number at PR time; migrations are never merged out of order (`outOfOrder=false`), and a migration is never edited after it is merged to main. Flyway settings are `table=flyway_schema_history_data`, `default-schema=public` and `schemas=public,netmon`. Use `ddl-auto=validate` if JPA is used (§12 Q5).

### 3.5 Retention job contract

- **Schedule:** `@Scheduled(cron = "0 30 3 * * *", zone = "UTC")`, daily. It runs outside the Longhorn 02:00 and restic 03:00 local-time windows.
- **Per-table defaults:** each table has a property `netmon.retention.<table>-days`, with the defaults in 3.3. Values below 1 are rejected at startup.
- **Mechanics:** `DELETE … WHERE <time column> < now() - <days>` in batches of 5 000 rows (`ctid IN (SELECT … LIMIT 5000)`) until 0 rows are deleted. The time columns are `window_start`, `occurred_at`, `fetched_at`, or `last_seen` for `ip_enrichment`. Each table logs `[retention] <table> deleted=<n>` and nothing else.
- **`blocklist_snapshots` exception.** Its deletion additionally excludes any row still referenced by `blocklist_entries.snapshot_id`, since the current entries for a list can point at a snapshot older than 30 d when the list has been `unchanged` for a while: `DELETE FROM netmon.blocklist_snapshots s WHERE s.fetched_at < now() - interval '30 days' AND NOT EXISTS (SELECT 1 FROM netmon.blocklist_entries e WHERE e.snapshot_id = s.id)`. Without this, the plain age-based delete would eventually hit the `blocklist_entries.snapshot_id` FK and fail the job daily.
- **State:** the job updates `collector_state('retention')`. It never truncates, and there is no manual deletion path in the API.

---

## 4. Collectors (data-service)

### 4.1 Scheduling model (decided)

The scheduler is Spring `@Scheduled` on the Boot-managed `ThreadPoolTaskScheduler`, with `spring.task.scheduling.pool.size=4`.

- **Cron and zone:** every cron is in UTC.
- **No overlap:** each collector is guarded by an in-JVM `ReentrantLock.tryLock()`, so a slow run is skipped rather than overlapped.
- **Why:** it needs no new dependency (ShedLock and Quartz would need approval). data-service runs `replicas: 1`, and the brief overlap during a rolling update is harmless because every write is idempotent (3.2).
- **Kill switch:** each collector has `netmon.collectors.<name>.enabled` (default `true`, and `false` for `reputation` when no API key is set). This lets an operator disable one source without redeploying code.

| Collector | Cron (UTC) | Unit of work | Catch-up cap |
|---|---|---|---|
| cloudflare-requests | `0 */5 * * * *` | Current hour so far, plus the previous hour until final | 24 h |
| cloudflare-firewall | `30 */5 * * * *` | `[cursor, now − 2 min)` | 24 h (design cap; Cloudflare keeps 31 d, §4.2) |
| blocklists | `0 0 5 * * *` | Both lists | — |
| reputation | `0 */30 * * * *` | ≤ `netmon.abuseipdb.per-run` IPs | — |
| lan | `0 4,19,34,49 * * * *` | Last completed 15-min window | 48 h |
| egress | `0 7 * * * *` | Last completed hour | 48 h |
| login-events | `15 * * * * *` | Outbox pages after cursor | 72 h (outbox TTL) |
| retention | `0 30 3 * * *` | All tables | — |

**Catch-up rule.** Pull-based collectors process missed windows oldest-first from `collector_state.last_window_end`, up to the cap. Anything older is skipped and logged once as `[<collector>] gap skipped from=… to=…`.

**Failure rule.** A failure leaves `last_window_end` unchanged, increments `consecutive_failures` and stores `last_error`. The next run retries. HTTP 429 and 5xx get exponential backoff between runs, capped at 30 min.

**Alerting.** A silent stall (for example, a Cloudflare token that has expired) shows up only in `/status` (§7.2) today, since there is no Prometheus rule watching collector freshness — unlike the node script and the coroot agent, which do have one (§5.6, §6.4). Until NM-1's infrastructure child is rolled out, that stays true: collector stalls are visible only in the UI. Q9 was approved on 2026-09-23. `micrometer-registry-prometheus` and `/actuator/prometheus` shipped with NM-0 (`homelab-data-service#13`, PR #18). The `ServiceMonitor` and the `NetmonCollectorStale` rule ship with NM-1's infrastructure child (`homelab#116`, PR #131) (amended 2026-09-24, NM-1: homelab#116). `netmon_collector_last_success_timestamp_seconds{collector}` is NaN until the collector's first success; the `NetmonCollectorStale` rule must treat a NaN sample as "never succeeded" (e.g. `time() - g > <threshold> or g != g` — the exact expression is NM-1's job, noted in §5.6/§6.4 style where the rule is specified) (amended 2026-09-23, NM-0: data-service PR #18).

**Freshness rules (NM-1, homelab#116).** These live in `additionalPrometheusRulesMap.homelab-netmon`, NM-1's own key (NM-3 and NM-2 use separate keys, see §5.6/§6.4). The scrape job is `data-service`, from the ServiceMonitor `monitoring/data-service` in `41_monitoring.yml`.

| Alert | Expr (per class, `T` = threshold) | For | Severity |
|---|---|---|---|
| `NetmonCollectorStale` | `(time() - g{sel} > T) or (g{sel} != g{sel} and on(namespace, pod) (time() - kube_pod_start_time{namespace="apps"} > T))` | 10m | warning |
| `NetmonDataServiceDown` | `up{job="data-service"} == 0 or absent(up{job="data-service"})` | 10m | warning |

- `g` is `netmon_collector_last_success_timestamp_seconds`.
- The classes, each with a static label `threshold`, are: `26h` for `blocklists` and `retention`; `3h` for `egress`; `90m` for `lan` and `reputation`; `15m` for every other collector, as a catch-all.
- The NaN branch waits until the Pod is older than `T`, so a fresh Pod does not alert on a daily collector that has not reached its slot yet. Pod age comes from kube-state-metrics' `kube_pod_start_time`. The JVM's `process_start_time_seconds` would reset on every in-Pod container restart and restart the grace period.
- **Contract for data-service:** a disabled collector (`netmon.collectors.<name>.enabled=false`) must not export the gauge. A NaN that never changes would otherwise fire permanently.
- (amended 2026-09-23, NM-1: homelab#116)

### 4.2 Cloudflare GraphQL (NM-1)

- **Request:** `POST https://api.cloudflare.com/client/v4/graphql` with headers `Authorization: Bearer ${CLOUDFLARE_API_TOKEN}` and `Content-Type: application/json`. The body is `{"query": "...", "variables": {...}}`.
- **Timeouts:** 10 s connect and read.
- **Zone:** `zoneTag` = `${CLOUDFLARE_ZONE_ID}`.
- **Token permissions** (created by the owner): zone `furchert.ch` with Analytics:Read. That permission serves both datasets: both Cloudflare collectors have run successfully with it since 2026-09-24, so Firewall Services:Read is not needed (amended 2026-09-24, NM-1: data-service PR #19).

**Phase-1 probe (NM-1 must run this first and record the result in its worklog).** It confirms that the fields below are available on the Free plan.

```graphql
query Probe($zoneTag: string!) {
  viewer { zones(filter: {zoneTag: $zoneTag}) { settings {
    httpRequestsAdaptiveGroups { enabled availableFields maxDuration maxNumberOfFields maxPageSize notOlderThan }
    firewallEventsAdaptive     { enabled availableFields maxDuration maxPageSize notOlderThan }
  } } }
}
```

If a field used below is missing from `availableFields`, drop it from the query and keep the column nullable. If `clientIP` is unavailable in groups, NM-1 stops and returns to the architect.

**Probe result** (zone `furchert.ch`, Free plan, 2026-09-24). The `settings` node shape above is correct. (amended 2026-09-24, NM-1: data-service PR #19)

| | `httpRequestsAdaptiveGroups` | `firewallEventsAdaptive` |
|---|---|---|
| enabled | true | true |
| maxDuration | 2 592 000 s (30 d) | 2 592 000 s (30 d) |
| notOlderThan | 2 678 400 s (31 d) | 2 678 400 s (31 d) |
| maxPageSize | 10 000 | 10 000 |
| maxNumberOfFields | 40 | 40 |
| `clientAsn` / `clientASNDescription` | **missing** | present |

Every other field in queries A and B is available. The 5-min cadence and the ≤ 24 h query windows stay as specified. A 30-day initial backfill is a follow-up (`homelab-data-service#20`).

**Query A: request groups.** One call per window.

```graphql
query InboundGroups($zoneTag: string!, $since: Time!, $until: Time!, $limit: uint64!) {
  viewer { zones(filter: {zoneTag: $zoneTag}) {
    httpRequestsAdaptiveGroups(limit: $limit,
        filter: {datetime_geq: $since, datetime_lt: $until}, orderBy: [count_DESC]) {
      count
      avg { sampleInterval }
      dimensions { clientIP clientCountryName
                   clientRequestHTTPHost clientRequestHTTPMethodName clientRequestPath edgeResponseStatus }
    } } }
}
```

- **Variables:** `since` = hour start and `until` = min(hour end, now − 2 min), in RFC 3339 UTC. `limit` = min(`maxPageSize`, 5000).
- **Refresh cadence:** every 5 min the current hour is re-collected and its rows replaced. The previous hour is re-collected until `now ≥ hour_end + 15 min`, and then written once more with `is_final = true`. This gives 5-min freshness with hourly storage, and every step is idempotent.
- **Truncation:** if the row count equals `limit`, the hour is re-queried as 12 five-minute slices. Their groups are summed per natural key in memory, then written. If a slice is still truncated, the window is marked truncated in `last_error`, which the status API shows.

**Query B: firewall events.** Keyset pagination.

```graphql
query FirewallEvents($zoneTag: string!, $since: Time!, $until: Time!, $limit: uint64!) {
  viewer { zones(filter: {zoneTag: $zoneTag}) {
    firewallEventsAdaptive(limit: $limit,
        filter: {datetime_geq: $since, datetime_lt: $until}, orderBy: [datetime_ASC]) {
      datetime rayName clientIP clientCountryName clientAsn clientASNDescription
      action source ruleId clientRequestHTTPHost clientRequestHTTPMethodName clientRequestPath userAgent
    } } }
}
```

- `since` = `collector_state.last_window_end − 10 min` (a 10-min overlap; the UNIQUE key on `(ray_name, security_source, coalesce(rule_id,''), action)` absorbs the re-fetched duplicates), or now − 24 h the first time. `until` = now − 2 min. `limit` = min(`maxPageSize`, 1000).
- If a page is full, the next page starts at `datetime_geq` = last `datetime`. Duplicates are absorbed by the UNIQUE key. If a full page's first and last `datetime` are identical (more events share one timestamp than fit in a page), the run records `truncated` in `last_error` and continues with `datetime_gt` = that timestamp instead, to guarantee forward progress. There are at most 20 pages per run.
- On success, `last_window_end` is set to `until`. If the 20-page cap is hit before `until` is reached, `last_window_end` is set to the last `datetime` actually fetched, **not** `until` — so the next run resumes from the true gap instead of silently skipping the remainder of the window.

**Query budget.** Cloudflare allows 300 queries per 5 min per user.

| Source of queries | Count |
|---|---|
| Normal operation | A (current and previous hour) = 2, B = 1, so **3 per 5 min**, about 1 % |
| Worst case | A with slicing on both the current and previous hour = 13 + 13 = 26, B with 20 pages = 20, so **46 per 5 min** |
| Catch-up throttle | ≤ 60 queries per 5-min run |

**Error handling**

- A GraphQL response with a non-empty `errors[]` counts as a failure. The error message is logged, and the query variables are never logged.
- HTTP 401/403 means `consecutive_failures++`, and the status API reports `credentials`.
- 429 triggers backoff.

**"Sampled" means** Cloudflare Adaptive Bit Rate sampling. When `sampleInterval > 1`, `count` is extrapolated from a sample, and the UI shows a "≈" marker. A zone of this size is expected to be unsampled almost always (assumption).

### 4.3 IP enrichment (NM-1)

After every Cloudflare, LAN (public IPs only), egress (external destinations) or login write, upsert each distinct IP into `ip_enrichment`. This sets first/last seen and `seen_in`; the country/ASN fields are set from Cloudflare data when available, and stay `null` for IPs seen only via egress or LAN.

**Public-only filter.** IPs in these ranges are never enriched, never blocklist-matched and never sent to AbuseIPDB:

- 10/8, 172.16/12, 192.168/16, 100.64/10;
- 127/8, 169.254/16, 224/4, 240/4, 0/8;
- the IPv6 ranges ::1, fc00::/7 and fe80::/10.

### 4.4 Blocklists (NM-1)

| List | URL | Format |
|---|---|---|
| `spamhaus-drop-v4` | `https://www.spamhaus.org/drop/drop_v4.json` | NDJSON. Each line is `{"cidr":"…","sblid":"…","rir":"…"}`, and the last line is `{"type":"metadata",…}` (unverified exact shape) |
| `firehol-level1` | `https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset` | One IP or CIDR per line; `#` starts a comment |

- **Fetch:** daily with `If-None-Match` set to the stored etag. A 304 or an identical sha256 is recorded as `unchanged`.
- **Parse:** each list is parsed completely before `blocklist_entries` is replaced for that list. A failed or empty parse keeps the previous entries.
- **Private-range filter:** FireHOL level1 includes bogons and RFC 1918 ranges (unverified but expected). Entries that overlap any private range from 4.3 are **dropped** during parsing, so LAN addresses are never "blocklisted".
- **Matching:** after each `applied` refresh, recompute `blocklist_hits`/`blocklisted` for every `ip_enrichment` row with `last_seen` within 30 d, using an SQL join on `ip <<= cidr`. New IPs are matched on insert.

### 4.5 AbuseIPDB (NM-1, activated later)

The collector is disabled while `ABUSEIPDB_API_KEY` is absent. The owner turns it on with the optional SOPS variable `data_service_abuseipdb_key` (§9), following infrastructure `DEPLOYMENT.md` "NM-1 follow-up: AbuseIPDB key (optional)" (amended 2026-09-24, homelab#116 follow-up).

- **Request:** `GET https://api.abuseipdb.com/api/v2/check?ipAddress=<ip>&maxAgeInDays=90` with headers `Key: ${ABUSEIPDB_API_KEY}` and `Accept: application/json`.
- **Fields read:** `data.abuseConfidenceScore` and `data.totalReports`. Nothing else is stored.
- **Budget:** at most `netmon.abuseipdb.daily-budget` = **200** checks per UTC day, well under the free 1 000, and `per-run` = 10. The counter lives in memory plus `collector_state.cursor`, formatted as `date:count`.
- **Candidates:** public IPs that are not blocklisted and have `abuseipdb_checked_at` null or older than 7 d. Only IPs meeting **one** of these conditions (the threshold) are checked, in this priority order:
  1. ≥ 1 `login_events` failure or locked outcome in the last 24 h.
  2. ≥ 1 `firewall_events` row with an action other than `skip`/`log` in the last 24 h.
  3. ≥ 50 requests in the last 24 h with ≥ 50 % of them `status >= 400`.
  4. Top 5 IPs by request count in the last 24 h.
- **Errors:** a 429 stops the run and marks the day's budget as exhausted.

### 4.6 Prometheus snapshot collectors (NM-3, NM-2)

**Query mechanics.** Queries use `POST ${PROMETHEUS_URL}/api/v1/query` with the form fields `query` and `time`. `time` is evaluated at the window end, which makes a query for a past window deterministic, and that is what enables catch-up. The timeout is 10 s. data-service treats an empty vector as zero rows, not as an error.

**LAN collector.** Runs every 15 min for window `[T−15m, T)`, evaluated at `time=T`, and writes three tables.

```promql
# lan_connection_snapshots
max by (node, dport, src_ip, state) (max_over_time(homelab_lan_connections[15m]))
# ufw_block_snapshots — bucket gauge; the value for bucket [T-15m,T) is visible during [T, T+15m)
max by (node, src_ip, dport, proto) (homelab_ufw_blocks_bucket)
  and on (node) (homelab_netmon_bucket_end_timestamp_seconds == <T as unix seconds>)
# ssh_auth_snapshots
max by (node, src_ip, outcome) (homelab_sshd_auth_bucket)
  and on (node) (homelab_netmon_bucket_end_timestamp_seconds == <T as unix seconds>)
```

The two bucket queries are **instant vector selectors**, not `last_over_time(...[5m])` ranges: a range selector ignores Prometheus' staleness marker, so at `T+4m` it can still return a series' last pre-`T` sample from the *previous* bucket, and the `and on(node) bucket_end==T` guard does not filter that out — adjacent windows would double-count. An instant selector respects staleness, so a superseded value disappears as soon as the node publishes the next one.

They are evaluated at `time = T + 4 min`, not `T`. The collector cron is at :04, :19, :34 and :49, which gives the node scripts time to publish the finished bucket. The collector first queries `homelab_netmon_bucket_end_timestamp_seconds` per node; a node whose bucket timestamp does not match `T` is treated as not yet published and is skipped for that window, retried on the next run within the 48 h cap. A node with a matching guard but no matching `*_bucket` series (nothing happened in that bucket) gets its window replaced with 0 rows, not the previous window's values.

**Expected-node tracking.** "Expected nodes" for a window are the nodes with `homelab_netmon_last_success_timestamp_seconds` present at `T+4m` — a node absent for an extended period (such as the MacBooks' periodic hard resets) is not expected and does not block progress. `collector_state('lan').last_window_end` only advances past a window once every expected node's data has been written for it; this keeps the high-water mark meaningful even though it is tracked per collector, not per node.

**Egress collector.** Runs hourly for window `[T−1h, T)`, evaluated at `time=T`.

```promql
topk(500, sum by (node, container_id, destination, actual_destination) (increase(container_net_tcp_bytes_sent_total[1h])))
sum by (node, container_id, destination, actual_destination) (increase(container_net_tcp_bytes_received_total[1h]))
sum by (node, container_id, destination, actual_destination) (increase(container_net_tcp_successful_connects_total[1h]))
sum by (node, container_id, destination, actual_destination) (increase(container_net_tcp_failed_connects_total[1h]))
max by (ip, fqdn) (last_over_time(ip_to_fqdn[1h]))
group by (node, container_id, destination, actual_destination) (last_over_time(container_net_tcp_successful_connects_total[1h]))
```

- **Row set:** the union of the keys from the first four queries **plus the sixth**, capped at 2 000 rows per window by bytes_sent then connects. Hitting that cap, or the `topk(500)` bound of the bytes-sent query, completes the run with the `truncated` warning in `/status` (a success, §7.2) (amended 2026-09-24, NM-2: data-service#22, homelab#118). Missing values are 0. The sixth query exists because a counter series that first appears inside the window has exactly one sample, so `increase()` returns nothing for it — without this query, a brand-new single-connect destination would be entirely missing from the row set for its first hour. **First-window counts for such a destination are a lower bound**, since `increase()` cannot see accumulation before the counter's first sample.
- **FQDN:** joined on `destination_ip = ip`. If an IP maps to several FQDNs, the lexicographically first one is used.
- **Name-only destinations:** coroot v1.35.10 (`common/net.go` `NewDestinationKey`) reports an external name that resolves to more than one external IP, or ends in `.amazonaws.com`, `.googleapis.com`, `.pkg.dev` or `.gcr.io`, as `destination="<fqdn>:<port>"` with an **empty** `actual_destination`. Such rows have `destination_ip` NULL and take `fqdn` from `destination` (amended 2026-09-24, NM-2: data-service#22, homelab#118).
- **Idle destinations:** coroot drops a destination's series 10 min after its last connection attempt (`gcInterval`), so the `[1h]` presence query returns recently active destinations only (amended 2026-09-24, NM-2: data-service#22, homelab#118).
- **Metric names:** verified against the v1.35.10 source (`metrics/metrics.go`). Every container metric also carries `container_id` and `app_id`; the agent's registry adds `machine_id` and `system_uuid` to **every** series (including `ip_to_fqdn`), and the ServiceMonitor drops both with `labeldrop` because they are constant per node and `node` (added by the ServiceMonitor) already identifies it (amended 2026-09-23, NM-2 prep review). `container_net_tcp_failed_connects_total` has **no** `actual_destination` label (only `destination`), so the fourth query's `actual_destination` group is always empty. Failed connects join a row on `(node, container_id, destination)` only when exactly one row matches; otherwise (e.g. a Service with several backends) they form their own row with `actual_destination = ''`, which avoids double counting (amended 2026-09-24, NM-2: data-service#22, homelab#118). `container_id` for pods is `/k8s/<namespace>/<pod>/<container>` (`containers/registry.go`). The spike confirms these against live data and records any difference here (amended 2026-09-23, NM-2 prep: homelab PR for #118).

---

## 5. Node-script metric contract (NM-3, infrastructure)

### 5.1 Placement

- **Role:** `netmon_node` (the owner approved "conntrack-tools + Node-Script-Rolle"). It installs the apt package `conntrack`, which is the Ubuntu 24.04 package that provides the `conntrack` binary (the package name is unverified).
- **Script:** `/usr/local/sbin/homelab-netmon-collect`, written in Python 3 with the stdlib only (the Ubuntu base python3; no pip).
- **Units:** `homelab-netmon.service` (`Type=oneshot`, runs as root because conntrack and the kernel journal need it) and `homelab-netmon.timer` (`OnCalendar=*-*-* *:*:05`, `AccuracySec=1s`, `Persistent=false`).
- **Output:** one file, `/var/lib/node_exporter/textfile_collector/homelab_netmon.prom`. It is written atomically to `…/.homelab_netmon.prom.tmp` and then renamed.
- **Prerequisite:** the node-exporter `--collector.textfile.directory` flag comes from `homelab` PR #109, via `prometheus-node-exporter.extraArgs` and a hostPath mount. NM-3 must not duplicate it. The directory is created by both `netmon_node` and #109's storage role, with identical attributes. NM-3's PR targets `main`, and #109 merges first (§12 Q3) (amended 2026-09-23, NM-3: PR #132).
- **Playbook:** role `netmon_node` added to `10_base.yml`, gated behind tag `netmon_node`, mirroring the `mac_tweaks` precedent (PR #108). **Decision (main session, Phase 3 review, 2026-09-23):** not `41_monitoring.yml`, and not a new playbook — `10_base.yml` already runs with `become: true` for every node, so this role needs no new privilege escalation to justify.
- **Configuration:** role variables are `netmon_node_lan_cidr` (default from the inventory LAN var, `192.168.1.0/24`), `netmon_node_pod_cidr` (`10.42.0.0/16`), `netmon_node_ports` (`[1883, 22, 8123, 6443, 10250]` — `10250`, the kubelet API, is added beyond the four ports originally discussed with the owner; it is read-only visibility into an existing UFW-allowed port, not a new opening), `netmon_node_max_series` (`200`) and `netmon_node_conntrack_acct` (`false`). The role is idempotent.

### 5.2 Metrics (exact)

```
# HELP homelab_lan_connections Current conntrack TCP entries to a watched local port, by original source.
# TYPE homelab_lan_connections gauge
homelab_lan_connections{node="raspi5",dport="1883",src_ip="192.168.1.50",state="ESTABLISHED"} 1
# HELP homelab_ufw_blocks_bucket UFW BLOCK log lines in the last completed 15-minute bucket (see homelab_netmon_bucket_end_timestamp_seconds).
# TYPE homelab_ufw_blocks_bucket gauge
homelab_ufw_blocks_bucket{node="raspi5",src_ip="192.168.1.77",dport="23",proto="TCP"} 4
# HELP homelab_sshd_auth_bucket sshd authentication results in the last completed 15-minute bucket (failed is a lower bound).
# TYPE homelab_sshd_auth_bucket gauge
homelab_sshd_auth_bucket{node="raspi5",src_ip="10.42.0.0/16",outcome="failed"} 2
# HELP homelab_netmon_bucket_end_timestamp_seconds End (exclusive, unix seconds) of the bucket the *_bucket gauges describe.
# TYPE homelab_netmon_bucket_end_timestamp_seconds gauge
homelab_netmon_bucket_end_timestamp_seconds{node="raspi5"} 1758620700
# HELP homelab_netmon_last_success_timestamp_seconds Unix time of the last successful script run.
# TYPE homelab_netmon_last_success_timestamp_seconds gauge
homelab_netmon_last_success_timestamp_seconds{node="raspi5"} 1758620765
# HELP homelab_netmon_truncated_series Series dropped into src_ip="other" because netmon_node_max_series was exceeded, per metric.
# TYPE homelab_netmon_truncated_series gauge
homelab_netmon_truncated_series{node="raspi5",metric="homelab_ufw_blocks_bucket"} 0
```

- **`node` label:** written by the script from the Ansible `inventory_hostname` (`raspi5`, `raspi4`, `mba1`, `mba2`). Verified: the node-exporter ServiceMonitor (chart 69.3.1) sets `honorLabels: true` and adds no `node` target label, so the file's label is kept as `node`, not `exported_node`, and the §4.6 queries stand (amended 2026-09-23, NM-3: homelab PR for #117).
- **`src_ip` values:** an IP inside `lan_cidr` is kept verbatim. An IP inside `pod_cidr` becomes the literal `10.42.0.0/16` (for all three metrics; the sshd example above was corrected accordingly). Anything else becomes `other`. For `ufw` and `sshd`, public (globally routable) IPs are also kept verbatim, because these are the attack signals. Tunnelled SSH appears as a pod or node IP.
- **sshd outcomes are disjoint:** one connection for a non-existent user counts once as `invalid_user` (the `Invalid user …` line); its follow-up `Failed … for invalid user …` line is **not** counted as `failed`, and `Connection closed by / Disconnected from invalid user …` lines are not counted at all. `failed` therefore means failed authentication for an existing user (amended 2026-09-23, NM-3: PR #132).
- **Own outbound flows:** `homelab_lan_connections` skips conntrack entries whose original source is one of the node's own addresses (`ip -o addr show`) — the node is then the client (e.g. the API server calling another node's kubelet on :10250), and the receiving node already counts the flow as inbound (amended 2026-09-23, NM-3: homelab PR for #117).
- **Cardinality bound:** the /24 LAN has 254 sources, times 5 ports and a few states. The hard cap is `netmon_node_max_series` per metric per node. The highest-valued series are kept verbatim; the overflow is summed into `src_ip="other"` (other labels kept) and counted in `homelab_netmon_truncated_series` (number of input series not emitted verbatim). For `homelab_ufw_blocks_bucket` the overflow also collapses `dport` to `0`, because one scanner sweeping ports would otherwise stay unbounded; an overflow row is therefore `{src_ip="other",dport="0",proto=<proto>}` (amended 2026-09-23, NM-3: homelab PR for #117).

### 5.3 Why gauges and buckets, not counters (decided)

Blocks and SSH attempts come from **sparse, short-lived label sets**, such as a scanning IP seen once. A Prometheus counter series that first appears with value N makes `increase()` miss those N events. Such series also never end cleanly, and cumulative state has to survive reboots.

A **completed-bucket gauge** avoids all three problems:

- **Deterministic:** each run recomputes the last completed 15-min bucket from the journal with `--since`/`--until`. No cursor state is kept on the node.
- **Scrape-rate independent:** the value is constant for the whole next bucket, so the scrape interval cannot double-count it.
- **Idempotent to read:** the `homelab_netmon_bucket_end_timestamp_seconds` guard ties values to a window.

`homelab_lan_connections` is a plain point-in-time gauge, because peak concurrency over a window is `max_over_time`.

### 5.4 Collection commands (shape only; no secrets involved)

```bash
# LAN connections: original-direction source + state, one call per watched port
conntrack -L -p tcp --orig-port-dst <port> 2>/dev/null
#   parse per line: first "src=" (original source), TCP state token (e.g. ESTABLISHED, TIME_WAIT)
# UFW blocks for bucket [S, E)
journalctl -k --since "@<S>" --until "@<E>" --no-pager -o cat | grep -F '[UFW BLOCK]'
#   parse SRC=, DPT= (absent -> 0), PROTO= ; ignore [UFW AUDIT]/[UFW ALLOW]
# sshd outcomes for bucket [S, E)   (unit name "ssh" on Ubuntu 24.04 — unverified)
journalctl -u ssh --since "@<S>" --until "@<E>" --no-pager -o cat
#   "Accepted <method> for <user> from <ip>"     -> accepted
#   "Failed <method> for (invalid user )?<user> from <ip>" -> failed
#   "Invalid user <user> from <ip>"              -> invalid_user
#   usernames are parsed only to classify and are NEVER emitted as labels
#   the username is attacker-controlled and may contain " from <ip> port <n>": the patterns
#   are greedy and anchored at the end of the line (… from (\S+) port \d+ ssh2(?:: .*)?$ and
#   … from (\S+) port \d+$), so the peer address sshd appends last always wins
```

`conntrack -L` lists the **IPv4** table only (its default family); v1 makes no `-f ipv6` call because the LAN is IPv4. `failed` in `homelab_sshd_auth_bucket` is a **lower bound**: at the default `LogLevel INFO`, sshd logs rejected public keys only once a connection gives up (after `MaxAuthTries`/2 attempts), not per offered key (amended 2026-09-23, NM-3: PR #132).

UFW's logging rules are rate-limited (`-m limit`, which is 3/min burst 10 at the default level; unverified on these nodes). `homelab_ufw_blocks_bucket` is therefore a **lower bound**, and the UI must label it that way.

### 5.5 `nf_conntrack_acct` decision

NM-3 leaves `net.netfilter.nf_conntrack_acct` **unchanged** (default 0), because LAN metrics need counts, not bytes. Only the NM-2 fallback (§6.6) sets it to 1. It does that through `/etc/sysctl.d/60-homelab-netmon.conf`, gated by `netmon_node_conntrack_acct: true`. The setting affects only new flows and has negligible overhead (assumption).

### 5.6 PrometheusRules (NM-3)

NM-3's rules go under `additionalPrometheusRulesMap.homelab-netmon-node` (group `homelab-netmon-node`). Each producer has its own key, and each key renders its own PrometheusRule: `homelab-netmon` (NM-1, PR #131), `homelab-netmon-node` (NM-3, PR #132) and `homelab-netmon-egress` (NM-2, PR #133; see §6.4). This keeps the PRs independently mergeable (amended 2026-09-23, NM-3: PR #132). `NetmonSeriesTruncated` is `info`, which the chart's `InfoInhibitor` keeps out of Discord unless a warning fires in the same namespace; it stays visible in Prometheus/Alertmanager.

| Alert | Expr | For | Severity |
|---|---|---|---|
| `NetmonNodeScriptStale` | `time() - homelab_netmon_last_success_timestamp_seconds > 600` | 5m | warning |
| `NetmonSeriesTruncated` | `homelab_netmon_truncated_series > 0` | 30m | info |

---

## 6. coroot-node-agent contract (NM-2, infrastructure)

### 6.1 Workload

| Item | Contract |
|---|---|
| Kind and namespace | `DaemonSet/coroot-node-agent` in `monitoring`. It is a hand-written manifest, applied by `41_monitoring.yml` (or the NM-2 plan's choice) from `cluster/monitoring/coroot-node-agent/`. It uses no Helm chart, because the chart is stale at 0.2.21. |
| Image | `ghcr.io/coroot/coroot-node-agent:1.35.10@sha256:<multi-arch index digest>`. The digest is resolved at implementation. No helm-tracking entry is needed. The image version is tracked in the manifest comment, following the cloudflared precedent. |
| Pod security | `hostPID: true`, container `securityContext.privileged: true`. No `hostNetwork` (unverified; confirm against upstream). |
| Host mounts (verified against coroot-operator v1.10.2 `controller/node_agent.go`) | `/sys/fs/cgroup` → `/host/sys/fs/cgroup` (ro), `/sys/kernel/tracing` → `/sys/kernel/tracing`, `/sys/kernel/debug` → `/sys/kernel/debug`, plus an `emptyDir` at `/tmp` (default `--wal-dir`). The containerd socket is reached through `/proc/1/root` (hostPID); `/run/k3s/containerd/containerd.sock` is in the agent's built-in probe list. No `hostNetwork` (the operator does not set it either). |
| Args (verified in `flags/flags.go`, `flags/flags_linux.go` at v1.35.10) | `--cgroupfs-root=/host/sys/fs/cgroup`, `--listen=0.0.0.0:80`, `--disable-log-parsing`, `--disable-pinger`, `--disable-gpu-monitoring`; no `--collector-endpoint`/`--metrics-endpoint` (either one moves the listener to `127.0.0.1:10300` and pushes data out). **L7 tracing stays on:** `ip_to_fqdn` is filled from DNS responses seen by the L7 tracer, so `--disable-l7-tracing` would empty the FQDN mapping. The agent never calls the Kubernetes API, so `automountServiceAccountToken: false`. |
| Tolerations and gate | `operator: Exists`. Scheduling is gated by `nodeSelector` `homelab.furchert.ch/coroot-node-agent: "enabled"`; `41_monitoring.yml` sets that label on the nodes in `coroot_node_agent_nodes` (default `[]` until the spike; `[raspi5, mba1]` since 2026-09-24) and removes it elsewhere, so the spike and the all-node rollout are playbook runs, not manifest edits |
| Resources (sized by the spike, §6.3) | requests `cpu: 50m`, `memory: 256Mi`; limits `cpu: 300m`, `memory: 1Gi`. 384Mi OOMKilled both spike agents during the startup scan (peaks 410 / 702 MiB); 1Gi leaves margin above that peak (amended 2026-09-24, NM-2 spike). |
| Labels | `app.kubernetes.io/name: coroot-node-agent` |
| NetworkPolicy | `networkpolicy.yaml`: ingress to the agent pods only from the kube-prometheus-stack Prometheus pods (`app.kubernetes.io/name: prometheus`, `operator.prometheus.io/name: kube-prometheus-stack-prometheus`, verified live) on TCP 80. The agent serves `/metrics` and Go's `/debug/pprof/*` unauthenticated from a privileged hostPID pod; pprof shares the default mux and has no disable flag at v1.35.10. Node-local traffic is always admitted by Kubernetes, so host processes and hostNetwork pods on an agent node (Home Assistant has no node pin) still reach pprof. Accepting that, or adding a `/metrics`-only proxy sidecar (a new pinned image, needs owner approval), is an owner decision before the all-node rollout (amended 2026-09-24, PR #133 review). Egress is not restricted (amended 2026-09-23, NM-2 prep review). |

### 6.2 Scrape

- **Objects:** a headless `Service` (port `metrics` 80) plus a `ServiceMonitor` labelled `release: kube-prometheus-stack`, which matches the live Prometheus `serviceMonitorSelector` (verified 2026-09-23). The scrape interval is 30 s.
- **`relabelings`:** `__meta_kubernetes_pod_node_name` → `node`.
- **`sampleLimit`: 10000 per target**, counted after `metricRelabelings`. A scrape that exceeds it fails, which fires the down alert and acts as a hard cardinality stop.
- **`metricRelabelings` (keep-list):**

```yaml
- sourceLabels: [__name__]
  regex: 'container_net_tcp_(successful_connects|failed_connects|bytes_sent|bytes_received)_total|container_net_tcp_active_connections|ip_to_fqdn'
  action: keep
```

- **Dropped by the keep-list:** `container_net_latency_seconds`, which has one series per destination IP and little value here; `container_dns_requests_total` and its ndots search-path noise, dropped until a consumer actually needs DNS-request counts (adding it back needs its own keep + drop-rule pair); and retransmits and all L7, CPU, memory and disk metrics.

### 6.3 Spike acceptance criteria

The spike runs on a single node first: raspi5, then mba1. Rollout to all nodes needs the owner's go.

**Kernel checks** (read-only, per node, recorded in the NM-2 worklog):

```bash
uname -r; ls -l /sys/kernel/btf/vmlinux
grep -E 'CONFIG_BPF_SYSCALL=|CONFIG_BPF_JIT=|CONFIG_DEBUG_INFO_BTF=' /boot/config-$(uname -r)
mount | grep -E 'tracefs|debugfs'; sysctl net.netfilter.nf_conntrack_acct
```

**Results** (2026-09-23, read-only over SSH) (amended 2026-09-23, NM-2 prep: homelab PR for #118):

| Node | Arch | Kernel | `/sys/kernel/btf/vmlinux` | BPF_SYSCALL / BPF_JIT | DEBUG_INFO_BTF | NET_CLS_BPF / NET_SCH_INGRESS | tracefs / debugfs | lockdown | `nf_conntrack_acct` | CPUs | RAM total / avail (MiB) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| raspi5 | aarch64 | 6.8.0-1053-raspi | present | y / y | y (+ modules) | m / m | mounted / mounted | none | 0 | 4 | 7937 / 5007 |
| raspi4 | aarch64 | 6.8.0-1047-raspi | present | y / y | y (+ modules) | m / m | mounted / mounted | none | 0 | 4 | 3784 / 2127 |
| mba1 | x86_64 | 6.12.79-1-t2-noble | **absent** | y / y | no (`DEBUG_INFO_NONE=y`) | m / m | mounted / mounted | none | 0 | 8 | 7750 / 4277 |
| mba2 | x86_64 | 6.19.10-2-t2-noble | **absent** | y / y | no (`DEBUG_INFO_NONE=y`) | m / m | mounted / mounted | none | 0 | 4 | 7808 / 5320 |

Criterion 1 holds on all four nodes. mba1 and mba2 run different t2 kernels, so a pass on mba1 does not automatically cover mba2. Prometheus baseline for criterion 6: `prometheus_tsdb_head_series` = 108 985.

Every criterion must hold on **both** raspi5 and mba1:

| # | Criterion |
|---|---|
| 1 | The kernel is ≥ 5.1 and `CONFIG_BPF_SYSCALL=y`. BTF is **not** required. |
| 2 | The agent is `Running` for ≥ 24 h with 0 restarts and no OOMKilled. The node's `journalctl -k` shows no BPF verifier errors. |
| 3 | `container_net_tcp_successful_connects_total` has a non-empty `actual_destination` for ≥ 3 known flows: furchert-ch → auth-service, flux → github.com, litellm → an external API. |
| 4 | The post-relabel series count per agent is below **5 000** (`scrape_samples_post_metric_relabeling`). |
| 5 | CPU averages below **100m** and stays below 250m at p95. Memory: RSS below **150 MiB** steady, working set below **450 MiB** steady (it includes reclaimable page cache from reading container binaries), and the startup peak below the memory limit. This replaces the earlier "working set < 200 Mi", which counted page cache (amended 2026-09-24, NM-2 spike). |
| 6 | Prometheus `prometheus_tsdb_head_series` grows by less than **10 %**. |
| 7 | The `container_id` format is recorded and §3.3/§4.6 are updated to match. |

**Spike result (raspi5 + mba1, from 2026-09-24 11:52)** (amended 2026-09-24, NM-2 spike):

| Measure | raspi5 | mba1 |
|---|---|---|
| First start at a 384Mi limit | OOMKilled in the startup scan, working-set peak 410 MiB | OOMKilled, peak 702 MiB |
| Restarts at 768Mi, 2 h+ | 0 | 0 |
| `up` | 1 | 1 |
| Series after relabeling | 161 | 771 |
| CPU | 0.02 cores | 0.05 cores |
| Working set steady (2 h band) | 320 MiB (313–327) | 399 MiB (370–420) |
| RSS steady | 69 MiB | 105 MiB |

eBPF loads on mba1's BTF-less t2 kernel. No alerts fired. Metrics flow (285 connect series, 12 `ip_to_fqdn` series). Criteria 1, 4 and 5 hold. Still to record: criterion 2's full 24 h window, and criteria 3, 6 and 7. Rollout order after the go: mba2 (different t2 kernel), then raspi4 (4 GB RAM).

**If criteria 1–3 fail on mba1/mba2**, run the agent on arm64 only (`nodeSelector: kubernetes.io/arch: arm64`) and use the §6.6 fallback on the Macs. **If they fail on the Pis too**, use the full fallback.

### 6.4 PrometheusRules

These go in `additionalPrometheusRulesMap.homelab-netmon-egress` (NM-2's own key, see §5.6), following the `homelab-backups` precedent from PR #109.

| Alert | Expr | For | Severity |
|---|---|---|---|
| `NetmonNewExternalDestination` | see below | 0m | info |
| `CorootNodeAgentDown` | `absent(kube_daemonset_status_desired_number_scheduled{namespace="monitoring", daemonset="coroot-node-agent"}) or max(kube_daemonset_status_number_available{…}) > (count(up{job="coroot-node-agent"} == 1) or vector(0))` | 10m | warning |

`NetmonNodeScriptStale` and `NetmonSeriesTruncated` cover the NM-3 node script, not coroot, and are defined in §5.6.

```promql
group by (workload, dest) (<D>(<W>(container_net_tcp_successful_connects_total{actual_destination!~"(10\\.4[23]\\.|192\\.168\\.|127\\.).*"})))
unless on (workload, dest)
group by (workload, dest) (<D>(<W>(last_over_time(container_net_tcp_successful_connects_total[1d] offset 15m))))
# <D>(v) = label_replace(label_replace(v, "dest", "$1", "destination", "(.+)"),
#            "dest", "$1", "actual_destination", "(.+)")
# <W>(v) = label_replace(label_replace(v, "workload", "$1", "container_id", "(.*)"),
#            "workload", "$1/$2/$3", "container_id",
#            "/k8s/([^/]+)/(.+?)(?:-[bcdfghjklmnpqrstvwxz2456789]{6,10})?-[bcdfghjklmnpqrstvwxz2456789]{5}/(.+)")
```

**Why `dest`** (amended 2026-09-24, NM-2: data-service#22, homelab#118): `dest` is `actual_destination` where coroot reports one, else `destination`. Name-only destinations (§4.6) have an empty `actual_destination`; keyed by it, all of a workload's name-only destinations collapsed into one `""` key and only the first ever alerted. An empty `actual_destination` passes the private-range filter, which is intended for these external names. The alert fires once per `(workload, dest)`.

**Why `workload`, not `container_id`** (amended 2026-09-23, NM-2 prep): `container_id` contains the pod name, which changes on every Deployment rollout. Grouped by `container_id`, every Flux image update would re-report all of a workload's known destinations. `<W>` strips the ReplicaSet hash and pod suffix (`/k8s/apps/litellm-5d8f7c9b6-x2k9p/litellm` → `apps/litellm/litellm`), the same rollout-stable identity and string format as the `workload_key` that `is_new` uses in §3.3 (amended 2026-09-24, NM-2: data-service#22, homelab#118). Pods whose names do not match (StatefulSets, systemd units) keep the raw `container_id`, and so do CronJob rows, because `<W>` only matches `/k8s/` ids. The exact expression is in `cluster/values/kube-prometheus-stack.yaml`; its promtool unit tests are in `cluster/values/tests/netmon-egress.test.yml`, run by `scripts/promtool-test-rules.sh` (amended 2026-09-24, NM-2: data-service#22, homelab#118).

**Why this `CorootNodeAgentDown` form** (amended 2026-09-23, NM-2 prep): the original `absent(up{…})` fires permanently while the spike gate is closed (DaemonSet present, 0 pods, 0 targets). The new form fires when the DaemonSet is missing, or when fewer agents are scraped successfully than are available (Service/ServiceMonitor missing, selector drift, `sampleLimit` exceeded). Crash loops, stuck rollouts and plain scrape failures are already covered by the chart's `KubePodCrashLooping`, `KubeDaemonSetRolloutStuck` and `TargetDown`, following PR #109's no-duplicate-alert rule.

The expression alerts on **series presence**, not on `increase() > 0`: a brand-new destination's counter has only one sample inside a 15 m window, so `increase()` over that window would return nothing and the alert would never fire for exactly the case it exists to catch. `group by (...) (metric)` turns the raw series into a 1-valued presence indicator regardless of its counter value, and the `unless` compares that against the same presence check over the prior day.

- **Labels and routing:** the alert is labelled `workload` and `dest`, one alert per new destination (amended 2026-09-24, NM-2: data-service#22, homelab#118). It is `severity: info` and carries `namespace: monitoring`. The chart's `InfoInhibitor` normally suppresses `info` alerts unless a warning/critical alert fires in the same namespace, so it normally shows in Alertmanager and Prometheus without reaching Discord. The rule group is evaluated every `5m` instead of the global 30 s, because its 1-day `last_over_time` is the most expensive query of the group (amended 2026-09-23, NM-2 prep review). Raising it to `warning` is an owner decision after the spike and the noise tuning below (amended 2026-09-23, NM-2 prep).
- **Noise:** it is expected to be noisy for CDN-rotating destinations. A name that flips between one and several IPs across DNS refreshes changes its key between `ip:port` and `fqdn:port`, which yields one extra `info` alert per flip (amended 2026-09-24, NM-2: data-service#22, homelab#118). Tuning, such as grouping by /24 or an FQDN suffix, is an NM-2 Phase-5 follow-up. It is not an allowlist.

### 6.5 Docs

The NM-2 PR adds the agent to `infrastructure/INTERFACES.md` §9 Observability and `DEPLOYMENT.md` § Monitoring. It also records the agent as an approved privileged workload in `monitoring`. Because CI (`infrastructure/.github/workflows/ci.yml:206-211,272-277`) loops over explicit directories rather than discovering new ones, **the NM-2 PR adds `cluster/monitoring/coroot-node-agent` to both CI loops** (kubeconform and conftest) — otherwise the new manifest gets neither check.

### 6.6 Fallback: conntrack egress (only if the spike fails)

The NM-3 script is extended, and the role sets `netmon_node_conntrack_acct: true`. It adds:

```
# TYPE homelab_egress_connections gauge
homelab_egress_connections{node,src_ip,dst_ip,dport,proto}   # current entries, dst outside pod/service/LAN CIDRs
# TYPE homelab_egress_bytes_bucket gauge
homelab_egress_bytes_bucket{node,src_ip,dst_ip,dport,proto,direction="sent|received"}   # bytes in last completed 15-min bucket
```

- The same cap and `other` rule as §5.2 applies.
- data-service maps `src_ip` (a pod IP) to a pod with `kube_pod_info{pod_ip}` from kube-state-metrics in the same PromQL query, and fills `egress_flow_snapshots` with `fqdn = null`.
- The fallback cannot produce `ip_to_fqdn`.

---

## 7. data-service read API and ingest contract

### 7.1 Common conventions

| Item | Contract |
|---|---|
| Base URL | `http://data-service.apps.svc.cluster.local:8082/api/netmon` (cluster-internal only) |
| Auth | `Authorization: Bearer <JWT>` (§7.5). Only `/actuator/health`, `/actuator/info` and `/actuator/prometheus` are public (amended 2026-09-23, NM-0: data-service PR #18). |
| Time window | `from` and `to` are ISO-8601 instants, e.g. `2026-09-23T10:00:00Z`. `to` defaults to now and `from` defaults to `to − 24h`, unless an endpoint says otherwise. `to − from` must be > 0 and ≤ **30 d**, or the response is 400. Windowed tables are filtered by overlap: `window_start < to AND window_end > from`. |
| Paging | Lists take `limit`, with a default of 50 and a maximum of 500. They also take `cursor`, an opaque string from the previous response. Responses carry `nextCursor`, which is a string or `null`. |
| JSON | camelCase. Timestamps are ISO-8601 UTC with `Z`. IPs are strings. Counts and bytes are integers. Absent optional values are `null`, never omitted. |
| Errors | RFC 9457 `application/problem+json` with the fields `type`, `title`, `status`, `detail` and `instance`, plus `code`. `code` is one of `invalid_window`, `invalid_parameter`, `not_found`, `unauthorized`, `forbidden` or `internal`. `detail` never echoes a token or a stack trace. |
| Caching | Every response has `Cache-Control: no-store` and `Pragma: no-cache`, because the data is personal. |
| Status codes | 200, 400, 401, 403, 404 (IP detail only), and 500 |

`/actuator/prometheus` is served **without** authentication, the same as `/actuator/health` — it is a cluster-internal scrape target for the approved Q9 metrics, and those metrics carry no IP labels. The Service port serving it is named `http` (amended 2026-09-23, NM-0: data-service PR #18). The ServiceMonitor for data-service and the `NetmonCollectorStale` PrometheusRule ship with NM-1's infrastructure child (`homelab#116`), because NM-0 has no collectors yet (amended 2026-09-23, NM-0: data-service PR #18).

Top-N lists take `limit` with a default of 10 and a maximum of 50.

### 7.2 Endpoints

**`GET /status`.** Collector freshness for the UI's honest-fallback banner.

```json
{ "collectors": [ { "name": "cloudflare-requests", "enabled": true, "lastSuccessAt": "…Z", "lastWindowEnd": "…Z",
                    "consecutiveFailures": 0, "lastErrorCode": null, "stale": false } ] }
```

- `stale` = `lastSuccessAt` is older than 3 × the cadence.
- `lastErrorCode` is `null`, `credentials`, `rate_limited`, `upstream`, `truncated` or `internal`. It is never a message.
- Before a collector's first success, staleness is measured from the service start time (amended 2026-09-23, NM-0: data-service PR #18).
- A collector run that completes with a warning (e.g. `upstream` when no node exposes the NM-3 metrics yet, or `truncated`) is recorded as a success: `lastSuccessAt` advances, `consecutiveFailures` stays 0 and `lastErrorCode` carries the warning code. Consumers must treat `lastErrorCode = upstream` with `consecutiveFailures = 0` as "no data yet", not as an outage (amended 2026-09-24, data-service `INTERFACES.md`).

**`GET /inbound/summary?from&to&host&limit`** (NM-1)

```json
{ "window": {"from": "…Z", "to": "…Z"},
  "totals": {"requests": 1234, "uniqueClientIps": 87, "sampled": false},
  "topClientIps": [ {"ip": "203.0.113.7", "requests": 120, "country": "DE", "asn": 3320, "asnOrg": "DTAG",
                     "blocklisted": false, "abuseScore": null, "firewallEvents": 3} ],
  "topCountries": [ {"country": "CH", "requests": 800} ],
  "topAsns":      [ {"asn": 3303, "asnOrg": "SWISSCOM", "requests": 500} ],
  "topHosts":     [ {"host": "furchert.ch", "requests": 900} ],
  "topPaths":     [ {"host": "furchert.ch", "path": "/de", "requests": 300} ],
  "statuses":     [ {"status": 200, "requests": 1100} ],
  "timeline":     [ {"bucketStart": "…Z", "requests": 52} ] }
```

- The `timeline` bucket is 1 h when `to − from` ≤ 7 d, otherwise 1 d.
- `sampled` is true if any contributing row is sampled.
- `topClientIps[].asn`/`asnOrg` come from `ip_enrichment`, and `topAsns` joins `ip_enrichment`. Both cover only IPs whose ASN is known from firewall events (§3.3), so `topAsns` does not sum to `totals.requests` (amended 2026-09-24, NM-1: data-service PR #19).

**`GET /inbound/firewall-events?from&to&action&host&ip&limit&cursor`** (NM-1)

```json
{ "items": [ {"occurredAt": "…Z", "rayName": "8c1…", "clientIp": "…", "country": "…", "asn": 1, "asnOrg": "…",
              "action": "block", "securitySource": "firewallManaged", "ruleId": "…", "host": "…", "method": "GET",
              "path": "/wp-login.php", "userAgent": "…", "blocklisted": true} ],
  "nextCursor": null }
```

- Items are ordered by `occurredAt` descending.

**`GET /ips/{ip}?from&to`** (NM-1, later extended by NM-3 and NM-4). The default window is **7 d**. A malformed `ip` returns 400. An IP never seen returns 404.

```json
{ "ip": "…", "firstSeen": "…Z", "lastSeen": "…Z", "seenIn": ["inbound", "login"],
  "country": "…", "asn": 1, "asnOrg": "…",
  "blocklists": [ {"list": "firehol-level1", "cidr": "…/24", "fetchedAt": "…Z"} ],
  "abuseIpDb": {"score": 87, "reports": 412, "checkedAt": "…Z"},
  "inbound": {"requests": 40, "topHosts": [], "topPaths": [], "statuses": []},
  "firewallEvents": [],
  "logins": {"success": 0, "failure": 12, "locked": 0},
  "lan": {"ufwBlocks": 0, "sshFailed": 0} }
```

- `abuseIpDb` is `null` if the IP was never checked.
- `firewallEvents` holds the last 20 items, in the same shape as the firewall-events list.
- `logins` is `null` before NM-4 and `lan` is `null` before NM-3.

**`GET /egress/top?from&to&namespace&workload&scope&limit`** (NM-2). `scope` is `external` (the default) or `all`. `workload` is an optional filter (amended 2026-09-24, NM-2: data-service#22, homelab#118).

```json
{ "items": [ {"namespace": "apps", "workload": "litellm", "container": "litellm", "node": "mba1",
              "destinationIp": "…", "destinationPort": 443, "fqdn": "api.anthropic.com", "scope": "external",
              "bytesSent": 1, "bytesReceived": 1, "connects": 1, "failedConnects": 0,
              "firstSeenInWindow": "…Z", "isNew": true} ] }
```

- Rows are aggregated by `(namespace, workload, container, destination_host, destination_port)`.
- For name-only destinations `destinationIp` carries the name (as does `fqdn`). This is a documented deviation from the field name; furchert-ch renders non-IP text as is (amended 2026-09-24, NM-2: data-service#22, homelab#118).
- `node` is the most frequent node for the row.
- Items are ordered by `bytesSent + bytesReceived` descending.

**`GET /lan/connections?from&to&node&dport`** (NM-3)

```json
{ "items": [ {"node": "raspi5", "dport": 1883, "srcIp": "192.168.1.50", "state": "ESTABLISHED",
              "peakConnections": 2, "windows": 96, "firstSeen": "…Z", "lastSeen": "…Z"} ] }
```

**`GET /lan/ufw-blocks?from&to&node&limit`** (NM-3)

```json
{ "lowerBound": true, "totals": {"blocks": 57},
  "items": [ {"srcIp": "…", "dport": 23, "proto": "TCP", "blocks": 12, "nodes": ["raspi5"]} ] }
```

**`GET /lan/ssh-auth?from&to&node`** (NM-3)

```json
{ "items": [ {"node": "raspi5", "srcIp": "…", "accepted": 3, "failed": 1, "invalidUser": 0} ] }
```

**`GET /logins/summary?from&to&limit`** (NM-4)

```json
{ "totals": {"success": 10, "failure": 4, "locked": 0},
  "byIp": [ {"ip": "…", "success": 0, "failure": 4, "locked": 0, "country": "…", "blocklisted": false, "abuseScore": null} ],
  "bySubject": [ {"subject": "dominic", "success": 10, "failureSameHmac": 1} ],
  "timeline": [ {"bucketStart": "…Z", "success": 1, "failure": 0, "locked": 0} ] }
```

- `failureSameHmac` counts failures whose `usernameHmac` equals the HMAC seen on that subject's successes. That links failed attempts to known accounts without storing the attempted usernames.

**`GET /logins/events?from&to&outcome&ip&limit&cursor`** (NM-4)

```json
{ "items": [ {"occurredAt": "…Z", "outcome": "failure", "clientIp": "…", "ipSource": "cf-connecting-ip",
              "subject": null, "usernameHmacPrefix": "3fa9c1d2", "userAgent": "…", "country": "…", "blocklisted": false} ],
  "nextCursor": null }
```

- Only the first 8 hex characters of the HMAC are exposed, which is enough to group events visually.

### 7.3 Implementation notes that bind the contract

- Requests to unknown query parameters are ignored.
- Every endpoint is read-only, so the API has no POST, PUT or DELETE.
- The API has no admin actions in v1. An AbuseIPDB re-check button is a follow-up.
- If the JWKS endpoint is unreachable, data-service answers 500 `problem+json` with code `internal` (no default Boot error body) (amended 2026-09-23, NM-0: data-service PR #18).

### 7.4 Error example

```json
{ "type": "about:blank", "title": "Bad Request", "status": 400, "code": "invalid_window",
  "detail": "to - from must be > 0 and <= 30 days", "instance": "/api/netmon/inbound/summary" }
```

### 7.5 Auth path (decided): client credentials for the existing `furchert-ch` client

**Validation against auth-service (verified in code):**

- The `furchert-ch` client exists with grant types `authorization_code` and `refresh_token` and scopes `openid profile email` (`auth-service/src/main/resources/application.yaml:83-92`). `client_credentials` is already supported and in use: the `device-service` client has it (`:66`), and device clients have it too.
- **Clients are JDBC-backed, and the YAML is bootstrap-only.** `StaticClientSeeder` skips existing `client_id`s, so editing `application.yaml` alone changes nothing in production (`auth-service/INTERFACES.md` §6 note).
- For `client_credentials`, Spring Authorization Server grants **only explicitly requested** scopes, which must be a subset of the registered ones. The token customizer adds no `role` claim, because no ROLE_ authority is present, and adds `device_id` only for `client_kind='device'`. `furchert-ch` is `sso`, so it gets no `device_id`.

**Required auth-service change** (NM-0 child PR in `homelab-auth-service`):

1. In `application.yaml`, add `grant-types: [authorization_code, refresh_token, client_credentials]` to the `furchert-ch` client, and add `"netmon:read"` to its `scopes`. This covers fresh databases.
2. Add a Flyway migration `V<next>__furchert_ch_client_credentials.sql` (currently `V6`). It is an idempotent `UPDATE oauth2_registered_client` for `client_id = 'furchert-ch'`. It appends `client_credentials` to `authorization_grant_types` and `netmon:read` to `scopes`, and only when they are absent. The columns are comma-separated. On a fresh DB it matches 0 rows and the seeder applies step 1. This is the production path.
3. Update auth-service `INTERFACES.md`. The §1 grant-types row must no longer say "IoT device clients only", and a new subsection documents `netmon:read`.

**Token request** (made by furchert-ch, server-side):

```
POST http://auth-service.apps.svc.cluster.local:8080/oauth2/token
Authorization: Basic base64(furchert-ch:<OIDC_CLIENT_SECRET>)
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&scope=netmon:read
```

- **Resulting access token:** `iss=https://auth.furchert.ch`, because the issuer is fixed by `AuthorizationServerSettings` even on the internal URL. The token also carries `sub=furchert-ch`, `aud=furchert-ch`, `scope=["netmon:read"]` and `exp` = 15 min.
- **Caching:** furchert-ch caches it in process until `exp − 60 s`.

**Checks performed by data-service** (Spring resource server):

- **Configuration:** set both `jwk-set-uri=http://auth-service.apps.svc.cluster.local:8080/oauth2/jwks` and `issuer-uri=https://auth.furchert.ch`. With `jwk-set-uri` set, Boot adds the issuer validator without needing discovery, so `iss` is still checked.
- **Signature, `exp` and `iss`:** validated by the defaults.
- **Authority mapping.** Use the **auth-service** converter pattern (`auth-service/src/main/java/ch/furchert/homelab/auth/config/SecurityConfig.java:149-167`), which merges the unprefixed `role` claim (`ROLE_<value>`) with the default `SCOPE_` authorities. Do **not** copy device-service's converter (`device-service/.../config/SecurityConfig.java:78-88`): it maps only `role` and drops the `SCOPE_` authorities entirely, which would make `SCOPE_netmon:read` never match and turn every furchert-ch call into a 403.
- **Authorization for `/api/netmon/**` (v1):** access is granted **only** if `SCOPE_netmon:read` **and** `sub ∈ netmon.api.allowed-clients` (default `[furchert-ch]`). `ROLE_ADMIN` is **not** accepted in v1: since only signature/`exp`/`iss` are validated, a user token with `role=ADMIN` issued to *any* client would otherwise pass — and grafana, n8n, litellm and Home Assistant all hold user tokens server-side, so a compromised third-party app would be able to read IP-level personal data. When the deferred user-token path (`furchert-ch#43`) lands, the check becomes `ROLE_ADMIN` **and** `aud` contains `furchert-ch`; that is an explicit API change made by that follow-up, not something v1 needs to pre-accept.
- **Why the `sub` check:** it is defence in depth. `netmon:read` is registered on a client that also runs `authorization_code`. A crafted authorize request could ask for that scope in a user flow, but Auth.js would reject it (PKCE and state), and furchert-ch does not persist access tokens. The `sub` allowlist rejects such tokens anyway, because their `sub` is a username.

**Alternative, deferred: forward the user's access token.** This would give per-user auditing and make ADMIN enforcement in data-service primary. It is blocked on `furchert-ch#43`, because the access token is not persisted in the Auth.js session and needs chunk-aware cookie handling. Revisit when #43 ships — that follow-up is what adds the `ROLE_ADMIN` + `aud` check to data-service, as part of its own API change.

**Alternative rejected: a dedicated client such as `furchert-ch-netmon`.** It separates the grants cleanly, but needs a new SOPS secret and a second credential in furchert-ch. The owner's recommendation (reuse) plus the `sub` check covers the risk. If the owner prefers the dedicated client, only the client ID/secret names in §8/§9 change.

### 7.6 Login-event channel (decided): **pull**. data-service pulls a transport outbox in auth-service.

| Option | Verdict |
|---|---|
| Push: auth-service POSTs to data-service with a service token | Rejected. auth-service would gain its first outbound runtime dependency (`052` and auth-service `CLAUDE.md`: "makes no runtime calls to other services"). It would also need a client registration to mint a token for itself. Events would be lost or blocked while data-service is down, or it would need its own retry queue. |
| INSERT-only DB role on `netmon.login_events` | Rejected. auth-service would couple to data-service's schema and credentials and get a second DataSource, and a shared table breaks the one-owner rule. |
| **Pull (chosen)** | Consistent with every other collector, since data-service pulls everything and producers only expose. auth-service stays call-free. An outage of data-service shorter than 72 h loses nothing. Replays are idempotent via `eventId`. |

**auth-service side (NM-4)**

- **Capture.** Listen for Spring Security `AuthenticationSuccessEvent` and `AbstractAuthenticationFailureEvent`, and **only** where the authentication is a `UsernamePasswordAuthenticationToken` from the form login. JWT-bearer and client authentications also publish events and must be ignored. Verified: the events fire exactly once per form-login attempt, for success, failure and locked (amended 2026-09-24, NM-4: auth-service PR #96).
- **Outcome mapping.** `CustomUserDetailsService` (`auth-service/.../security/CustomUserDetailsService.java:27-34`) sets only `enabled = (users.status == "ACTIVE")`; it never sets the locked/expired flags. So `DisabledException` is the only account-status exception this codebase can actually throw, and it is thrown **before** the password check.

  | Result | `outcome` |
  |---|---|
  | Success | `success` |
  | `DisabledException` (`users.status != ACTIVE`; thrown before the password check) | `locked` |
  | Any other failure | `failure` |
- **Client IP.** Use the `CF-Connecting-IP` header if present and parseable as an IP (`ipSource=cf-connecting-ip`). Otherwise use `request.getRemoteAddr()` (`ipSource=remote-addr`). Tomcat's RemoteIpValve is active via `forward-headers-strategy: native` (`application.yaml:23`), and it can already rewrite `getRemoteAddr()` from `X-Forwarded-For` before this code runs — so `ipSource=remote-addr` may itself be header-derived, not a lower-trust fallback below the explicit `CF-Connecting-IP` path. Both are spoofable in-cluster (§10).
- **Username.** `usernameHmac` = lowercase hex of `HMAC-SHA256(key = ${LOGIN_EVENT_HMAC_KEY}, message = lowercase(trim(submitted username)))`.
  - **Why a keyed hash:** users sometimes type a password into the username field, so failed-attempt usernames can contain secrets and junk PII that must not be copied into a second DB and its backups.
  - **Why keyed rather than a plain hash:** the username space is tiny, so an unkeyed SHA-256 is reversible by dictionary. The key stays in auth-service only.
  - `subject` (plaintext username) is set **only** for `success`.
- **Outbox.** A table `login_event_outbox` in `homelabdb`, owned by auth-service and created by its own Flyway migration. Its columns are `id bigserial PK`, `event_id uuid unique`, `occurred_at`, `outcome`, `client_ip`, `ip_source`, `username_hmac`, `subject`, `user_agent` and `recorded_at default now()`.
  - Capture IP, user agent and username **synchronously**, inside the Spring Security event listener itself — auth-service has no `@EnableAsync` (`AuthServiceApplication.java:10` only has `@EnableScheduling`), so the insert cannot rely on Spring's `@Async`. Hand the captured, immutable record to a bounded single-thread executor that performs the actual insert off the login path. If that queue is full, the record is dropped and a **WARN** (not ERROR — this is expected, bounded backpressure, not an incident that should page through Sentry) is logged **without** the IP or username. A login must never fail because of telemetry.
  - Purge job: rows with `recorded_at < now() - 72h`, hourly. This TTL purge is the only one. There is no early purge below data-service's cursor (§10) (amended 2026-09-24, NM-4: auth-service PR #96).
- **Endpoint.** `GET /api/v1/login-events?after=<id>&limit=<n>`, where `after` defaults to 0 and `limit` defaults to 500 with a maximum of 1000.
  - It requires `SCOPE_login-events:read` via `@PreAuthorize("hasAuthority('SCOPE_login-events:read')")` on the controller method — the chain-wide `.anyRequest().authenticated()` (`SecurityConfig.java:51`) is not enough by itself, since it would also accept a signed-in user's `ROLE_ADMIN` token. NM-4's tests include a case asserting that an ADMIN user token gets 403 here.
  - It returns rows with `id > after AND recorded_at <= now() - interval '10 seconds'`, ordered by `id`. The 10 s settle window avoids skipping ids whose transactions commit late.
  - While the feature is disabled (§9), the endpoint answers **503**, not 404.
  - Errors use auth-service's existing body `{"status": 400, "error": "…", "timestamp": "…Z"}`, not RFC 9457 `problem+json`. The codes are 400 for a negative or non-numeric `after` or a `limit` outside 1–1000, 401 without a token, 403 without the scope, and 503 while disabled.
  - Settings live under `app.login-events.*`: `hmac-key`, `ttl` (72 h), `settle` (10 s), `queue-capacity` (1000), `default-limit` (500), `max-limit` (1000) and `purge-cron` (hourly).
  - The payload field names are exactly those in the example below. `source_service` is a data-service column (§3.3), not part of the auth-service payload.
  - (amended 2026-09-24, NM-4: auth-service PR #96)

```json
{ "events": [ {"id": 1234, "eventId": "0b6f…", "occurredAt": "…Z", "outcome": "failure", "clientIp": "203.0.113.7",
               "ipSource": "cf-connecting-ip", "usernameHmac": "<64 hex>", "subject": null, "userAgent": "…"} ],
  "nextAfter": 1234, "hasMore": false }
```

**New auth-service client for data-service.** Its client ID is `data-service`, with `grant-types: [client_credentials]`, `scopes: ["login-events:read"]` and no redirect URIs.

- Because it is a new client, the YAML seeder creates it on the next boot, so no migration is needed.
- Verified: `StaticClientSeeder` accepts the empty redirect-URI list. It skips the client while `DATA_SERVICE_CLIENT_SECRET` is blank, and creates it on the first boot that has the secret.
- The seeder never updates an existing client. Rotating the secret after that first boot therefore also needs an update of the `oauth2_registered_client` row (auth-service `INTERFACES.md` §6), not only a new SOPS value.
- (amended 2026-09-24, NM-4: auth-service PR #96)

**data-service side.** The `login-events` collector runs every minute.

1. Get a token from `${AUTH_TOKEN_URL}` using `${AUTH_CLIENT_ID}:${AUTH_CLIENT_SECRET}` and `scope=login-events:read`.
2. Page with `after = collector_state.cursor` while `hasMore` is true, up to 10 pages per run.
3. Upsert on `event_id`, update the cursor, and enrich the IPs (§4.3).

---

## 8. furchert-ch UI contract

| Item | Contract |
|---|---|
| Route | `/[locale]/dashboard/network` (`src/app/[locale]/dashboard/network/page.tsx`), with `dynamic = 'force-dynamic'` |
| Gating | Copy the dashboard gate: `assertAuthEnv()`, then `await auth()` in try/catch, then `<SignInGate>` when there is no session. Then check `asRole(session.user?.role) === 'ADMIN'`, and otherwise render the shared `src/app/[locale]/dashboard/NoAccess.tsx`. **This component does not exist yet** — NM-1 creates it if `furchert-ch#44` has not landed first, and the two efforts then share it (`#44`/`#45`). Any `/api/**` handler added later calls `auth()` and performs the same check itself. |
| Nav | `DevSubnav` gets a `network` tab. The union becomes `'overview' \| 'network'`, it gains a Link, and the key is `dashboard.subnav.network`. The tab is shown to every signed-in user, and the page decides access. |
| Env | `DATA_SERVICE_URL` (default `http://data-service.apps.svc.cluster.local:8082`, trailing slash stripped) and `DATA_SERVICE_TOKEN_URL` (default `http://auth-service.apps.svc.cluster.local:8080/oauth2/token`). Both are read lazily in `src/netmon.env.ts`, which mirrors `metrics.env.ts`, including a `shouldAttemptNetmon()` that skips the fetch in dev when the URL is unset. |
| Credentials | Reuse the existing `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` (Secret `furchert-ch-secrets`, key `oidc-client-secret`). **No new secret.** |
| Data access | Server-only modules `src/lib/netmon/token.ts` (client-credentials token plus in-memory cache) and `src/lib/netmon/client.ts`. Every call uses `fetch` with `cache: 'no-store'` and `AbortSignal.timeout(5000)`. That is longer than Prometheus' 2.5 s because 30-day aggregates on a Pi are slower (assumption). Sections load with `Promise.allSettled`. A failed section renders an honest "unavailable" state with a null value, never fabricated data. Logs use the `[netmon]` prefix and never include tokens, URLs with query strings, or IPs. |
| Window and IP selection | These are search params, so no client JS is needed. `?window=24h\|7d\|30d` (default `24h`) is mapped to `from`/`to` on the server. `?ip=<ip>` renders an IP-detail panel at the top from `GET /ips/{ip}`. The IP is validated server-side before use. |
| Browser | The browser never calls data-service or auth-service. The CSP stays same-origin (`connect-src 'self'`). v1 needs no route handler. |
| Charts | No chart library. Bars are inline `<div>` bars and the timeline is inline SVG `<rect>`s, following the `DashboardShell` bar-meter idiom and ETHON tokens. Tables are the first shared table markup and stay co-located in `network/`. |
| i18n | All strings in `de.json` and `en.json` under `dashboard.network.*` plus `dashboard.subnav.network` and `dashboard.noAccess.*` |

**Sections** (rendered top to bottom; a section whose sub-project has not shipped shows a labelled "not yet available" placeholder):

| Section | Sub-project | API | Content |
|---|---|---|---|
| Status strip | NM-1 | `/status` | Per-collector freshness dot (StatusDot) with "stale" or "unavailable" |
| IP detail (conditional) | NM-1 | `/ips/{ip}` | Enrichment, blocklists, AbuseIPDB, recent activity |
| Inbound | NM-1 | `/inbound/summary`, `/inbound/firewall-events` | Totals, timeline, top IPs (link `?ip=`), countries, ASNs, hosts, paths, status bars, firewall events table |
| LAN | NM-3 | `/lan/*` | Connections per port by source, UFW blocks labelled as a lower bound, SSH outcomes |
| Egress | NM-2 | `/egress/top` | Top destinations per workload, "new" badge, FQDN |
| Logins | NM-4 | `/logins/*` | Totals, top IPs with failures, recent events |

**i18n key skeleton:**

- `dashboard.network.{title, subtitle, window.{24h,7d,30d}, unavailable, notYetAvailable, sampled, lowerBound}`
- `dashboard.network.status.{title, stale, ok, disabled}`
- `dashboard.network.inbound.{title, requests, uniqueIps, topIps, countries, asns, hosts, paths, statuses, firewall.{title, action, source, rule}}`
- `dashboard.network.ip.{title, firstSeen, lastSeen, blocklists, abuseScore, notChecked}`
- `dashboard.network.lan.{title, connections, ufwBlocks, sshAuth}`
- `dashboard.network.egress.{title, workload, destination, fqdn, bytesSent, bytesReceived, new}`
- `dashboard.network.logins.{title, success, failure, locked, byIp, events}`
- `dashboard.noAccess.{title, body}`

**Docs in the same furchert-ch PR:**

- `INTERFACES.md` gets a new backend section for data-service that links to this spec.
- `DEPLOYMENT.md` and `.env.local.example` get the two env vars.
- `OVERVIEW.md` gets the routes table entry, and `CHANGELOG.md` gets an entry.
- `k8s/deployment.yaml` gets the two env vars as plain values.

---

## 9. Platform and secrets contract (infrastructure)

Secrets are provisioned by the owner. Implementers add only variable **names**, asserts and Secret wiring.

**SOPS variables** (`infra/inventory/group_vars/all.sops.yml` and `.example`)

| Variable | Sub-project | Consumer | Notes |
|---|---|---|---|
| `data_service_db_password` | NM-0 | data-service (role `data_service`) | Random, e.g. `openssl rand -hex 24` |
| `data_service_cloudflare_analytics_token` | NM-1 | data-service | Created by the owner (§4.2 permissions) |
| `data_service_cloudflare_zone_id` | NM-1 | data-service | Not a credential, but kept with the token for one source of config |
| `data_service_abuseipdb_key` | NM-1 (later) | data-service | Optional. Its assert is skipped when undefined. |
| `auth_service_data_service_client_secret` | NM-4 | auth-service (`{noop}`-prefixed), data-service (plain) | Follows the `auth_service_<client>_client_secret` pattern. Optional, see below. |
| `auth_service_login_event_hmac_key` | NM-4 | auth-service only | At least 32 characters, e.g. `openssl rand -base64 48`. Rotating it breaks HMAC continuity for events already stored. Optional, see below. |
| *(reused)* `auth_service_furchert_ch_client_secret` | NM-0 | furchert-ch (existing `oidc-client-secret`) | **No new var.** The client-credentials call uses the existing secret. |

**Kubernetes Secrets** (ns `apps`, created by `59_app_services.yml`, `no_log: true`)

| Secret | Keys | Sub-project |
|---|---|---|
| `data-service-secrets` | `db-username` (literal `data_service`), `db-password`, `cloudflare-api-token`, `cloudflare-zone-id`, `abuseipdb-api-key` (only when defined), `auth-client-secret` | NM-0 creates it with the DB keys. NM-1 and NM-4 add keys. |
| `homelab-auth-secrets` (existing) | add `data-service-client-secret: "{noop}<value>"` and `login-event-hmac-key` | NM-4 |

**NM-4 keys are optional in playbook 59.** The two NM-4 SOPS variables go together. With neither set, playbook 59 skips `data-service-client-secret`, `login-event-hmac-key` and `auth-client-secret`, so it keeps working before the owner adds the values. It does not delete keys that an earlier run created; turning NM-4 off again is a manual step (infra `DEPLOYMENT.md`). With only one set, a short HMAC key or a client secret that already starts with `{`, the playbook fails. The keys are added by separate tasks that patch the existing Secrets (amended 2026-09-24, NM-4 infra: homelab#134).

**Postgres tasks.** These go in `59_app_services.yml` and mirror the LiteLLM block (`:290-359`):

1. Assert `data_service_db_password`.
2. Create the role if it is missing (`CREATE ROLE data_service WITH LOGIN`, `changed_when` on `CREATE ROLE`).
3. Set the password via the base64/`format('ALTER ROLE %I WITH PASSWORD %L')` stdin pattern, with `no_log` and `changed_when: false`.
4. Create the DB if it is missing (`CREATE DATABASE data_service OWNER data_service`).

Flyway creates the schema `netmon`, since the owner may create schemas. The brief placed these tasks in `50_apps_infra.yml`, but the existing per-app DB pattern is in playbook 59 and in 54 for club_assistant.

**data-service deployment env** (`homelab-data-service/k8s/deployment.yaml`)

| Env | Value / source |
|---|---|
| `DB_URL` | `jdbc:postgresql://postgresql.apps.svc.cluster.local:5432/data_service` |
| `DB_USERNAME` / `DB_PASSWORD` | secretKeyRef `data-service-secrets` / `db-username`, `db-password` |
| `JWT_ISSUER` / `JWKS_URI` | `https://auth.furchert.ch` / `http://auth-service.apps.svc.cluster.local:8080/oauth2/jwks` |
| `PROMETHEUS_URL` | `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |
| `CLOUDFLARE_GRAPHQL_URL` | `https://api.cloudflare.com/client/v4/graphql` |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ZONE_ID` | secretKeyRef `cloudflare-api-token` / `cloudflare-zone-id` (`optional: true` until NM-1) |
| `ABUSEIPDB_API_KEY` | secretKeyRef `abuseipdb-api-key`, `optional: true` |
| `AUTH_TOKEN_URL` / `AUTH_SERVICE_URL` | `http://auth-service.apps.svc.cluster.local:8080/oauth2/token` / `http://auth-service.apps.svc.cluster.local:8080` |
| `AUTH_CLIENT_ID` / `AUTH_CLIENT_SECRET` | `data-service` / secretKeyRef `auth-client-secret` (`optional: true` until NM-4) |

The rest of the deployment follows the `052` baseline:

- port 8082;
- requests `100m`/`256Mi`, limits `1000m`/`512Mi`;
- JVM `-Xmx128m -XX:+UseSerialGC -XX:MaxMetaspaceSize=96m` (raised from 64m: NM-0 measured ~56 MB metaspace for data-service alone) (amended 2026-09-23, NM-0: data-service PR #18), which the spike may raise to `-Xmx192m`;
- probes on `/actuator/health` with a 300 s startup budget;
- `replicas: 1`, `automountServiceAccountToken: false`, and a multi-arch image `ghcr.io/doemefu/homelab-data-service` with the Flux image-automation marker.

**Flux.** Add `cluster/apps/data-service/{source,sync,imagerepo,imagepolicy,imageupdate,kustomization}.yaml`, cloned from `cluster/apps/device-service/`, and list the directory in `cluster/apps/kustomization.yaml`. The image tag scheme is the same as the siblings' (assumption).

**Flux prerequisites (owner actions, NM-0).** The spec's earlier draft omitted three owner/secret steps that block the GitRepository and image automation from ever reconciling:

1. **Deploy key.** `GitRepository.spec.secretRef` needs a Secret `data-service-flux-auth` holding an SSH deploy key with **write** access to `homelab-data-service` (mirrors `infrastructure/cluster/apps/device-service/source.yaml:11-12`; see `CONTRIBUTING.md:492`). The owner creates the GitHub deploy key and its SOPS/Secret counterpart.
2. **GHCR visibility.** A new GHCR package (`ghcr.io/doemefu/homelab-data-service`) defaults to **private**, so the `ImageRepository` needs either the package made public or a `ghcr-auth` pull secret wired in (`imagerepo.yaml:9-18`).
3. **Branch ruleset.** `homelab-data-service`'s branch protection ruleset must allow the Flux automation's push to `main` (the image-tag commit), the same way the existing service repos' rulesets do.

**NM-0 order:** DB/Secret (playbook 59 run) → `data-service` repo populated with `k8s/` and a first built image → `cluster/apps/data-service/` wiring applied.

**auth-service deployment env additions** (`auth-service/k8s/deployment.yaml`, NM-4)

| Env | Value / source |
|---|---|
| `DATA_SERVICE_CLIENT_SECRET` | secretKeyRef `homelab-auth-secrets` / `data-service-client-secret` |
| `LOGIN_EVENT_HMAC_KEY` | secretKeyRef `homelab-auth-secrets` / `login-event-hmac-key` |

auth-service is Flux-auto-deployed on every merge to `main`, and it is the sole IdP, so a missing Secret key must never stop the pod. Both env vars are therefore **optional**: the `secretKeyRef`s have `optional: true`, and the Spring config uses empty defaults (`${DATA_SERVICE_CLIENT_SECRET:}`, `${LOGIN_EVENT_HMAC_KEY:}`). While either is missing, or the HMAC key is shorter than 32 characters, auth-service starts normally, does not seed the `data-service` client, records no login events, answers 503 on `/api/v1/login-events` and logs one WARN. The auth-service PR can therefore merge at any time. **NM-4 enable order:** SOPS vars added → playbook 59 run (creates the Secret keys) → auth-service restart (env vars are read at pod start) → data-service PR (`homelab-data-service#17`) → furchert-ch PR (`furchert-ch#64`). §11's NM-4 acceptance criteria still include "the auth-service pod restarts cleanly" (amended 2026-09-24, NM-4: auth-service PR #96, homelab#134).

**Backups.** No change is needed. `scripts/backup-app-data.sh` reads the database list from the server at runtime (`PG_DATABASE_QUERY`), so `data_service` is dumped automatically. The brief assumed a per-DB list, and that assumption is corrected here. Longhorn and restic cover the Postgres PVC as before.

**Tracking.** coroot-node-agent is a plain manifest, so no helm-tracking entry is needed. Its image and digest are bumped by hand, with a comment in the manifest (cloudflared precedent). The data-service image is tracked by Flux image automation.

**Architecture doc.** The NM-0 infra PR amends `docs/052-architecture-target.md` in the data-service section: "Database: PostgreSQL — `data_service` (schema `netmon`)", plus a reference to ADR 0002 and this spec. It also adds data-service's egress destinations (§10).

---

## 10. Security and privacy

- **IP addresses are personal data.** They are admin-only in the UI. The data-service API is cluster-internal only and requires `netmon:read` from an allowed client (§7.5; v1 does not accept ROLE_ADMIN) (amended 2026-09-23, NM-0: data-service PR #18). Retention is bounded (§3.3), and nothing leaves the cluster except AbuseIPDB lookups of public IPs that crossed the §4.5 threshold.
- **No secrets in logs:**
  - data-service never logs tokens, `Authorization` headers, GraphQL variables or AbuseIPDB keys, and `last_error` holds a class and short message only;
  - furchert-ch never logs tokens or IPs;
  - node scripts never emit usernames.
- **`CF-Connecting-IP` is spoofable in-cluster, and so is the `remote-addr` fallback.** No NetworkPolicy exists, so any pod can call auth-service directly with a forged `CF-Connecting-IP` header; and because Tomcat's RemoteIpValve is active, `request.getRemoteAddr()` can itself already be XFF-derived (§7.6), so falling back to it is not a materially more trustworthy path. This is accepted for the homelab. **Follow-up issue:** add NetworkPolicies so that auth-service :8080 accepts ingress only from cloudflared (ns `platform`), furchert-ch and data-service, and data-service :8082 accepts ingress only from furchert-ch. k3s' embedded policy controller enforces them.
- **The login-event outbox is a transient buffer, but backups are not.** `login_event_outbox` (§7.6) holds up to 72 h of login IPs, user agents and (for successful logins) plaintext usernames before its hourly purge. `scripts/backup-app-data.sh`'s dumps and the nightly Longhorn snapshot both capture whatever is in the table when they run, so up to 72 h of that data can persist in a backup or snapshot after the live row has been purged. This is accepted as a bounded, documented exposure. NM-4 does not purge rows at or below data-service's last-pulled cursor ahead of the 72 h cap. auth-service does not know that cursor, so the 72 h TTL purge is the only one (amended 2026-09-24, NM-4: auth-service PR #96).
- **No Sentry in data-service v1** (§12 dependency table). Both auth-service and device-service ship `sentry-spring-boot-4`; data-service defers it to keep the initial dependency set minimal, and because `last_error` (§3.3) already captures the exception class and a short message — with no IPs — for the collector-failure case that matters most.
- **Never raise cloudflared's log level** to debug. At debug it logs request headers, including cookies and `Authorization`.
- **Tunnelled SSH hides client IPs.** fail2ban and `ssh_auth_snapshots` see the cloudflared path, not the attacker. Cloudflare Access for ssh/grafana/n8n is a follow-up.
- **Outbound destinations of data-service** must be documented in the infra `INTERFACES.md`. They are:
  - `api.cloudflare.com:443`, `www.spamhaus.org:443`, `raw.githubusercontent.com:443` and `api.abuseipdb.com:443`;
  - the cluster-internal auth-service, Prometheus and PostgreSQL.

  Blocklists are fetched **only** by data-service.
- **Privileged DaemonSet.** coroot-node-agent runs privileged with hostPID in `monitoring`. It was explicitly approved by the owner, and the rollout needs a go after the spike. A NetworkPolicy limits pod-network ingress to its unauthenticated `:80` (`/metrics`, `/debug/pprof/*`) to Prometheus; node-local sources, including hostNetwork pods such as Home Assistant, stay able to reach pprof (§6.1) (amended 2026-09-24, PR #133 review); cluster-wide NetworkPolicies remain the follow-up `homelab#127` (amended 2026-09-23, NM-2 prep review).
- **HMAC key.** The key lives in auth-service only. data-service stores only HMACs, and the API exposes only an 8-hex-character prefix.

---

## 11. Rollout and acceptance criteria

The order is **NM-0 → NM-1 → NM-3 → NM-2 → NM-4**. Within each sub-project the producer goes first, then data-service, then furchert-ch, with one branch and one PR per repo. All changes are additive, and **no backwards-incompatible contract change** exists. The furchert-ch client change adds a grant and a scope without removing anything.

| Sub-project | Acceptance criteria (all must hold) |
|---|---|
| NM-0 | `data_service` DB and role exist, and a second playbook-59 run reports 0 changes. The data-service pod is Ready. `flyway_schema_history_data` shows V1. `GET /api/netmon/status` returns 401 without a token and 200 with a furchert-ch client-credentials token. A token without `netmon:read` gets 403. The auth-service migration is applied, and the existing furchert-ch login still works. The spec is committed to `infrastructure/docs/` and the forwarder is in place. |
| NM-1 | The probe result is recorded. `inbound_request_groups` fills hourly with `is_final` rows. `firewall_events` fills, and a re-run creates no duplicates (count stable). Both blocklists are `applied`, and no RFC 1918 IP is `blocklisted`. `/dashboard/network` renders the inbound section for ADMIN and NoAccess for USER, in DE and EN. `pnpm build` passes. |
| NM-3 | `homelab_netmon.prom` is present on all 4 nodes and a second role run reports 0 changes. The series per node stay under the cap. `lan_connection_snapshots` shows the mosquitto clients by LAN IP. A UFW block from a test host appears within 30 min. The UI LAN section renders. |
| NM-2 | The §6.3 spike criteria are met on raspi5 and mba1 and recorded. The owner gives a go before all nodes. The alerts load (`promtool check rules` or the rules visible in Prometheus). `egress_flow_snapshots` shows litellm's external destinations with FQDNs. The UI egress section renders. |
| NM-4 | The auth-service pod restarts cleanly after the `DATA_SERVICE_CLIENT_SECRET`/`LOGIN_EVENT_HMAC_KEY` env vars are wired (§9). A failed login from a test client appears in `login_events` within 2 min with `ipSource=cf-connecting-ip` and the correct outcome. The outbox purges rows older than 72 h. The login latency is unchanged, and a login still succeeds with data-service scaled to 0. The UI logins section renders. |

**GitHub issue map** (numbers filled in when the issues are created)

| Sub-project | homelab | homelab-data-service | homelab-auth-service | furchert-ch |
|---|---|---|---|---|
| Epic | #114 | — | — | — |
| NM-0 | #115 | #13 | #93 | — |
| NM-1 | #116 (secret, scrape, alerts) | #14 | — | #61 |
| NM-3 | #117 | #15 | — | #62 |
| NM-2 | #118 | #16 | — | #63 |
| NM-4 | #134 (secrets, spec amendments) | #17 | #94 | #64 |

---

## 12. Open questions and unverified items

**Open questions**

| # | Question | Blocks | Default if unanswered |
|---|---|---|---|
| Q1 | Cloudflare token creation, plus whether Firewall Services:Read is needed | resolved 2026-09-24: token created, Analytics:Read is enough (§4.2) | — |
| Q2 | Free-plan availability of `clientIP`, `clientASNDescription` and `userAgent` (§4.2 probe) | resolved 2026-09-24: all available except `clientAsn`/`clientASNDescription` on request groups, which were dropped (§4.2) | — |
| Q3 | `homelab` PR #109 merged (textfile collector) | **NM-3 (blocker)** | NM-3's PR does not duplicate #109 and targets `main`; #109 merges first, then NM-3 resolves the `additionalPrometheusRulesMap` conflict (one key, all entries) (amended 2026-09-23, NM-3) |
| Q4 | Go for the coroot spike, then for the all-node rollout | **NM-2 (blocker)** | — (owner action) |
| Q5 | data-service dependency set — see the table below. It must be approved before NM-0 implementation starts. | **NM-0 (blocker: approval)** | — |
| Q6 | Reuse the `furchert-ch` client (chosen) or a dedicated client | non-blocker | Reuse |
| Q7 | Retention defaults (90/180/30 d) | non-blocker | As in §3.3 |
| Q8 | AbuseIPDB key approval | non-blocker (collector disabled) | Disabled |
| Q9 | Micrometer/Prometheus metrics for data-service: `/actuator/prometheus` + a `ServiceMonitor` + a `NetmonCollectorStale` rule on `netmon_collector_last_success_timestamp_seconds` (§4.1). Needs the new `micrometer-registry-prometheus` dependency (below) and aligns with `auth-service#80`. **Approved 2026-09-23.** The dependency and the endpoint shipped with NM-0 (`homelab-data-service#13`, PR #18). The `ServiceMonitor` and the rules ship with NM-1 infra (`homelab#116`, PR #131). | resolved (NM-0 approval) | Until the NM-1 infra rollout: `/status` endpoint only, so collector stalls stay visible only in the UI, not alerted |
| Q10 | NetworkPolicy follow-up (§10) | non-blocker | Separate issue |
| Q11 | `nf_conntrack_acct=1` sysctl, needed only for the §6.6 fallback if the NM-2 coroot spike fails | non-blocker (blocks only the fallback path) | Not set; NM-2 stays on coroot-node-agent |

**Q5/Q9 dependency table (data-service, `homelab-data-service/pom.xml`).** "Mirrors sibling" cites which of `auth-service`/`device-service` already uses the artifact; "new" means neither does and it needs its own approval alongside this list.

| Artifact | Version source | Purpose | Mirrors sibling y/n |
|---|---|---|---|
| `org.springframework.boot:spring-boot-starter-webmvc` | Boot 4.1.1 BOM | REST controllers, JSON | y (auth-service, device-service) |
| `org.springframework.boot:spring-boot-starter-security` | Boot 4.1.1 BOM | Security filter chain | y |
| `org.springframework.boot:spring-boot-starter-security-oauth2-resource-server` | Boot 4.1.1 BOM | Validate JWTs against auth-service's JWKS (§7.5) | y (device-service) |
| `org.springframework.boot:spring-boot-starter-jdbc` | Boot 4.1.1 BOM | `JdbcClient` for bulk upserts, deliberately **no JPA** (§3.4) | **new** — both siblings use `spring-boot-starter-data-jpa` instead |
| `org.springframework.boot:spring-boot-starter-flyway` | Boot 4.1.1 BOM | Migrations | y |
| `org.flywaydb:flyway-database-postgresql` | Boot 4.1.1 BOM | Postgres Flyway dialect | y |
| `org.postgresql:postgresql` | Boot 4.1.1 BOM (auth-service pins `42.7.13` explicitly) | JDBC driver, runtime scope | y |
| `org.springframework.boot:spring-boot-starter-actuator` | Boot 4.1.1 BOM | `/actuator/health`, `/actuator/info` | y |
| `org.springframework.boot:spring-boot-starter-validation` | Boot 4.1.1 BOM | Bean validation on request DTOs | y |
| `org.projectlombok:lombok` | Boot 4.1.1 BOM, optional | Boilerplate reduction | y |
| `org.springdoc:springdoc-openapi-starter-webmvc-ui` | pinned `3.1.0` (auth-service's version) | OpenAPI docs (optional, per the original brief) | y |
| `io.micrometer:micrometer-registry-prometheus` | Boot 4.1.1 BOM | `/actuator/prometheus` + `NetmonCollectorStale` alert (Q9) | **new** — recommended by the main session, needs owner approval |
| `org.springframework.boot:spring-boot-starter-test` (test) | Boot 4.1.1 BOM | JUnit 5, AssertJ, Mockito, and `MockRestServiceServer` for the Cloudflare/Prometheus/AbuseIPDB HTTP stubs — no extra dependency needed for that | y |
| `org.springframework.boot:spring-boot-webmvc-test` (test) | Boot 4.1.1 BOM | `MockMvc` (split into its own artifact since Boot 4.0) | y |
| `org.springframework.security:spring-security-test` (test) | Boot 4.1.1 BOM | `@WithMockUser`, JWT test support | y (auth-service's naming; device-service, on Boot 4.0.5, uses the differently-named `spring-boot-starter-security-test`) |
| `org.springframework.boot:spring-boot-starter-security-oauth2-resource-server-test` (test) | Boot 4.1.1 BOM | Resource-server test slice | y (device-service) |
| `org.testcontainers:testcontainers-bom` (import, test) | pinned `2.0.5` | Aligns every Testcontainers artifact version in one place | y (auth-service) |
| `org.testcontainers:testcontainers-junit-jupiter` (test) | BOM-managed (`2.0.5`) | JUnit 5 extension | y |
| `org.testcontainers:testcontainers-postgresql` (test) | BOM-managed (`2.0.5`) | `postgres:17-alpine` container for repository/Flyway tests, as in auth-service | y |

**Explicitly excluded from v1** (defaults per the main session, recorded here so NM-0 does not re-litigate them): a hand-rolled `RestClient` (already in `spring-boot-starter-webmvc`) for the §7.5/§7.6 client-credentials token fetch, instead of adding `spring-boot-starter-security-oauth2-client`; and `io.sentry:sentry-spring-boot-4` (§10), even though both siblings ship it.

**Unverified items** (confirm in the owning sub-project's Phase 1)

| Item | Owner |
|---|---|
| ~~Cloudflare `settings` node shape; `maxPageSize` values~~ — verified by the 2026-09-24 probe (§4.2). Still open: `count` being sample-adjusted; `clientCountryName` being ISO-2; analytics ingest delay ≤ 2 min | NM-1 |
| Spamhaus `drop_v4.json` exact NDJSON shape; FireHOL level1 containing private ranges | NM-1 |
| coroot-node-agent footprint measured on raspi5 + mba1 (§6.3 spike result: RSS 69 / 105 MiB, working set 320 / 399 MiB, startup peak 410 / 702 MiB); still open: mba2, raspi4, and the live `container_id`/label shape (flags, mounts, port 80 and metric/label names verified in the v1.35.10 source on 2026-09-23) | NM-2 spike |
| ~~Whether the node-exporter scrape already adds a `node` label (possible `exported_node`)~~ — verified: it does not (`honorLabels: true`, §5.2) | NM-3 |
| apt package name `conntrack`; sshd unit name `ssh`; UFW log rate limits on these nodes | NM-3 |
| ~~Spring Security authentication events firing for auth-service's form-login chain; `users.status` → Locked/Disabled exception mapping~~ — verified in auth-service PR #96: one event per form-login attempt, `DisabledException` → `locked` (§7.6) | NM-4 |
| ~~`StaticClientSeeder` accepting a client with no redirect URIs~~ — verified in auth-service PR #96 (§7.6) | NM-4 |

**Decided during NM-0 implementation** (`homelab-data-service` PR #18, 2026-09-23)

| # | Decision |
|---|---|
| 1 | `/actuator/prometheus` served unauthenticated like `/actuator/health` (§7.1); ServiceMonitor + `NetmonCollectorStale` rule ship with NM-1's infrastructure child (`homelab#116`) |
| 2 | `collector_state.last_error_code` column added, CHECK-constrained to the §7.2 error-code enum (§3.3) |
| 3 | `/status` staleness is measured from the service start time before a collector's first success (§7.2) |
| 4 | `netmon_collector_last_success_timestamp_seconds` is NaN before first success; `NetmonCollectorStale` must treat NaN as "never succeeded" (§4.1) |
| 5 | JVM `-XX:MaxMetaspaceSize` raised from 64m to 96m (measured ~56 MB metaspace for NM-0 alone) (§9) |
| 6 | §10 corrected: v1 does not accept ROLE_ADMIN, only `netmon:read` per §7.5 |
| 7 | JWKS-unreachable failure mode specified: 500 `problem+json`, code `internal` (§7.3) |

---

Reviewed 2026-09-23 (plan-reviewer, PASS WITH CHANGES, 32 findings applied); amended 2026-09-23 after data-service PR #18.
NM-2 amendments (data-service#22, homelab#118): 2026-09-24.
