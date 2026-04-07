# Current Architecture — Legacy Monolith

This document describes the architecture of the legacy Terrarium IoT application as it exists in `oldApp/`.

---

## Overview

The legacy application is a **single Spring Boot 3.3 / Java 21 monolith** that handles all responsibilities: user authentication, device communication (MQTT), scheduled automation, real-time WebSocket updates, time-series data storage, and a REST API for the React frontend.

**Stack:** Spring Boot 3.3, Java 21, MariaDB, InfluxDB, Eclipse Paho MQTT, React 18

---

## Architecture Diagram

```
Internet
    |
    v
+--------+       +------------------+
| Nginx  | <---> | React Frontend   |  (Port 33)
| :80/443|       | (React 18)       |
+--------+       +--------+---------+
    |                      |
    v                      | REST + WebSocket (STOMP)
+---------------------------+---------------------------+
|            Spring Boot Monolith (:8080/8443)          |
|                                                       |
|  +-------------+  +--------------+  +-------------+  |
|  | AuthCtrl    |  | DataCtrl     |  | UserMgmtCtrl|  |
|  | /api/auth/* |  | /api/data/*  |  | /api/user-* |  |
|  +------+------+  +------+-------+  +------+------+  |
|         |                |                  |         |
|  +------+------+  +------+-------+  +------+------+  |
|  | JWT/Refresh |  | InfluxService|  | UserService |  |
|  | TokenService|  | (Flux DSL)   |  | EmailService|  |
|  +-------------+  +--------------+  +-------------+  |
|                                                       |
|  +------------------+  +---------------------------+  |
|  | MqttClientService|  | MqttSchedulerService      |  |
|  | MqttService      |  | (CronTrigger, schedules   |  |
|  | (Paho v3)        |  |  .json)                   |  |
|  +--------+---------+  +-------------+-------------+  |
|           |                          |                |
|  +--------+---------+                |                |
|  | WebSocketCtrl    | <-- MqttMessageReceivedEvent   |
|  | (STOMP /api/ws)  |                                |
|  +------------------+                                |
+---------------------------+---------------------------+
        |           |                  |
        v           v                  v
  +-----------+ +-----------+  +----------------+
  | MariaDB   | | InfluxDB  |  | MQTT Broker    |
  | :3306     | | :8086     |  | cloud.tbz.ch   |
  | - users   | | - sensor  |  | :1883          |
  | - tokens  | |   data    |  | (external,     |
  | - roles   | |           |  |  school broker)|
  +-----------+ +-----------+  +-------+--------+
                                       |
                            +----------+----------+
                            |                     |
                       +----+-----+         +-----+----+
                       |  Terra1  |         |  Terra2  |
                       |  (ESP32) |         |  (ESP32) |
                       +----------+         +----------+
```

---

## Components

### 1. REST API (Controllers)

| Controller | Base Path | Endpoints | Auth Required |
|-----------|-----------|-----------|---------------|
| AuthController | `/api/auth` | `POST /login`, `POST /register`, `POST /verifyEmail`, `POST /logout`, `POST /refreshtoken` | No (public) |
| DataController | `/api/data` | `GET /influxData`, `GET /influxDataNew`, `GET /deviceStatus` | Yes (USER) |
| UserMgmtController | `/api/user-management` | `GET /showUser/{id}`, `DELETE /deleteUser/{id}`, `PUT /updateUser/{id}`, `GET /showRoles`, `POST /forgotPassword`, `POST /resetPassword`, `GET /allUsers` | Yes (ADMIN for most) |
| ContentController | `/api/get` | `GET /all`, `GET /user`, `GET /mod`, `GET /admin` | Role-based |
| WebSocketController | `/api/ws` | `@MessageMapping /requestData`, `/toggle/{id}/{field}` | WebSocket |

### 2. Authentication

- **Method:** Custom JWT + Refresh Token
- **Library:** JJWT (io.jsonwebtoken)
- **Storage:** HTTP-only, Secure, SameSite=Lax cookies
- **Token lifetimes:** 30min access (prod), 1 week refresh (prod)
- **Password hashing:** BCrypt (strength 10, SecureRandom)
- **Roles:** USER, MODERATOR, ADMIN
- **User statuses:** UNVERIFIED, ACTIVE, INACTIVE, BLOCKED
- **Email verification:** Required for account activation (Outlook SMTP)

### 3. MQTT Integration

- **Client:** Eclipse Paho MQTT v3
- **Broker:** `tcp://cloud.tbz.ch:1883` (external school broker, no auth)
- **Connection:** Auto-reconnect, will message on disconnect

**Subscribed Topics:**

| Topic Pattern | Payload | Purpose |
|--------------|---------|---------|
| `terra{n}/SHT35/data` | `{"Temperature": 22.5, "Humidity": 65.0}` | Sensor readings (30s interval) |
| `terra{n}/mqtt/status` | `{"MqttState": 1}` | Device online/offline |
| `terra{n}/light` | `{"LightState": 1}` | Light state feedback |
| `terra{n}/nightLight` | `{"NightLightState": 1}` | Night light state (terra2 only) |
| `terra{n}/rain` | `{"RainState": 1}` | Rain state feedback |

**Published Topics (manual control):**

| Topic | Payload | Trigger |
|-------|---------|---------|
| `terra{n}/light/man` | `{"LightState": 0\|1}` | WebSocket toggle from frontend |
| `terra{n}/rain/man` | `{"RainState": 0\|1}` | WebSocket toggle from frontend |
| `terra{n}/nightLight/man` | `{"NightLightState": 0\|1}` | WebSocket toggle from frontend |
| `terraGeneral/{field}/schedule` | `{"{Field}State": 0\|1}` | Scheduled task |

### 4. Scheduled Tasks

Loaded from `schedules.json` at startup, executed via Spring `TaskScheduler` + `CronTrigger`:

| Schedule | Cron | MQTT Topic | Payload |
|----------|------|-----------|---------|
| Light on | `0 0 8 * * ?` | `terraGeneral/light/schedule` | `{"LightState": 1}` |
| Light off | `0 0 20 * * ?` | `terraGeneral/light/schedule` | `{"LightState": 0}` |
| Night light on | `0 0 23 * * ?` | `terraGeneral/nightLight/schedule` | `{"NightLightState": 1}` |
| Night light off | `0 0 5 * * ?` | `terraGeneral/nightLight/schedule` | `{"NightLightState": 0}` |
| Rain | `0 0 7,9,11,19,21 * * ?` | `terraGeneral/rain/schedule` | `{"RainState": 1}` |

### 5. WebSocket (STOMP)

- **Endpoint:** `/api/ws`
- **Protocol:** STOMP over SockJS
- **Broker prefix:** `/topic`
- **App prefix:** `/app`
- **Flow:** MQTT message received -> `MqttMessageReceivedEvent` -> `WebSocketController` -> broadcast to `/topic/terrarium`
- **Control:** Frontend sends toggle via `/app/toggle/{terrariumId}/{field}` -> publishes MQTT command

### 6. InfluxDB Integration

- **Client:** influxdb-client-java v7.1.0
- **Query language:** Flux DSL
- **Data stored by:** Telegraf (MQTT consumer -> InfluxDB writer)
- **Queries:**
  - Measurement data: 15-minute mean windows, configurable period (24h/7d/30d/1y)
  - Device status: 25-hour history at hourly intervals

### 7. Email Service

- **Provider:** Outlook SMTP (`smtp-mail.outlook.com:587`)
- **Sender:** `tbz.flugi@hotmail.com` (school account)
- **Uses:** Email verification after registration, password reset tokens
- **Templates:** Thymeleaf

---

## Database Schema

### MariaDB

```sql
-- Core user table
user_accounts (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(255) UNIQUE NOT NULL,
    email       VARCHAR(255) UNIQUE NOT NULL,
    password    VARCHAR(255) NOT NULL,          -- BCrypt hash
    userStatus_id INT REFERENCES status(id),
    created     TIMESTAMP,
    updated     TIMESTAMP,
    last_login  TIMESTAMP
);

-- Many-to-many: users <-> roles
user_roles (
    user_id BIGINT REFERENCES user_accounts(id),
    role_id INT REFERENCES role(id)
);

role (
    id   INT PRIMARY KEY,
    name VARCHAR(20)   -- ROLE_USER, ROLE_MODERATOR, ROLE_ADMIN
);

status (
    id   INT PRIMARY KEY,
    name VARCHAR(20)   -- UNVERIFIED, ACTIVE, INACTIVE, BLOCKED
);

-- JWT refresh tokens
refreshtoken (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id     BIGINT REFERENCES user_accounts(id),
    token       VARCHAR(255) UNIQUE NOT NULL,
    expiryDate  DATETIME NOT NULL
);

-- Email verification / password reset tokens
email_token (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id     BIGINT REFERENCES user_accounts(id),
    token       VARCHAR(255) NOT NULL,
    expiryDate  DATETIME NOT NULL,
    used        BOOLEAN DEFAULT FALSE
);

-- Request logging
log_entry (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(255),
    endpoint    VARCHAR(500),
    timestamp   DATETIME,
    methodName  VARCHAR(255)
);
```

### InfluxDB

- **Measurement:** `InfluxTerraData`
- **Tags:** `device` (terra1/terra2), `application`
- **Fields:** Temperature (double), Humidity (double), MqttState (int)
- **Retention:** Default (unlimited)

---

## Data Flow

### Sensor Data (ESP32 -> Frontend)

```
ESP32 publishes JSON to MQTT topic
    -> Telegraf subscribes, writes to InfluxDB (historical)
    -> Spring Boot MqttService receives, updates in-memory Terrarium object
        -> Publishes MqttMessageReceivedEvent
            -> WebSocketController broadcasts to /topic/terrarium
                -> React frontend receives via STOMP, updates UI
```

### Device Control (Frontend -> ESP32)

```
User clicks toggle in React UI
    -> STOMP message to /app/toggle/{terrariumId}/{field}
        -> WebSocketController publishes MQTT to terra{n}/{field}/man
            -> ESP32 receives, toggles relay
                -> ESP32 publishes state feedback to terra{n}/{field}
```

### Scheduled Automation

```
MqttSchedulerService loads schedules.json on startup
    -> Registers CronTrigger for each active schedule
        -> At scheduled time: publishes MQTT to terraGeneral/{field}/schedule
            -> All ESP32 devices receive and act
```

---

## Deployment (Docker Compose)

7 containers orchestrated via Docker Compose:

| Container | Image | Port | Purpose |
|-----------|-------|------|---------|
| Frontend | iot-app:front | 33 | React dev server |
| Backend | iot-app:back | 8080, 8443 | Spring Boot monolith |
| MariaDB | mariadb:latest | 3306 | User data, tokens |
| InfluxDB | influxdb:alpine | 8086 | Time-series sensor data |
| Telegraf | telegraf:alpine | — | MQTT -> InfluxDB bridge |
| Nginx | nginx:alpine | 80, 443 | Reverse proxy, SSL |
| Certbot | certbot | — | Let's Encrypt SSL certs |

---

## Known Issues & Limitations

1. **External MQTT broker** (`cloud.tbz.ch`) — school-owned, no auth, no control over uptime
2. **In-memory device state** — lost on restart, no persistence
3. **Telegraf as middleman** — adds a component that could be eliminated
4. **Monolithic deployment** — any change (even to auth) requires full restart, killing MQTT connections
5. **MariaDB for everything** — user data + tokens + logs in one DB, no separation
6. **MODERATOR role** — exists but has no distinct permissions in practice
7. **Email via school account** — `tbz.flugi@hotmail.com` is not a permanent solution
8. **No multi-arch** — Docker images built for single architecture
9. **`latest` tags** — MariaDB and other images use unpinned versions
10. **Request logging to DB** — every API call logged to MariaDB, adds write load with minimal value
