# M6 Design: App Infrastructure + Home Assistant

**Date:** 2026-03-31
**Status:** Approved

---

## Scope

Two new playbooks completing Milestone 6:

| Playbook | Namespace | Services |
|---|---|---|
| `50_apps_infra.yml` | `apps` | PostgreSQL 17, InfluxDB 2, Mosquitto 2 |
| `51_homeassistant.yml` | `homeassistant` | Home Assistant |

---

## 1. Architecture

### 50_apps_infra.yml — Shared App Infrastructure

Three services deployed via Helm into the `apps` namespace. All use Longhorn PVCs for persistence. No external ingress (LAN-only). Credentials injected from `all.sops.yml` via `values:` dict in the playbook (same pattern as `grafana.adminPassword` in `40_platform.yml`).

**Services:**

| Service | Helm Chart | Namespace | PVC Size | Mount Path |
|---|---|---|---|---|
| PostgreSQL 17 | `bitnami/postgresql` | `apps` | 5Gi | `/bitnami/postgresql` |
| InfluxDB 2 | `influxdata/influxdb2` | `apps` | 10Gi | `/var/lib/influxdbv2` |
| Mosquitto 2 | `k8s-at-home/mosquitto` (primary candidate; verify availability during research) | `apps` | 1Gi | `/mosquitto/data` |

**Secrets (to add to `all.sops.yml`):**
- `postgresql_password`
- `postgresql_replication_password`
- `influxdb_admin_password`
- `influxdb_admin_token`

Mosquitto: anonymous auth (LAN-only, no external exposure).

### 51_homeassistant.yml — Home Assistant

Home Assistant deployed via Helm (`pajikos/home-assistant`) into a dedicated `homeassistant` namespace.

**Key configuration:**
- `hostNetwork: true` — required for mDNS/multicast auto-discovery of LAN devices
- StatefulSet with Longhorn PVC (5Gi) mounted at `/config`
- No USB device passthrough (no dongles)
- No Ingress, no Cloudflare Tunnel — LAN access only via `http://<node-ip>:8123`
- No node affinity — pod can float freely across cluster nodes

**Mosquitto integration:**
HA connects to Mosquitto cross-namespace: `mosquitto.apps.svc.cluster.local:1883`
Anonymous auth (matches Mosquitto M6 config).

---

## 2. Playbook Structure

Both playbooks follow the established pattern from `40_platform.yml`:

```yaml
hosts: k3s_server
gather_facts: false
run_once: true
delegate_to: localhost
```

**`50_apps_infra.yml` task order:**
1. Create `apps` namespace
2. Add Helm repos (bitnami, influxdata, community)
3. Deploy PostgreSQL (values-file + secrets from SOPS)
4. Deploy InfluxDB 2 (values-file + secrets from SOPS)
5. Deploy Mosquitto (values-file, anonymous)

**`51_homeassistant.yml` task order:**
1. Create `homeassistant` namespace
2. Add pajikos Helm repo
3. Deploy Home Assistant (values-file, `hostNetwork: true`)

---

## 3. Values Files

New files in `cluster/values/`:
- `cluster/values/postgresql.yaml`
- `cluster/values/influxdb2.yaml`
- `cluster/values/mosquitto.yaml`
- `cluster/values/home-assistant.yaml`

All chart versions pinned (no `latest`).

---

## 4. Validation

| Service | Validation Command |
|---|---|
| PostgreSQL | `kubectl exec -n apps deploy/postgresql -- psql -U postgres -c "\l"` |
| InfluxDB 2 | `kubectl port-forward -n apps svc/influxdb2 8086:8086` → UI at localhost:8086 |
| Mosquitto | `mosquitto_pub/sub -h <node-ip> -p 1883 -t test` from LAN |
| Home Assistant | Browser → `http://<node-ip>:8123` → onboarding wizard |

Idempotency: each playbook run twice → `changed=0` on second run.

---

## 5. Post-M6 Deferred Items

These are explicitly out of scope for M6 and should be tackled together as a bundle:

- **`mqtt.furchert.ch` WSS endpoint** — Expose Mosquitto externally via Cloudflare Tunnel (same pattern as `grafana.furchert.ch`)
- **MQTT authentication** — Username/password via Mosquitto passwordfile (Kubernetes Secret)

Both deferred together: there is no value in adding auth without external exposure, and no value in external exposure without auth.

---

## 6. Decisions & Rejected Alternatives

| Topic | Decision | Rejected Alternative | Reason |
|---|---|---|---|
| HA deployment tool | Helm (`pajikos/home-assistant`) | Kustomize (guide approach) | Consistent with repo tooling; no new tool introduced |
| HA deployment tool | Helm | Raw manifests via `k8s` module | Less maintenance overhead, pinned versioning |
| HA namespace | `homeassistant` (own) | `apps` | Matches own playbook; HA is not shared infra |
| HA networking | `hostNetwork: true` | Regular Pod networking | mDNS/multicast requires host network |
| HA external access | LAN-only | Cloudflare Tunnel | User preference; simpler for M6 |
| Mosquitto auth | Anonymous | Username/password | LAN-only, no external exposure; deferred post-M6 |
| Mosquitto placement | `apps` namespace | `homeassistant` namespace | Shared infra; other services may use it |
| Node affinity | None (float freely) | Pin to specific node | No USB dongles — no hardware dependency |
