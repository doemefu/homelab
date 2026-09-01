# Target Architecture — Microservices

> Amended 2026-09-01 per ADR 0001 (parent `docs/adr/0001-schedules-ownership-and-data-plane.md`): schedules ownership -> device-service.

This document describes the target architecture for the Terrarium IoT application after the migration from the legacy monolith.

---

## Overview

The monolith is replaced by **3 focused Java microservices** running on a K3s cluster (Raspberry Pi), backed by PostgreSQL, InfluxDB, and Mosquitto. Each service has a clear domain boundary, its own test suite, and can be deployed independently.

**Stack:** Java 25, Spring Boot 4.0.5, PostgreSQL 17, InfluxDB 2, Mosquitto 2

Each service lives in its own GitHub repository and builds its own multi-arch Docker image. Infrastructure services (PostgreSQL, InfluxDB, Mosquitto) are managed by the IaC repo, not this project.

---

## Architecture Diagram

```
Internet
    |
    v
+-------------------+
| Cloudflare Tunnel |  (TLS terminated at edge)
+--------+----------+
         |
+--------+-------------------------------------------+
| K3s Cluster (raspi5 + raspi4)  namespace: apps     |
|                                                    |
|  +-------------+  +---------------+  +----------+  |
|  | auth-service|  | device-service|  |  data-   |  |
|  | :8080       |  | :8081         |  | service  |  |
|  | (own repo)  |  | (own repo)    |  | :8082    |  |
|  +------+------+  +--+----+---+---+  | (own repo)|  |
|         |            |    |   |      +---+--+---+  |
|         v            v    |   v          |  |      |
|    +----------+  +--------+  +--------+  |  |      |
|    |PostgreSQL|  |Mosquitto|  |InfluxDB|<-+  |      |
|    | :5432    |  | :1883   |  | :8086  |<----+      |
|    |(IaC repo)|  |(IaC repo)| |(IaC repo)|          |
|    +----------+  +----+----+  +--------+            |
+------------------------+---------------------------+
                         |
              +----------+----------+
              |                     |
         +----+-----+         +-----+----+
         |  Terra1  |         |  Terra2  |
         |  (ESP32) |         |  (ESP32) |
         +----------+         +----------+
    |     +---------+  write |  |(ESP32)| |(ESP32)|
    |                        |  +-------+ +-------+
    +--- REST ----> api-service
    +--- WebSocket --> device-service
         (STOMP /ws)

+-----------------------------------------------------+
|                    data-service :8082                |
|  - InfluxDB queries (historical data)               |
|  - JWT validation via JWKS from auth-service         |
+-----------------------------------------------------+
         |
         v
    +---------+
    |InfluxDB |
    | (read)  |
    +---------+
```

---

## Service Boundaries

### auth-service

**Domain:** Identity and access management.

**Responsibilities:**
- User CRUD (create, read, update, delete, password reset)
- JWT token issuance (`POST /auth/login` -> signed JWT)
- JWT token refresh (`POST /auth/refresh`)
- JWKS endpoint (`GET /auth/jwks`) for other services to validate tokens
- Role-based access control (USER, ADMIN)

**Does NOT:**
- Talk to MQTT, InfluxDB, or any IoT concerns
- Call other services at runtime (self-contained)

**Database:** PostgreSQL — `users` table (owns it)

**Key design decision:** Uses **jjwt library with RSA key pair** instead of Spring Authorization Server. The RSA public key is exposed via a JWKS endpoint. Other services validate tokens locally using the public key — no runtime dependency on auth-service for token validation.

### device-service

**Domain:** Real-time IoT device management.

**Responsibilities:**
- MQTT subscriber (all `terra#/#` topics)
- Device state persistence in PostgreSQL (`devices` table)
- InfluxDB writer (sensor data on every MQTT message)
- Scheduled MQTT commands (light, nightlight, rain automation)
- WebSocket broadcast (STOMP, live device state to frontend)
- Device control REST endpoint (manual toggle -> MQTT publish)
- Schedules REST CRUD (planned: device-service#41)

**Does NOT:**
- Handle user authentication or user CRUD
- Query historical InfluxDB data for charts

**Database:** PostgreSQL — owns `devices` and `schedules` tables
**InfluxDB:** Write-only (sensor measurements)
**MQTT:** Full client (subscribe + publish)

**Key design decision:** This is a long-running, stateful service. It maintains persistent MQTT connections and in-process scheduled tasks. Restarting this service briefly disconnects from MQTT but reconnects automatically. The scheduling engine reconciles from its own `schedules` table on a periodic fixed delay (`app.scheduler.poll-interval`, shipped at 60s); once the CRUD API lands (device-service#41), CRUD writes will re-register the affected task directly in-process — no cross-service polling or HTTP notification needed now that device-service owns both the table and the REST API. The periodic reconciliation stays in place as a fallback safety net for out-of-band DB edits, not as the primary change-propagation path.

### data-service

**Domain:** Historical sensor data retrieval (near-term).

**Responsibilities:**
- InfluxDB queries (historical temperature, humidity, device status)
- JWT validation for all endpoints

**Does NOT:**
- Connect to MQTT (current; see target picture)
- Write to InfluxDB (current; see target picture)
- Manage users or issue tokens

**Database:** PostgreSQL — none (no owned tables; stateless historical-query service)
**InfluxDB:** Read-only (queries)

**Key design decision (superseded 2026-09-01, ADR 0001):** Schedule CRUD does not live here. Schedules are a device-management concern, tightly coupled to the in-process scheduling engine that executes them, so the `schedules` table, its CRUD REST API, and execution all live in device-service. This supersedes the original design (schedule CRUD in data-service) described in earlier drafts of this document. data-service's near-term scope is limited to read-only historical InfluxDB queries.

**Target picture (later step, ADR 0001):** data-service is intended to eventually own sensor-data ingestion and processing (MQTT -> InfluxDB writes), moving that responsibility out of device-service. That is an explicit, separate decision not yet made — until then, ingestion stays in device-service and the "Does NOT" items above hold.

---

## Inter-Service Communication

```
+---------------+          +----------------+          +--------------+
| auth-service  |          | device-service |          | data-service |
|               |          |                |          |              |
| JWKS endpoint |<---------|JWT validation  |          |              |
| (public key)  |  (HTTP   | (startup only) |          |              |
|               |   once)  |                |          |              |
+---------------+          +-------+--------+          +--------------+
                                   |
                                   | owns
                                   v
                           +-------+--------+
                           | PostgreSQL     |
                           | devices table  |
                           | schedules table|
                           +----------------+
```

**Communication pattern: Shared database; no synchronous service-to-service calls on request paths.**

- auth-service is fully self-contained. Other services only fetch its JWKS once at startup (or on key rotation) to get the RSA public key — the only cross-service HTTP call in this architecture, and it happens outside the request path.
- device-service owns both the `devices` and `schedules` tables; it owns schedule execution end-to-end (ADR 0001, 2026-09-01).
- No message broker between services (MQTT is for device communication only).
- This is intentionally simple for a 3-service architecture. If the project grows, an event bus could replace the shared DB pattern.

---

## Authentication Flow

```
1. User submits credentials
   POST /auth/login { "username": "admin", "password": "secret" }

2. auth-service validates against users table (BCrypt)
   -> Issues JWT (signed with RSA private key)
   -> Issues refresh token (stored in DB or as signed JWT)
   -> Returns both as HTTP-only cookies or JSON body

3. Frontend stores access token (memory) + refresh token (HTTP-only cookie)

4. Frontend calls any service with Authorization: Bearer <jwt>

5. device-service / data-service validate JWT locally
   -> Fetch RSA public key from auth-service JWKS endpoint (cached)
   -> Verify signature + expiration
   -> Extract claims (username, role)
   -> No runtime call to auth-service needed

6. On token expiry: Frontend calls POST /auth/refresh
   -> auth-service issues new access token
```

---

## Database Schema

### PostgreSQL (shared instance, all services)

```sql
-- Owned by: auth-service
CREATE TABLE users (
    id              BIGSERIAL PRIMARY KEY,
    username        VARCHAR(50) NOT NULL UNIQUE,
    email           VARCHAR(100) NOT NULL UNIQUE,
    password_hash   VARCHAR(100) NOT NULL,         -- BCrypt
    role            VARCHAR(10) NOT NULL DEFAULT 'USER',  -- USER, ADMIN
    status          VARCHAR(10) NOT NULL DEFAULT 'ACTIVE', -- ACTIVE, INACTIVE, BANNED
    created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Owned by: auth-service (if using DB-backed refresh tokens)
CREATE TABLE refresh_tokens (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token           VARCHAR(500) NOT NULL UNIQUE,
    expires_at      TIMESTAMP NOT NULL,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Owned by: device-service (ADR 0001)
CREATE TABLE schedules (
    id              BIGSERIAL PRIMARY KEY,
    device_name     VARCHAR(50),
    field           VARCHAR(50),
    payload         TEXT,
    cron_expression VARCHAR(100),
    active          BOOLEAN DEFAULT TRUE
);

-- Owned by: device-service
CREATE TABLE devices (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(50) NOT NULL UNIQUE,   -- "terra1", "terra2"
    mqtt_online     BOOLEAN DEFAULT FALSE,
    temperature     DOUBLE PRECISION,
    humidity        DOUBLE PRECISION,
    light           VARCHAR(10),                    -- ON, OFF
    night_light     VARCHAR(10),                    -- ON, OFF (terra2 only)
    rain            VARCHAR(10),                    -- ON, OFF
    last_seen       TIMESTAMP
);
```

### InfluxDB

- **Bucket:** `iot-bucket`
- **Measurement:** `terrarium`
- **Tags:** `device` (terra1, terra2)
- **Fields:** `temperature` (float), `humidity` (float), `light` (int 0/1), `nightLight` (int 0/1), `rain` (int 0/1), `mqttState` (int 0/1)
- **Written by:** device-service (on every MQTT sensor message)
- **Read by:** data-service (historical queries, aggregated)

---

## MQTT Topic Structure

> **Note:** The MQTT topic structure can be redesigned for the new architecture. The structure below reflects the legacy system as a starting point. Final topic design will be decided during M2 (device-service).

### Device -> Broker (publish)

| Topic | Payload | Interval |
|-------|---------|----------|
| `terra{n}/SHT35/data` | `{"Temperature": 22.5, "Humidity": 65.0}` | 30s |
| `terra{n}/mqtt/status` | `{"MqttState": 1}` | On connect (retained) |
| `terra{n}/light` | `{"LightState": 1}` | On state change |
| `terra{n}/nightLight` | `{"NightLightState": 1}` | On state change (terra2) |
| `terra{n}/rain` | `{"RainState": 1}` | On state change |

### device-service -> Broker (publish)

| Topic | Payload | Trigger |
|-------|---------|---------|
| `terra{n}/{field}/man` | `{"{Field}State": 0\|1}` | Manual control from frontend |
| `terraGeneral/{field}/schedule` | `{"{Field}State": 0\|1}` | Scheduled task |
| `javaBackend/mqtt/status` | `{"MqttState": 0\|1}` | Service connect/disconnect |

### Mosquitto ACL (enforced)

| User | Permissions |
|------|------------|
| `terra1` | Publish: `terra1/#`. Subscribe: `terra1/#`, `terraGeneral/#` |
| `terra2` | Publish: `terra2/#`. Subscribe: `terra2/#`, `terraGeneral/#` |
| `backend` | Subscribe: `terra1/#`, `terra2/#`, `terraGeneral/#`. Publish: `terra1/*/man`, `terra2/*/man`, `terraGeneral/#`, `javaBackend/#` |

---

## REST API Overview

### auth-service (:8080)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/auth/login` | No | Authenticate, return JWT + refresh token |
| POST | `/auth/refresh` | Refresh token | Issue new access token |
| POST | `/auth/logout` | JWT | Invalidate refresh token |
| GET | `/auth/jwks` | No | RSA public key set for token validation |
| POST | `/users` | ADMIN | Create user |
| GET | `/users/{id}` | JWT | Get user by ID |
| PUT | `/users/{id}` | ADMIN | Update user |
| DELETE | `/users/{id}` | ADMIN | Delete user |
| POST | `/users/{id}/reset-password` | ADMIN or self | Reset password |

### device-service (:8081)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/devices` | JWT | List all devices with current state |
| GET | `/devices/{id}` | JWT | Single device state |
| POST | `/devices/{id}/control` | JWT | Send control command (-> MQTT publish) |
| WS | `/ws` | Optional | STOMP WebSocket, subscribe to `/topic/terrarium/{deviceId}` |
| GET | `/schedules` | JWT | List all schedules (planned: device-service#41) |
| POST | `/schedules` | ADMIN | Create schedule (planned: device-service#41) |
| PUT | `/schedules/{id}` | ADMIN | Update schedule (planned: device-service#41) |
| DELETE | `/schedules/{id}` | ADMIN | Delete schedule (planned: device-service#41) |

### data-service (:8082)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/data/measurements` | JWT | Historical sensor data (params: device, period) |
| GET | `/data/devices/{id}/status` | JWT | Device online/offline history |

---

## Deployment Model

### Local Development

Services run locally via `./mvnw spring-boot:run` and connect to infrastructure services in the K3s cluster via `kubectl port-forward` or direct node IP. No Docker Compose.

```bash
# Port-forward cluster services for local dev
kubectl port-forward -n apps svc/postgres 5432:5432 &
kubectl port-forward -n apps svc/influxdb2 8086:80 &
kubectl port-forward -n apps svc/mosquitto 1883:1883 &

# Run service locally
cd terrarium-auth-service
./mvnw spring-boot:run
```

### Production (K3s on Raspberry Pi)

- **Cluster:** K3s (raspi5 as control-plane, raspi4 as worker) — **already running**
- **Namespace:** `apps`
- **Ingress:** Cloudflare Tunnel (TLS at edge, no K8s Ingress resources)
- **Storage:** Longhorn (RF=2) for PostgreSQL and InfluxDB PVCs
- **Secrets:** SOPS + age (encrypted in infra repo)
- **Images:** Multi-arch (linux/arm64 + linux/amd64), pushed to GHCR
- **Resource limits:** CPU 50m-500m, Memory 64Mi-256Mi per service
- **JVM tuning:** `-Xmx128m -XX:+UseSerialGC -XX:MaxMetaspaceSize=64m`
- **Infrastructure services (PostgreSQL, InfluxDB, Mosquitto):** Deployed and managed by IaC repo, not this project

### Resource Budget (estimated, application services only)

| Component | Memory (est.) | CPU (est.) | Managed by |
|-----------|--------------|------------|------------|
| auth-service | 150-200Mi | 50-200m | This project |
| device-service | 150-200Mi | 50-300m | This project |
| data-service | 150-200Mi | 50-200m | This project |
| PostgreSQL 17 | 100-150Mi | 50-200m | IaC repo |
| InfluxDB 2 | 150-250Mi | 50-300m | IaC repo |
| Mosquitto 2 | 10-20Mi | 10-50m | IaC repo |
| **Total** | **~710-970Mi** | **~360-1250m** | |

Fits comfortably on raspi5 (8GB) + raspi4 (4GB) with K3s overhead (~500Mi).

---

## What Changed vs. Legacy

| Aspect | Legacy Monolith | Target Microservices |
|--------|----------------|---------------------|
| Services | 1 (Spring Boot) | 3 (auth + device + data) |
| Auth | Custom JWT (JJWT) | Custom JWT (JJWT) with JWKS distribution |
| Auth framework | None (custom filters) | None (simple jjwt + RSA, NOT Spring Authorization Server) |
| User roles | USER, MOD, ADMIN | USER, ADMIN (MOD dropped) |
| Email verification | Yes (Outlook SMTP) | No (admin creates users, add later if needed) |
| MQTT broker | External (cloud.tbz.ch) | Self-hosted Mosquitto with auth + ACL |
| Device state | In-memory (lost on restart) | PostgreSQL (persistent) |
| InfluxDB writer | Telegraf (separate container) | device-service (direct, Telegraf removed) |
| Scheduled tasks | schedules.json (static) | PostgreSQL table (runtime editable via REST) |
| Database | MariaDB | PostgreSQL 17 |
| Request logging | DB-backed (every request) | Application logs to stdout (collected by cluster) |
| Repo structure | Monorepo | Multi-repo (one per service) |
| Deployment | Docker Compose (7 containers) | K3s on Raspberry Pi (pods in apps namespace) |
| TLS | Nginx + Certbot | Cloudflare Tunnel (TLS at edge) |
| Multi-arch | No | Yes (ARM64 + AMD64 required) |

---

## Decisions Not Yet Made (deferred to implementation)

1. **Refresh token strategy:** DB-backed (revocable) vs. signed JWT (stateless). Recommend DB-backed for revocability.
2. **Schedule change notification (resolved 2026-09-01, ADR 0001):** No longer an open decision — device-service is both schedule owner and executor, so CRUD writes (device-service#41) re-register the affected task directly in-process. The shipped 60s periodic reconciliation (`SchedulerService`, `app.scheduler.poll-interval`) remains only as a fallback safety net for out-of-band DB edits, not as the primary change-propagation mechanism.
3. **WebSocket authentication:** Require JWT for WebSocket connection or allow unauthenticated read-only subscriptions. WebSocket only broadcasts state (read-only), so unauthenticated is acceptable for simplicity.
4. **MQTT topic redesign:** Current topics follow `terra{n}/{sensor}/data` pattern. May be simplified or restructured during M2.
5. **CI/CD pipeline:** GitHub Actions for building multi-arch images per service repo.
