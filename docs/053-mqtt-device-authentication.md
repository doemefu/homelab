# SPEC — MQTT Device Authentication via JWT

> Replace Mosquitto's `allow_anonymous true` with JWT-based authentication and per-device topic ACLs, using JWKS from auth-service.

**Status:** draft
**Cross-references:**
- [`homelab-auth-service` › `docs/SPEC-iot-device-clients.md`](https://github.com/doemefu/homelab-auth-service/blob/main/docs/SPEC-iot-device-clients.md) — token issuer
- [`homelab-device-service` › `SPEC-device-registration.md`](https://github.com/doemefu/homelab-device-service/blob/main/SPEC-device-registration.md) — orchestrator that provisions device clients

---

## Goal

Devices authenticate to Mosquitto using a JWT (received as the MQTT password during `CONNECT`). Mosquitto validates the JWT signature against auth-service's JWKS endpoint and enforces topic-level ACLs based on the `device_id` claim.

This resolves the post-M6 task tracked in `.claude/memory/project_post_m6_items.md` (auth on Mosquitto).

---

## Current state

See `infra/playbooks/50_apps_infra.yml` lines 205–310:

- `eclipse-mosquitto:2.1.2-alpine` (digest-pinned since #57 — see the mosquitto container's
  `image:` line in the playbook) deployed with `allow_anonymous true`.
- Single shared `backend` MQTT user **planned but not yet enforced** — devices and device-service all connect anonymously today.
- Service exposed as `LoadBalancer` on port 1883.
- ACL not configured. Persistence in `mosquitto-data` PVC.

The base `eclipse-mosquitto` image has no JWT support — a plugin is required.

---

## Required changes

### 1. Pick a JWT-capable Mosquitto image

**Decision needed in plan review** between two candidates:

| Option | Pros | Cons |
|--------|------|------|
| [`iegomez/mosquitto-go-auth`](https://github.com/iegomez/mosquitto-go-auth) (custom image) | Active, multi-arch (`arm64` + `amd64`), supports JWKS via `jwt` backend with `mode=remote`+`local`, ACL via local file or DB | Not an official image — pin to specific tag; rebuild from source if compromise concerns |
| Custom Dockerfile FROM `eclipse-mosquitto:2.1.2-alpine` + compile [`mosquitto-jwt-auth`](https://github.com/wiomoc/mosquitto-jwt-auth) | Official base, smaller, focused | More maintenance — rebuild on every Mosquitto patch release |

**Recommended:** `iegomez/mosquitto-go-auth:3.0.0` (or latest pinned at plan time). Multi-arch is critical (raspi5 = arm64, mba1 = amd64). Verify image manifest with `docker manifest inspect` before committing the tag.

### 2. Replace deployment image + config

In `50_apps_infra.yml`, change the mosquitto container's `image:` line (now digest-pinned,
`repo:tag@sha256:...` — see CONTRIBUTING.md "Digest-Pinned Platform Images", #57) to the
chosen plugin image (with its own freshly-resolved digest, per that same procedure). Add
`MOSQUITTO_GO_AUTH_*` env vars or a richer config (plugin image expects an extended
`mosquitto.conf`).

Updated `mosquitto.conf` (in the `mosquitto-config` ConfigMap):

```conf
listener 1883
allow_anonymous false

# Plugin
auth_plugin /mosquitto/go-auth.so

# JWT backend — validates token against auth-service JWKS
auth_opt_backends jwt
auth_opt_jwt_mode remote
auth_opt_jwt_params_mode json
auth_opt_jwt_response_mode status
auth_opt_jwt_remote_host auth-service.apps.svc.cluster.local
auth_opt_jwt_remote_port 8080
auth_opt_jwt_remote_with_tls false

# JWKS — local signature validation (avoids per-CONNECT HTTP call)
auth_opt_jwt_parse_token true
auth_opt_jwt_secret_keys_url http://auth-service.apps.svc.cluster.local:8080/oauth2/jwks
auth_opt_jwt_userfield Subject     # Or use a custom claim once §3 lands
auth_opt_jwt_skip_user_expiration false

# ACL — from JWT claim `device_id`
auth_opt_jwt_aclquery_use_topic true
auth_opt_acl_jwt_claim device_id
auth_opt_acl_pattern readwrite %u/#
auth_opt_acl_pattern read       terraGeneral/#

# Logging
log_dest stdout
log_type error warning notice information
persistence true
persistence_location /mosquitto/data/
```

> Exact option names depend on the plugin version chosen — verify against plugin docs during plan phase. The pattern above is correct in spirit: `%u` expands to the JWT user/claim, giving each device write access only to its own subtree.

**JWT claim format the plugin must parse** (produced by auth-service today, not negotiable on this side):

- `device_id` — string, single value, equals the MQTT username; use for ACL pattern expansion (`%u`)
- `scope` — single string, space-separated values (`"mqtt:pub mqtt:sub"`) per RFC 6749 §3.3, not a JSON array; the plugin must split on whitespace if scope-based authorization is enabled
- `iss`, `sub`, `aud`, `exp` — standard JWT; `iss` matches `app.oidc.issuer` from auth-service (`https://auth.furchert.ch` in prod)

Confirm the chosen plugin handles space-separated `scope` correctly before committing the plugin choice.

### 3. JWKS endpoint reachability + cache

- Mosquitto pod calls `http://auth-service.apps.svc.cluster.local:8080/oauth2/jwks` — internal-cluster only, no TLS required for this hop.
- JWKS is cached by the plugin. Default TTL is typically 5–10 min — acceptable. Means revocation lag after `DELETE /api/v1/clients/{id}` ≈ token TTL (1h) regardless of cache, since deletion doesn't rotate the key.
- If faster revocation needed: shorten device access-token TTL in auth-service (already a config knob).

### 4. Backend service MQTT user

device-service still needs to publish (control commands, scheduler) and subscribe (all `terra#/#` topics). Two options:

- **Option A (preferred):** device-service requests a `client_credentials` JWT from auth-service at startup with a special `device_id=backend` claim (auth-service grants this to the `device-service` SSO client when `client_credentials` is added — see auth-service spec §4). Mosquitto ACL grants `backend` read/write on everything.
- **Option B:** keep one static password for device-service, configured via `mosquitto_passwd`-style file alongside the JWT plugin (multi-backend mode: `auth_opt_backends jwt files`). Simpler but introduces a second auth path to maintain.

**Decision: Option A.** Keep one auth mechanism (JWT). Add ACL pattern:

```conf
auth_opt_acl_pattern_backend readwrite #
```

Applied only when `device_id = backend`. The plugin syntax varies — confirm in plan.

### 5. Network exposure

Currently `type: LoadBalancer` exposes port 1883 cluster-externally. After this change, anonymous connects are rejected, but **plaintext JWT-in-password over port 1883 is still TLS-less**. For a homelab LAN this is acceptable; for any deployment where 1883 is reachable from beyond the LAN, add `listener 8883` with TLS (cert-manager-issued certificate).

**Out of scope for this spec.** Note as a follow-up: `cert-manager`-issued cert + TLS listener.

**Mandatory until TLS is enabled:** because the JWT travels in the MQTT password in
cleartext over port 1883, the broker must not be reachable beyond the trusted LAN. Before
rollout, restrict the `LoadBalancer` to LAN ranges (`spec.loadBalancerSourceRanges`) or make
the Service internal-only / firewall the port — this is a hard guard, not a follow-up note.

### 6. Idempotency + rollout

- Mosquitto Deployment uses `strategy: Recreate` (RWO PVC). Pod restart picks up new ConfigMap automatically (Mosquitto rereads config on SIGHUP, but K8s replaces the pod — fine).
- During cutover: existing devices using anonymous auth will lose connection until they're flashed with new credentials. Coordinate with `device-service` PR that registers existing devices via `POST /devices` first.

### 7. Documentation

Update:

- `OPERATIONS.md` — new runbook: "Rotate device credentials" (delete client → re-register → reflash).
- `APPS.md` — Mosquitto auth section: how to obtain device credentials (call device-service `POST /devices`).
- `.claude/memory/project_post_m6_items.md` — mark Mosquitto auth as resolved when shipped.

### 8. Tests (Ansible / validation)

- `ansible-lint infra/` passes.
- `ansible-playbook infra/playbooks/50_apps_infra.yml --check --diff` shows only Mosquitto ConfigMap + Deployment diffs.
- Idempotency: second run produces zero changes.
- Manual integration (recorded in worklog):
  1. `curl auth-service .../oauth2/token` with a registered device → JWT.
  2. `mosquitto_pub -h <node-ip> -p 1883 -u terra1 -P <jwt> -t terra1/test -m hello` succeeds.
  3. Same command with `-t terra2/test` is rejected (ACL).
  4. Anonymous `mosquitto_pub` (no `-u`) is rejected (`allow_anonymous false`).
  5. After `DELETE /api/v1/clients/terra1` + waiting one token TTL, step 2 starts failing.

---

## Out of scope

- TLS listener on port 8883 (follow-up — see §5).
- WebSockets-over-TLS for browser MQTT clients (frontend uses STOMP/WebSocket on device-service, not Mosquitto directly).
- mTLS-based device auth as an alternative — explicitly rejected: JWT is consistent with the rest of the auth stack and supports dynamic registration without per-device cert provisioning.
- Migrating to EMQX or another broker.

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Plugin image broken on arm64 | medium | high (raspi5 = arm64 control plane) | Verify multi-arch manifest before committing the image tag; test rollout on a dev namespace first |
| JWKS endpoint unreachable at Mosquitto startup | low | high (all auth fails) | Mosquitto starts anyway; plugin retries on each CONNECT until JWKS reachable. Add Prometheus alert: `mosquitto_auth_failures_total{reason="jwks"}` |
| Revocation lag (up to 1h after `DELETE`) | high | low | Document; shorten token TTL if needed |
| Existing devices fail after cutover | high | medium | Schedule rollout window; pre-register all current devices via device-service before flipping `allow_anonymous` |
| Plugin config syntax differs from spec above | high | low | Validate exact options against plugin docs during plan phase; this spec captures intent, not final syntax |

---

## Acceptance

- `kubectl exec -n apps deploy/mosquitto -- cat /mosquitto/config/mosquitto.conf` shows `allow_anonymous false` + JWT plugin block.
- An ESP32 flashed with `clientId + clientSecret` for `terra1` connects, publishes to `terra1/SHT35/data`, and is rejected if it tries to publish to `terra2/#`.
- Anonymous connects from inside the cluster network are rejected.
- device-service continues to subscribe to all `terra#/#` topics using its own JWT.
- `ansible-playbook --check --diff` second run shows zero changes.
