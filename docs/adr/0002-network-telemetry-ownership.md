# ADR 0002 — Network Telemetry Ownership: data-service as the Analytical Data Plane

> Canonical copy (infrastructure repo). The parent workspace file forwards here (since homelab#349). ADR 0001 stays in the parent workspace and is referenced by name only.

**Status:** Accepted 2026-09-23 (implemented by homelab-data-service#18, homelab-auth-service#95, homelab#126); amended 2026-11-08 (homelab#349, see Amendment)
**Scope:** cross-repo — `homelab-data-service`, `homelab` (infrastructure), `homelab-auth-service`, `furchert-ch`
**Extends:** ADR 0001 (parent workspace, `docs/adr/0001-schedules-ownership-and-data-plane.md`) — broadens data-service's scope; supersedes nothing else in 0001
**Contract:** [`../060-network-monitoring.md`](../060-network-monitoring.md)
**Tracking:** `doemefu/homelab#114` (Epic "Network monitoring")

---

## Context

The homelab has no network visibility today:

- **Public traffic** reaches the cluster only through the Cloudflare Tunnel. Inside the cluster, every tunnelled request comes from the cloudflared pod. The real client IP exists only at the Cloudflare edge (GraphQL Analytics) and in the `CF-Connecting-IP` header. Nothing records either.
- **Egress and east-west traffic** is invisible. node-exporter exposes per-interface and conntrack aggregates only, with no per-destination data.
- **LAN access to cluster ports** is unobserved. That covers MQTT on 1883 (anonymous), SSH, 6443, 10250 and Home Assistant 8123. UFW logs its blocks to the kernel log on every node, but nothing collects them.
- **Logins** at auth-service leave no per-source-IP trail.

Epic `homelab#114` collects these four data sets (sub-projects NM-1 to NM-4). Dominic added a binding requirement on where the data lives (2026-09-23, verbatim):

> "der datenhaushalt sollte möglichst einheitlich an einem zentralen ort bleiben (maintainability und nachvollziehbarkeit) und nicht gesplittert an verschiedenen orten in verschiedenen services aufbewahrt werden"

(English: the data should stay as uniformly as possible in one central place, for maintainability and traceability, and not be split across different places in different services.)

ADR 0001 defined data-service as the future **sensor-data** plane. data-service is still a README-only repo with no deployment. Its near-term scope was read-only historical InfluxDB queries.

## Decision

### 1. data-service is the analytical data plane

`homelab-data-service` owns **all analytical/historical data** in the homelab. That covers:

- **sensor history** (ADR 0001, unchanged: InfluxDB queries; ingestion stays in device-service until that separate decision is made), and
- **network telemetry** (new: every data set of Epic #114).

### 2. One store, one owner

Network telemetry is stored in **one PostgreSQL database** on the existing platform Postgres (`postgresql.apps.svc.cluster.local:5432`). The database is `data_service`, the schema is `netmon`, and the login role is `data_service`. Only data-service writes to it, migrates it with Flyway, applies retention to it, and serves it over its REST read API.

### 3. Producers emit, they do not keep

| Producer | What it does | What it must not do |
|---|---|---|
| Cloudflare (GraphQL Analytics) | Serves edge data for its plan window (7 d / 24 h) | — (external) |
| Prometheus | Carries coroot and node-script metrics as **transport** (14 d retention) | Act as the system of record for per-IP/per-destination data |
| Node scripts (NM-3) | Write current values into node-exporter textfiles | Keep history on the node |
| auth-service (NM-4) | Exposes login events in a **transport buffer** (≤ 72 h) that data-service pulls | Serve login history or analytics |

data-service **pulls** from every producer on a schedule. Every collector is idempotent.

### 4. Consumers read only through data-service

furchert-ch's `/dashboard/network` reads **only** data-service's REST API, server-side. It never reads Prometheus, Cloudflare or auth-service for network data. ADMIN gating stays in furchert-ch. data-service authorizes the service token.

### 5. Alerting stays in Prometheus

Infrastructure signals remain PrometheusRules routed to the existing Discord receiver. These include agent down, node script stale and a new external destination first seen in 24 h. Data-level alerts such as reputation hits are a follow-up.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| New `homelab-netmon` service | A fifth service with its own CI, image, deployment and DB duplicates data-service's purpose. The owner chose to revive data-service instead. |
| n8n workflows as collectors | Data and logic would sit in n8n's SQLite/exports, outside version-controlled code with tests. Idempotency and retention would be hard to guarantee. |
| Kubernetes CronJob scripts writing to Postgres | Splits collector logic and schema ownership across script images and the infra repo. Leaves no owner for the read API. |
| Prometheus as the store | Poor fit for per-IP and per-destination cardinality on arm64 Pis. It has 14 d retention and a 20 Gi PVC that already filled raspi4 once, and it cannot hold Cloudflare or login data. |
| Split storage (each producer keeps its own data) | Directly violates the owner's central-data principle. It needs N retention policies, N backup paths and N APIs for one page. |

## Consequences

**Positive**

- One schema, one retention policy, one backup target and one API for the whole Epic. That makes maintenance and audit ("where does this number come from?") straightforward.
- Network history outlives the Cloudflare Free-plan windows (7 d / 24 h) and Prometheus' 14 d.
- data-service gets a real first deployable scope, and the NM-0 bootstrap is reused by the sensor-history issues.
- auth-service stays free of outbound runtime calls, because data-service pulls login events.

**Negative**

- data-service becomes a stateful Postgres owner. [`052-architecture-target.md`](../052-architecture-target.md) says "Database: PostgreSQL — none" for data-service and must be amended by the NM-0 infrastructure PR (done, homelab#126).
- A new repo must be bootstrapped with CI, image, Flux and secrets before any network data flows (NM-0).
- data-service (namespace `apps`) depends on Prometheus in namespace `monitoring` for instant queries (spec `060` §4.6). This is a **named exception** to infrastructure's code-style convention against cross-namespace dependencies from `apps`, following the precedent furchert-ch's own Prometheus reads already set (`furchert-ch/src/lib/metrics/prometheus.ts`).
- auth-service gains a small transport-buffer table and one read endpoint (NM-4). That is a bounded exception to "producers do not keep": a hard 72 h TTL with no analytics — though that 72 h window can still surface in a nightly `scripts/backup-app-data.sh` dump or Longhorn snapshot taken while a row is still live, which is documented as an accepted exposure in spec `060` §10.
- IP addresses are personal data. The store is admin-only and has retention limits (spec 060 §10).

## References

- [`docs/060-network-monitoring.md`](../060-network-monitoring.md) — the cross-repo contract implementing this ADR
- ADR 0001 (parent workspace, `docs/adr/0001-schedules-ownership-and-data-plane.md`) — schedules ownership; original data-service scope
- [`052-architecture-target.md`](../052-architecture-target.md) — data-service section (to amend in NM-0), port `:8082` reservation
- `doemefu/homelab#114` — Epic; `doemefu/homelab-data-service#1` — sensor-history Epic (shares the NM-0 bootstrap)

## Amendment 2026-11-08 (WA-0, homelab#349): browser push write path

Web analytics (Epic `doemefu/homelab#348`, contract [`100-web-analytics.md`](../100-web-analytics.md)) extends decision 2: the same database `data_service` gets a second schema, `webanalytics`, with data-service as its single owner. Decisions 1 and 2 (one store, one owner) apply unchanged.

Decision 3 (data-service pulls from every producer) does not fit browser events: there is no producer endpoint to pull from. As a recorded exception, furchert-ch pushes events to data-service (`POST /api/webanalytics/events`) with a `client_credentials` token carrying scope `analytics:write`. Delivery is at-most-once; furchert-ch keeps only a bounded in-memory forward queue as transport, never as a store. Reads use scope `analytics:read`. Decision 4 is unchanged: furchert-ch reads only through data-service's REST API, server-side.
