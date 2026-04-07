# IoT App Rewrite — Monolith to Microservices Migration

## Overview

This document is the **complete project plan** for migrating the Terrarium IoT monolith (`oldApp/iotApp`) to a microservices architecture. It covers architecture, milestones, deliverables, testing requirements, and deployment.

**What this project does:**
- Replaces the legacy Spring Boot monolith with 3 focused microservices (each in its own repo)
- Moves device state from in-memory to persistent PostgreSQL storage
- Adds runtime-editable scheduling (replacing static `schedules.json`)
- Deploys all services to the existing K3s cluster on Raspberry Pi

**What this project does NOT do:**
- Modify ESP32 firmware (separate project; MQTT topics may change but firmware is out of scope)
- Build a frontend (separate project, secondary priority)
- Set up the K3s cluster (already running — managed by the [homelab infra repo](https://github.com/doemefu/homelab))
- Deploy infrastructure services (PostgreSQL, InfluxDB, Mosquitto) — those are managed via the IaC repo

---

## Goals

- **Backend feature parity** with the legacy monolith: real-time device state, historical data queries, scheduled automation, manual device control
- **Independent deployability**: restart auth-service without killing MQTT connections; each service has its own repo
- **Persistent device state**: survive service restarts without data loss
- **Runtime-editable schedules**: change light/rain timing without redeployment
- **Production-ready on Pi hardware**: all services fit within Raspberry Pi resource constraints
- **Test coverage**: every service has unit tests + integration tests as part of its deliverable
- **Clean MQTT topic design**: topics can be redesigned for the new architecture (not locked to legacy structure)

---

## Scope

### In Scope
- 3 Java microservices, each in its own GitHub repo: auth-service, device-service, data-service
- K8s Deployment manifests per service (in each service repo)
- Unit tests + integration tests for every service (Testcontainers)
- CI/CD pipeline per repo for multi-arch Docker images (GitHub Actions)
- Infrastructure requirements list for IaC repo (PostgreSQL, InfluxDB, Mosquitto)

### Out of Scope
- Frontend (separate project, separate repo, later)
- ESP32 firmware changes (separate project)
- K3s cluster setup (already done, infra repo)
- Infrastructure service deployment — PostgreSQL, InfluxDB, Mosquitto (IaC repo)
- Mobile app
- Email verification (admin creates accounts manually)
- Service mesh, API gateway, distributed tracing

---

## Fixed Decisions

| Topic | Decision | Rationale |
|-------|----------|-----------|
| Auth | jjwt + RSA key pair (NOT Spring Authorization Server) | OAuth 2.1 is overkill for 1-3 users. Simple JWT covers all needs. |
| Language | Java 25 for all 3 services | Upgraded from Java 21 during M1 implementation. Consistent patterns, single base image. A Python data processing service may be added later on top. |
| Service count | 3 services (auth, device, data) | Clean domain boundaries. device-service sits between devices and data. data-service sits between data and consumers. |
| Repo structure | **Multi-repo** (one repo per service) | Services must be independently deployable and versioned. Future services may use different languages. |
| Roles | USER, ADMIN only (MODERATOR dropped) | No distinct moderator permissions needed for a personal project. |
| Email verification | Dropped | Admin creates users manually. Can be added later if needed. |
| Schedules | PostgreSQL table + REST API | Runtime-editable without redeployment. Old `schedules.json` required container restart. |
| Database | Single PostgreSQL instance in the cluster, shared by all services | Simplest for 3 services. Deployed and managed by IaC repo. |
| InfluxDB writer | device-service (direct) | Telegraf removed — one less component, one less config surface. |
| MQTT broker | Self-hosted Mosquitto in the cluster (with auth + ACL) | Replaces external school broker. Deployed and managed by IaC repo. |
| MQTT topics | Can be redesigned | Not locked to legacy `terra1/SHT35/data` structure. Will be defined during device-service design. |
| Local dev | Develop against cluster | No Docker Compose. Services run locally via `mvnw spring-boot:run`, connect to cluster services via port-forward or direct IP. |
| Deployment target | K3s cluster (raspi5 + raspi4), already running | Namespace `apps`. Cloudflare Tunnel for external access. Longhorn for storage. |
| Secrets | SOPS + age (via IaC repo) | No plaintext secrets in git. |
| Existing code | Archive `auth-service` + `user-management-service` to `archive/` | Spring Authorization Server is being replaced. User entity/patterns are ported to new auth-service. |

---

## Cluster State (as of 2026-03-27)

The K3s cluster is fully operational:

| Node | Role | Arch | Status |
|------|------|------|--------|
| raspi5 | Control-Plane + Worker | arm64, 8GB | Ready |
| raspi4 | Worker | arm64, 4GB | Ready |

Running platform services:
- Traefik (ingress), cert-manager (TLS), cloudflared (Cloudflare Tunnel)
- Longhorn (storage, RF=2)
- Prometheus + Grafana + Alertmanager (monitoring)

Namespace `apps` exists and is empty — ready for service deployment.

---

## Tech Stack

### Backend Services
- **Java 25** (eclipse-temurin:25-jre-alpine base image)
- **Spring Boot 4.0.5** (pinned, not `latest`). Note: SB 4.0 uses Spring Security 7.0, Jackson 3 (`tools.jackson` group ID), and requires `spring-boot-webmvc-test` for MockMvc.
- **Spring Security** (JWT filter, not Spring Authorization Server)
- **Spring Data JPA** + **Hibernate** (PostgreSQL)
- **jjwt 0.12.x** (JWT signing/validation with RSA)
- **Eclipse Paho MQTT v3** (1.2.5) — device-service only
- **influxdb-client-java** (7.x) — device-service + data-service
- **Spring WebSocket** (STOMP) — device-service only
- **Flyway** (database migrations, all services)
- **Lombok** (boilerplate reduction)
- **springdoc-openapi** (API documentation)
- **Testcontainers** (integration tests)

### Infrastructure (deployed via IaC repo, NOT this project)
- **PostgreSQL 17** (Alpine, multi-arch)
- **InfluxDB 2** (Alpine, multi-arch)
- **Eclipse Mosquitto 2** (multi-arch, with password auth + ACL)

### Pinned Versions (to be set at M1 start)

| Component | Version |
|-----------|---------|
| Java | 25 |
| Spring Boot | 4.0.5 |
| jjwt | 0.12.x |
| Eclipse Paho | 1.2.5 |
| influxdb-client-java | 7.x |
| Testcontainers | latest stable at M1 |

---

## Repository Structure

### Service Repos (one per service, on GitHub)

```
homelab-auth-service/          # github.com/doemefu/homelab-auth-service
|-- src/main/java/...
|-- src/test/java/...
|-- src/main/resources/
|   |-- application.properties
|   |-- db/migration/            # Flyway migrations
|-- pom.xml
|-- Dockerfile
|-- k8s/                         # K8s deployment manifest for this service
|   |-- deployment.yml
|-- .github/workflows/           # CI/CD: build + push multi-arch image
|-- README.md
|-- CLAUDE.md                    # Service-specific Claude Code instructions

homelab-device-service/        # github.com/doemefu/homelab-device-service
|-- (same structure)

homelab-data-service/          # github.com/doemefu/homelab-data-service
|-- (same structure)
```

### This Repo (homelab — architecture, docs, firmware, legacy reference)

```
homelab/
|-- README.md
|-- OPERATIONS.md
|-- CONTRIBUTING.md
|-- DEPLOYMENT.md
|-- CLAUDE.md
|
|-- docs/
|   |-- 05-iot-app-rewrite.md        # This document
|   |-- architecture-current.md
|   |-- architecture-target.md
|
|-- archive/                         # Archived old services (reference only)
|   |-- auth-service/
|   |-- user-management-service/
|
|-- oldApp/                          # Legacy monolith (reference only)
|-- newApp/                          # Existing automation/deployment configs (to be cleaned up)
|-- Terra1/                          # ESP32 firmware (not modified in this project)
|-- Terra2/                          # ESP32 firmware (not modified in this project)
```

---

## Infrastructure Requirements (for IaC Repo)

The following services must be deployed to the K3s cluster (namespace `apps`) before the application services can run. This is a checklist for the IaC repo, not this project.

| Service | Image | Min Resources | Storage | Ports | Notes |
|---------|-------|--------------|---------|-------|-------|
| PostgreSQL 17 | `postgres:17-alpine` | 100Mi RAM, 50m CPU | Longhorn PVC, 5Gi | 5432 | Shared by all 3 services. Create databases: `authdb`, `devicedb`, `datadb` (or single `terrariumdb`). |
| InfluxDB 2 | `influxdb:2-alpine` | 200Mi RAM, 100m CPU | Longhorn PVC, 10Gi | 8086 | Create org `terrarium`, bucket `iot-bucket`. |
| Mosquitto 2 | `eclipse-mosquitto:2` | 20Mi RAM, 10m CPU | Longhorn PVC, 1Gi (persistence) | 1883 | Password auth enabled, ACL file. Users: `backend`, `terra1`, `terra2`. |

**Secrets needed (SOPS-encrypted in IaC repo):**
- `POSTGRES_USER`, `POSTGRES_PASSWORD`
- `INFLUX_ADMIN_TOKEN`, `INFLUX_ORG`, `INFLUX_BUCKET`
- `MOSQUITTO_BACKEND_PASSWORD`, `MOSQUITTO_TERRA1_PASSWORD`, `MOSQUITTO_TERRA2_PASSWORD`

**Mosquitto ACL structure:**

```
user terra1
topic write terra1/#
topic read terra1/#
topic read terraGeneral/#

user terra2
topic write terra2/#
topic read terra2/#
topic read terraGeneral/#

user backend
topic read terra1/#
topic read terra2/#
topic read terraGeneral/#
topic write terra1/+/man
topic write terra2/+/man
topic write terraGeneral/#
topic write javaBackend/#
```

> Note: MQTT topic structure may be redesigned during M2 (device-service). This ACL is a starting point based on the legacy structure.

---

## Milestones

### M0 — Architecture & Project Plan

**Goal:** Approved architecture and project plan documents. No code.

| Deliverable | Type | Status |
|-------------|------|--------|
| `docs/05-iot-app-rewrite.md` | Doc | This document |
| `docs/architecture-current.md` | Doc | Legacy monolith architecture |
| `docs/architecture-target.md` | Doc | Target microservices architecture |
| Archive existing `auth-service` + `user-management-service` to `archive/` | Repo cleanup | |
| Delete `newApp/iotApp-deployment/` (stale K8s manifests) | Repo cleanup | |
| Infrastructure requirements list for IaC repo | Doc | See section above |

---

### M1 — auth-service

**Goal:** A working auth-service that issues JWTs, manages users, and exposes a JWKS endpoint. Deployed to K3s cluster.

**Repo:** `github.com/doemefu/homelab-auth-service`

**Technical Deliverables:**

| Component | Description |
|-----------|-------------|
| Spring Boot project | Java 25, Spring Boot 4.0.5 (user generates via start.spring.io, I specify deps) |
| User entity + Flyway migration | `users` + `refresh_tokens` tables |
| Auth endpoints | `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout` |
| JWKS endpoint | `GET /auth/jwks` (RSA public key for token validation) |
| User CRUD endpoints | `POST/GET/PUT/DELETE /users`, `POST /users/{id}/reset-password` |
| Security config | JWT filter, BCrypt password encoder, role-based access |
| Dockerfile | Multi-stage build, `eclipse-temurin:25-jre-alpine`, multi-arch |
| K8s manifest | `k8s/deployment.yml` — Deployment + Service for namespace `apps` |
| GitHub Actions workflow | Build + test + push multi-arch image to GHCR |

**Test Deliverables:**

| Test | Scope | Type |
|------|-------|------|
| UserServiceTest | User CRUD, password encoding, duplicate detection | Unit |
| AuthServiceTest | Login, token generation, refresh, logout | Unit |
| UserControllerTest | REST endpoint responses, validation, error handling | Unit (MockMvc) |
| AuthControllerTest | Auth flow, cookie/header handling | Unit (MockMvc) |
| AuthIntegrationTest | Full login -> get token -> access protected endpoint -> refresh -> logout | Integration (Testcontainers + PostgreSQL) |
| SecurityConfigTest | Unauthorized access returns 401, role-based access works | Integration |

**Doc Deliverables:**

| Document | Content |
|----------|---------|
| `README.md` (in service repo) | API reference, configuration, local run instructions, K8s deployment |

**Deployment verification:**
```bash
kubectl get pods -n apps -l app=auth-service    # Running
kubectl logs -n apps -l app=auth-service        # No errors
# Port-forward and test:
kubectl port-forward -n apps svc/auth-service 8080:8080
curl -X POST http://localhost:8080/auth/login -d '{"username":"admin","password":"..."}'
```

---

### M2 — device-service

**Goal:** A working device-service that subscribes to MQTT, persists device state, writes to InfluxDB, runs scheduled commands, and broadcasts live state via WebSocket. Deployed to K3s cluster.

**Repo:** `github.com/doemefu/homelab-device-service`

**Technical Deliverables:**

| Component | Description |
|-----------|-------------|
| Spring Boot project | Java 25, Spring Boot 4.0.5 |
| Device entity + Flyway migration | `devices` table |
| MQTT client | Subscribe to device topics, parse JSON payloads |
| Device state persistence | Update `devices` table on every MQTT message |
| InfluxDB writer | Write sensor data to InfluxDB bucket on each MQTT message |
| Scheduling engine | Read `schedules` table, register Spring `TaskScheduler` + `CronTrigger`, publish MQTT on schedule |
| WebSocket broadcast | STOMP at `/ws`, broadcast device state changes |
| Device control REST | `POST /devices/{id}/control` -> publish MQTT command |
| Device list REST | `GET /devices`, `GET /devices/{id}` |
| JWT validation | OAuth2 Resource Server config, validate via auth-service JWKS |
| Dockerfile + K8s manifest + GitHub Actions | Same pattern as auth-service |

**Test Deliverables:**

| Test | Scope | Type |
|------|-------|------|
| MqttMessageParserTest | Parse all MQTT payload formats (sensor data, state, status) | Unit |
| DeviceServiceTest | State update logic, device lookup | Unit |
| InfluxWriterTest | Correct measurement, tags, fields written | Unit (mocked client) |
| SchedulerServiceTest | CronTrigger registration, schedule reload, MQTT publish on trigger | Unit |
| DeviceControllerTest | REST endpoints, validation, error responses | Unit (MockMvc) |
| MqttIntegrationTest | Connect to Mosquitto, receive message, verify device state updated | Integration (Testcontainers: Mosquitto + PostgreSQL) |
| InfluxIntegrationTest | Write data to InfluxDB, verify it can be queried back | Integration (Testcontainers: InfluxDB) |
| WebSocketIntegrationTest | Connect STOMP client, receive broadcast on MQTT message | Integration |
| SchedulerIntegrationTest | Create schedule in DB, verify MQTT message published at trigger time | Integration (Testcontainers) |

**Doc Deliverables:**

| Document | Content |
|----------|---------|
| `README.md` (in service repo) | MQTT topics, API reference, scheduling, configuration |

**Deployment verification:**
```bash
kubectl get pods -n apps -l app=device-service  # Running
kubectl logs -n apps -l app=device-service      # MQTT connected, receiving messages
```

---

### M3 — data-service

**Goal:** A working data-service that queries InfluxDB for historical data and provides CRUD for schedules. Deployed to K3s cluster.

**Repo:** `github.com/doemefu/homelab-data-service`

**Technical Deliverables:**

| Component | Description |
|-----------|-------------|
| Spring Boot project | Java 25, Spring Boot 4.0.5 |
| Schedule entity + Flyway migration | `schedules` table |
| InfluxDB query endpoints | `GET /data/measurements`, `GET /data/devices/{id}/status` |
| Schedule CRUD endpoints | `GET/POST/PUT/DELETE /schedules` |
| Flux query builder | Parameterized queries (device, period, aggregation window) |
| JWT validation | OAuth2 Resource Server, validate via auth-service JWKS |
| Dockerfile + K8s manifest + GitHub Actions | Same pattern as auth-service |

**Test Deliverables:**

| Test | Scope | Type |
|------|-------|------|
| InfluxQueryServiceTest | Query construction for different periods, aggregation windows | Unit |
| ScheduleServiceTest | CRUD operations, validation, edge cases | Unit |
| DataControllerTest | REST endpoint responses, parameter validation | Unit (MockMvc) |
| ScheduleControllerTest | CRUD endpoint responses, auth checks | Unit (MockMvc) |
| InfluxQueryIntegrationTest | Write test data to InfluxDB, query via service, verify results | Integration (Testcontainers: InfluxDB) |
| ScheduleIntegrationTest | Full CRUD cycle against real PostgreSQL | Integration (Testcontainers: PostgreSQL) |
| SecurityTest | Unauthenticated requests rejected, ADMIN-only endpoints enforced | Integration |

**Doc Deliverables:**

| Document | Content |
|----------|---------|
| `README.md` (in service repo) | API reference, InfluxDB query patterns, configuration |

**Deployment verification:**
```bash
kubectl get pods -n apps -l app=data-service    # Running
kubectl port-forward -n apps svc/data-service 8082:8080
curl http://localhost:8082/data/measurements?device=terra1&period=24h -H "Authorization: Bearer <jwt>"
```

---

### M4 — Integration & End-to-End Verification

**Goal:** All 3 services running on K3s, talking to each other and to infrastructure services. Full data flow verified. Documentation complete.

**Technical Deliverables:**

| Component | Description |
|-----------|-------------|
| Cloudflare Tunnel config | Ingress entries for API services (in IaC repo) |
| Resource limit tuning | Adjust based on `kubectl top pods` actual usage |
| Smoke test script | `scripts/smoke-test.sh` that runs against the cluster |

**Test Deliverables:**

| Test | Scope | Type |
|------|-------|------|
| Smoke test | Login -> list devices -> control device -> query data -> manage schedules | End-to-end script |
| Deployment verification | All pods Running, PVCs Bound, no CrashLoopBackOff | Manual (kubectl) |
| External access test | API accessible via Cloudflare Tunnel | Manual |
| Resource check | `kubectl top pods -n apps` — all within limits | Manual |
| Cross-service auth | Token from auth-service accepted by device-service and data-service | Manual |
| Data flow | MQTT message -> device-service -> PostgreSQL + InfluxDB -> data-service query returns it | Manual |

**Doc Deliverables:**

| Document | Content |
|----------|---------|
| `README.md` (this repo, update) | Project overview, architecture diagram, quick start, service links |
| `OPERATIONS.md` (create) | Runbooks: service restart, DB backup/restore, Mosquitto password rotation, log access |
| `CONTRIBUTING.md` (create) | Local dev setup (port-forward to cluster), testing, PR process per service repo |

---

## Definition of Done

- [ ] All 3 backend services deployed to K3s and pass their test suites
- [ ] Each service has its own GitHub repo with CI/CD building multi-arch images
- [ ] Auth-service issues JWTs that device-service and data-service accept
- [ ] device-service persists device state in PostgreSQL (survives restart)
- [ ] device-service writes sensor data to InfluxDB
- [ ] data-service queries InfluxDB and returns historical data
- [ ] Scheduled automation runs (light on/off, rain on schedule)
- [ ] Smoke test script passes end-to-end against the cluster
- [ ] All secrets encrypted via SOPS (no plaintext in git)
- [ ] `README.md`, `OPERATIONS.md`, `CONTRIBUTING.md` complete
- [ ] Each service has unit tests + integration tests with reasonable coverage
- [ ] No `latest` tags anywhere (all versions pinned)
- [ ] Infrastructure requirements clearly documented for IaC repo

---

## Extensions (Post-M4)

Ideas deliberately excluded from M0-M4 scope. Only start after Definition of Done is fully met.

### Frontend (separate project)
- React 18 + TypeScript + Vite + TailwindCSS
- Own repo: `homelab-frontend`
- Login, dashboard with live WebSocket, historical charts, schedule management, admin panel

### ESP32 Firmware Update (separate project)
- Point Terra1 + Terra2 to self-hosted Mosquitto
- Add MQTT credentials
- Adapt to new MQTT topic structure if changed

### Python Data Processing Service
- Real data processing/analytics on top of the Java data-service
- Anomaly detection, trend analysis, predictive alerts
- Own repo, Python/FastAPI

### Email Notifications
- Alerts when device goes offline (mqttState 0 for >5 minutes)
- Daily summary (min/max temperature, humidity, rain cycles)

### OTA Firmware Updates
- Push firmware to ESP32 over-the-air via MQTT or HTTP

### Additional Sensors
- CO2 sensor, UV index, soil moisture

### Multi-Terrarium Support
- Dynamic device registration (not hardcoded terra1/terra2)
- Device provisioning flow

### Grafana Integration
- Direct Grafana dashboards for InfluxDB data (Grafana already running in monitoring namespace)
