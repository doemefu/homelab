# SPEC — MQTT Broker and Device Authentication

> Mosquitto requires credentials from every client and enforces per-user topic ACLs. Devices authenticate with
> static per-device passwords on the official `eclipse-mosquitto` image (route 2b).

**Status:** revision 2, accepted (owner decision 2026-11-12, homelab#122). Revision 1 (draft) proposed JWT
authentication through the `mosquitto-go-auth` plugin; it is superseded (see "Decision").
**Tracking:** homelab#122 (broker, phases 0–3) · homelab#377 (firmware, Terra1/Terra2) · homelab#378 (TLS on
8883) · homelab#379 (IoT network segmentation) · homelab#380 (archived mosquitto-exporter)
**Implementation:** `infra/playbooks/50_apps_infra.yml` (Mosquitto section), `infra/playbooks/files/mosquitto-passwd.py`
**Runbook:** `DEPLOYMENT.md` "Mosquitto broker access (homelab#122)"

---

## 1. Goal

- No anonymous client reaches the broker.
- Each client is a named broker user and may publish and subscribe only within its own topics.
- The local control loop (device ↔ broker ↔ device-service) keeps working without the internet and without
  auth-service.

---

## 2. Decision

**Route 2b: static per-device passwords** in Mosquitto's built-in `password_file`, with an `acl_file`, on the
official `eclipse-mosquitto:2.1.2-alpine` image (digest-pinned in the playbook). No auth plugin.

**Rejected: route 2a, JWT through `iegomez/mosquitto-go-auth`.** Revision 1 assumed the plugin validates
RS256 tokens against auth-service's JWKS. In plugin release 3.0.0 it does not:

- Its `jwt` backend verifies only HMAC shared-secret tokens and has no JWKS option. The option names in
  revision 1 do not exist in the plugin.
- In every `jwt` mode the token travels as the MQTT **username**, not the password.
- The project is archived (no further releases), and its only image for Mosquitto 2 ships Mosquitto 2.0.18.
  That is a downgrade from 2.1.2 that loses later fixes, including one for SUBSCRIBE by authenticated clients.
- A working JWT route would need the plugin's `http` backend plus a verifier service in device-service on an
  unrouted port. Device CONNECT would then depend on device-service, Postgres and, for token refresh, on the
  internet path to `auth.furchert.ch`.

Consequences of 2b:

- Revocation is immediate: remove the user's line or change its password, then run playbook 50. The broker
  restarts and every session ends. Under JWT an issued token stays valid until it expires.
- Rotation means reflashing the device (§5).
- **Dormant OAuth device clients.** device-service `POST /devices` still provisions an auth-service
  `client_credentials` client per device (device-service#62). Under 2b these clients are not used by the
  broker. They stay registered and reserved for a possible later token route. Their tokens (`aud` = the
  device id, no `role`) are rejected by every resource server, so they grant nothing today. If 2b becomes
  permanent, device-service may stop provisioning them (a device-service and spec change).
- Devices never call the device-service REST API or `/ws`. Both require an ADMIN token issued to
  `furchert-ch` (device-service#124), and the tunnel answers 404 for the REST paths (homelab#121).

---

## 3. Broker

### 3.1 Configuration (`mosquitto.conf`)

```conf
listener 1883
use_username_as_clientid true
allow_anonymous false
password_file /mosquitto/auth/passwd
acl_file /mosquitto/auth/acl
persistence true
persistence_location /mosquitto/data/
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information
```

- `use_username_as_clientid true` (per listener): the broker replaces every client's id with its username, so
  a client cannot take over another client's session by reusing its id. `backend` therefore runs as client
  `backend`, whatever id device-service sends; device-service uses clean sessions, so nothing depends on it.
  Consequence: each broker user holds at most one connection; a second CONNECT with the same username
  replaces the first. That matches every client today (device-service runs one replica with `maxSurge: 0`,
  device-service#113; one exporter, one Home Assistant, one ESP32 per device). Never use the `backend` or
  `exporter` credentials for manual tests while those clients run: the test would disconnect them.
- One `log_type` per line: Mosquitto 2.1 applies only the first value of a multi-value `log_type` line.
  `notice` carries the connect, disconnect and "not authorised" lines.

`password_file` and `acl_file` are deprecated in Mosquitto 2.1 in favour of the `password-file` and
`acl-file` plugins, and remain supported until 3.0. Moving to the plugins is a follow-up before any 3.x
upgrade.

### 3.2 Users

| User | Client | Session id (= username, §3.1) | SOPS variable |
|---|---|---|---|
| `backend` | device-service (sends client id `device-service`) | `backend` | `device_service_mqtt_password` (also written to `device-service-secrets/mqtt-password` by playbook 59) |
| `exporter` | mosquitto-exporter | `exporter` | `mosquitto_exporter_mqtt_password` |
| `homeassistant` | Home Assistant (optional, only if its MQTT integration is used) | `homeassistant` | `mosquitto_homeassistant_mqtt_password` |
| `<device id>` (`terra1`, `terra2`) | one ESP32 each | the device id | `mosquitto_<id>_mqtt_password` (`-` in the id becomes `_`) |

Device ids come from the playbook list `mosquitto_devices` and must match `[a-z0-9-]{3,32}`, the
device-service registration rule. The names `backend`, `exporter` and `homeassistant` are reserved.
device-service parses telemetry only from `terra<N>` topics (`MqttMessageParser`), so new devices use ids
of the form `terra<N>` until that parser changes. Every
password is at least 24 characters, single line, and unique (`openssl rand -base64 32`). Playbook 50 asserts
all of this.

### 3.3 Password hashes

`password_file` lines use Mosquitto's `$7$` format: `<user>:$7$<iterations>$<base64 salt>$<base64 hash>`,
PBKDF2-HMAC-SHA512 with 100 000 iterations and a 64-byte hash. `files/mosquitto-passwd.py` computes them
on the Ansible controller. It reads the passwords on stdin, never from argv. The 12-byte salt is
PBKDF2-HMAC-SHA512 of the password and `"mosquitto-passwd-salt:" + username`, at the same 100 000
iterations. That makes it deterministic, so a second playbook run renders the same file and changes
nothing, and because the salt costs as much as the hash, it is no shortcut for testing a password guess.
Mosquitto 2.1 accepts only 12- or 64-byte salts. Built-in
`password_file` does not accept bcrypt or crypt `$6$` hashes.

### 3.4 ACL

```conf
user backend
topic read terra1/#            # one line per entry of mosquitto_devices
topic read terra2/#
topic readwrite terraGeneral/#
topic write +/+/man
topic readwrite javaBackend/mqtt/status

user exporter
topic read $SYS/#

pattern readwrite %u/#
pattern read terraGeneral/#
```

The two `pattern` lines apply to every user. They give each device exactly its own subtree `<id>/#`
(read and write) and read access to `terraGeneral/#`. A device cannot publish to another device's topics
or to `terraGeneral/#`. `homeassistant` gets `homeassistant/#`, its discovery prefix.

### 3.5 Exposure

| Phase | Service | Reachable from |
|---|---|---|
| 0 (homelab#122) | `ClusterIP` (`mosquitto_service_type`); UFW rule for 1883 deleted | in-cluster clients only |
| 3, at firmware cutover | `LoadBalancer` with `loadBalancerSourceRanges` limited to the ESP32 `/32` addresses | the two devices and the cluster |

Until TLS on 8883 exists (homelab#378), passwords cross the LAN in cleartext. The source-range restriction
and a separate IoT network (homelab#379) bound that exposure. Never open 1883 to the whole LAN or beyond.

---

## 4. Device contract (firmware, homelab#377)

Applies to every device, Terra1 and Terra2 first.

- **Protocol:** MQTT 3.1.1 to `mqtt://<broker LB IP>:1883`. Keep host, port and an optional CA certificate
  configurable for the later TLS listener (8883).
- **Identity:** username = client id = the device id, exactly as registered (e.g. `terra1`). The broker
  enforces this (`use_username_as_clientid`, §3.1): whatever id the device sends, its session is `<id>`.
- **Password:** the device's own password from §3.2, provisioned at flash time and stored in NVS. Never in
  source code, the repository, logs or serial output.
- **Publish only under `<id>/`:**
  - `<id>/SHT35/data`: JSON `{"Temperature": …, "Humidity": …}`
  - `<id>/mqtt/status`, `<id>/light`, `<id>/nightLight`, `<id>/rain`
- **Subscribe to** `<id>/+/man` (manual commands, payload `{"<Field>State": n}`) and
  `terraGeneral/+/schedule` (schedules). Never publish to `terraGeneral/#`.
- **Last will:** `<id>/mqtt/status`, retained, QoS 1.
- **Refused CONNECT** (return codes 4 bad credentials, 5 not authorized): log it and retry with exponential
  backoff up to 5 minutes. No tight reconnect loop.
- **No REST or WebSocket** calls to device-service. Devices talk MQTT only.

---

## 5. Operations

**Add a device** (owner):
1. Pick the id: `terra<N>` (§3.2), not a reserved name.
2. SOPS: `mosquitto_<id>_mqtt_password` (`openssl rand -base64 32`).
3. Playbook 50: add the id to `mosquitto_devices` (pull request), merge, then
   `ansible-playbook infra/playbooks/50_apps_infra.yml`. The backend ACL line `topic read <id>/#` is
   generated from the same list.
4. device-service: add `<id>/#` to `app.mqtt.topics` (pull request in that repo). Its device row is created
   on the first message, or explicitly through `POST /devices` (which also provisions the dormant OAuth
   client, §2).
5. Flash the device with id and password.
6. Phase 3: add the device's `/32` to the LoadBalancer source ranges.

**Rotate a device password:** new SOPS value → playbook 50 → reflash the device. The old password stops
working when the broker restarts.

**Revoke a device:** remove the id from `mosquitto_devices` (or rotate its password without reflashing),
then run playbook 50. Effective immediately. The id may stay in device-service's `app.mqtt.topics` and its
device row; that is harmless, since no client can publish under it any more.

**Rotate `backend`:** vault → playbook 50 → playbook 59 → `kubectl -n apps delete pod -l app=device-service`
(device-service reads the password only at start).

**Rollback** to anonymous access: `ansible-playbook infra/playbooks/50_apps_infra.yml -e mqtt_auth_enabled=false`
(same image, no data migration). Only while the Service is `ClusterIP`.

---

## 6. Acceptance

- Anonymous CONNECT and a wrong password are refused ("not authorised").
- `backend` subscribes to every device subtree and `terraGeneral/#`, and publishes commands and schedules.
- `exporter` reads `$SYS/#`; the metric `broker_connection_up` is 1.
- Device `terra1` publishes to `terra1/SHT35/data` and receives `terra1/+/man` and `terraGeneral/+/schedule`.
  Its publishes to `terra2/#` and `terraGeneral/#` are not delivered.
- A second run of playbook 50 reports no change for the Mosquitto tasks.

Tested before rollout against a local `eclipse-mosquitto:2.1.2-alpine` container with the generated files
(homelab#122 phase 1 pull request).

---

## 7. Out of scope

- TLS listener on 8883 (homelab#378).
- A token-based device route. If ever adopted, its verifier must reject ID tokens (`docs/fleet-invariants.md`,
  INV-LOGOUT-1) and run on a port the tunnel never routes.
- WebSockets for browser MQTT clients (the frontend uses STOMP on device-service).
- Replacing the archived mosquitto-exporter (homelab#380).
- Migrating to another broker.

---

## 8. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Passwords readable on the LAN (no TLS yet) | medium | medium | Phase 3 `/32` source ranges; TLS (homelab#378); IoT network (homelab#379) |
| A device password leaks from flash | low | low–medium | ACL limits it to the device's own subtree; revoke by rotating (§5) |
| A client reuses another client's id to kick its session (e.g. with a password leaked from a device) | low | medium | `use_username_as_clientid true` (§3.1): the broker sets every client id to the username, so a device user can only replace its own session; revoke the device (§5) |
| Wrong vault value locks device-service out | low | medium | Rotation order in §5; rollback with `mqtt_auth_enabled=false` |
| Mosquitto 3.0 removes `password_file` / `acl_file` | certain on 3.0 | medium | Move to the `password-file` / `acl-file` plugins before upgrading |
