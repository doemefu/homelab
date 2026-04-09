# Sentry Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Sentry error tracking to auth-service and device-service (and prepare data-service) so that unhandled exceptions and background-thread errors are automatically captured and visible in the Sentry dashboard.

**Architecture:** Sentry's Spring Boot logging integration is enabled in both services — all existing `log.error(..., exception)` calls are captured automatically with no new exception-handling code. One minor fix in `SchedulerService` is required to attach the exception object to the log call so SLF4J passes it to Sentry. A shared K8s Secret `sentry-dsn` is created via Ansible (`50_apps_infra.yml`) from a SOPS-encrypted value, and referenced by both service Deployments. auth-service requires only config changes; device-service requires config changes plus the one-line `SchedulerService` fix.

**Tech Stack:** `io.sentry:sentry-spring-boot-starter-jakarta:8.34.1`, Spring Boot 4.0.5, Java 25, Ansible + SOPS for secret management, K8s Secrets in `apps` namespace.

---

## Prerequisites (user actions before starting)

1. Log in to [sentry.io](https://sentry.io) with your GitHub Student account
2. Create a new project: **Create Project → Java → Spring Boot → name it `homelab`**
3. Copy the DSN: **Project Settings → Client Keys (DSN) → DSN** — looks like `https://abc123@o123456.ingest.sentry.io/789`
4. Keep the DSN handy — you will paste it into `all.sops.yml` in Task 6

---

## Files Changed

### homelab (infrastructure repo)
| File | Change |
|------|--------|
| `infrastructure/infra/playbooks/50_apps_infra.yml` | Add task: create `sentry-dsn` K8s Secret from SOPS var |
| `infrastructure/infra/inventory/group_vars/all.sops.yml.example` | Document `sentry_dsn` variable |

### auth-service repo
| File | Change |
|------|--------|
| `pom.xml` | Add `sentry-spring-boot-starter-jakarta:8.34.1` dependency |
| `src/main/resources/application.yaml` | Add `sentry:` config block |
| `k8s/deployment.yaml` | Add `SENTRY_DSN` env var from K8s Secret |

### device-service repo
| File | Change |
|------|--------|
| `pom.xml` | Add `sentry-spring-boot-starter-jakarta:8.34.1` dependency |
| `src/main/resources/application.yaml` | Add `sentry:` config block |
| `k8s/deployment.yaml` | Add `SENTRY_DSN` env var from K8s Secret |
| `src/main/java/ch/furchert/homelab/device/service/SchedulerService.java` | Fix log.error call at line 123: pass `e` as final arg so SLF4J attaches the stack trace |

---

## Task 1: Add Sentry dependency to auth-service

**Repo:** `homelab-auth-service`

**Files:**
- Modify: `pom.xml`
- Modify: `src/main/resources/application.yaml`

- [ ] **Step 1: Add Sentry dependency to pom.xml**

In `pom.xml`, add after the last `<dependency>` block inside `<dependencies>` (before the closing `</dependencies>` tag):

```xml
<!-- Sentry error tracking -->
<dependency>
    <groupId>io.sentry</groupId>
    <artifactId>sentry-spring-boot-starter-jakarta</artifactId>
    <version>8.34.1</version>
</dependency>
```

- [ ] **Step 2: Add Sentry config block to application.yaml**

Append to the end of `src/main/resources/application.yaml`:

```yaml
sentry:
  dsn: ${SENTRY_DSN:}
  environment: production
  send-default-pii: false
  traces-sample-rate: 0.0
  logging:
    enabled: true
    minimum-event-level: ERROR
    minimum-breadcrumb-level: WARN
  tags:
    service: auth-service
```

`SENTRY_DSN` defaults to empty string — Sentry is a no-op when DSN is empty, so all existing tests pass unchanged.

- [ ] **Step 3: Build and run tests**

```bash
./mvnw verify
```

Expected: `BUILD SUCCESS`. If Sentry raises a startup warning about empty DSN — that is normal and expected.

- [ ] **Step 4: Commit**

```bash
git add pom.xml src/main/resources/application.yaml
git commit -m "feat: add Sentry error tracking (logging integration)

Adds sentry-spring-boot-starter-jakarta 8.34.1. All log.error() calls
are automatically captured as Sentry events. DSN is empty by default
so tests are unaffected. SENTRY_DSN env var wired in k8s/deployment.yaml
in a separate commit."
```

---

## Task 2: Wire SENTRY_DSN into auth-service K8s Deployment

**Repo:** `homelab-auth-service`

**Files:**
- Modify: `k8s/deployment.yaml`

- [ ] **Step 1: Add SENTRY_DSN env var to deployment.yaml**

In `k8s/deployment.yaml`, add to the `env:` list of the `auth-service` container (after the existing `APP_JWT_PUBLIC_KEY` entry):

```yaml
            - name: SENTRY_DSN
              valueFrom:
                secretKeyRef:
                  name: sentry-dsn
                  key: dsn
```

Full resulting `env:` block for reference:

```yaml
          env:
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: homelab-db-credentials
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: homelab-db-credentials
                  key: password
            - name: APP_JWT_PRIVATE_KEY
              value: "file:/etc/secrets/private.pem"
            - name: APP_JWT_PUBLIC_KEY
              value: "file:/etc/secrets/public.pem"
            - name: SENTRY_DSN
              valueFrom:
                secretKeyRef:
                  name: sentry-dsn
                  key: dsn
```

- [ ] **Step 2: Commit**

```bash
git add k8s/deployment.yaml
git commit -m "feat: add SENTRY_DSN env var to auth-service K8s deployment"
```

---

## Task 3: Add Sentry dependency to device-service

**Repo:** `homelab-device-service`

**Files:**
- Modify: `pom.xml`
- Modify: `src/main/resources/application.yaml`

- [ ] **Step 1: Add Sentry dependency to pom.xml**

In `pom.xml`, add after the last `<dependency>` block inside `<dependencies>` (before the closing `</dependencies>` tag):

```xml
<!-- Sentry error tracking -->
<dependency>
    <groupId>io.sentry</groupId>
    <artifactId>sentry-spring-boot-starter-jakarta</artifactId>
    <version>8.34.1</version>
</dependency>
```

- [ ] **Step 2: Add Sentry config block to application.yaml**

Append to the end of `src/main/resources/application.yaml`:

```yaml
sentry:
  dsn: ${SENTRY_DSN:}
  environment: production
  send-default-pii: false
  traces-sample-rate: 0.0
  logging:
    enabled: true
    minimum-event-level: ERROR
    minimum-breadcrumb-level: WARN
  tags:
    service: device-service
```

- [ ] **Step 3: Build and run tests**

```bash
./mvnw verify
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 4: Commit**

```bash
git add pom.xml src/main/resources/application.yaml
git commit -m "feat: add Sentry error tracking (logging integration)

Adds sentry-spring-boot-starter-jakarta 8.34.1. All log.error() calls
are automatically captured as Sentry events. DSN is empty by default
so tests are unaffected."
```

---

## Task 4: Fix SchedulerService log.error call

**Repo:** `homelab-device-service`

**Files:**
- Modify: `src/main/java/ch/furchert/homelab/device/service/SchedulerService.java` (line 123)

**Why:** SLF4J only attaches the exception stack trace to a log event when the final argument is a `Throwable`. Currently `e.getMessage()` (a String) is passed instead of `e`, so Sentry's logging integration captures the log message but not the exception stack trace.

- [ ] **Step 1: Fix the log.error call in SchedulerService**

In `SchedulerService.java`, find the catch block in `reloadSchedules()` (around line 122):

```java
            } catch (IllegalArgumentException e) {
                log.error("Invalid cron expression '{}' for schedule id={}: {}",
                        schedule.getCronExpression(), schedule.getId(), e.getMessage());
            }
```

Replace with:

```java
            } catch (IllegalArgumentException e) {
                log.error("Invalid cron expression '{}' for schedule id={}: {}",
                        schedule.getCronExpression(), schedule.getId(), e.getMessage(), e);
            }
```

The only change is appending `, e` as the final argument — SLF4J treats a trailing `Throwable` argument specially and attaches it as the exception, which Sentry then captures with full stack trace.

- [ ] **Step 2: Run tests**

```bash
./mvnw verify
```

Expected: `BUILD SUCCESS`. The existing `SchedulerServiceTest` must still pass.

- [ ] **Step 3: Commit**

```bash
git add src/main/java/ch/furchert/homelab/device/service/SchedulerService.java
git commit -m "fix: attach exception to SchedulerService log.error for Sentry capture

SLF4J only forwards the stack trace to appenders (and Sentry) when the
final argument to log.error() is a Throwable. Was passing e.getMessage()
(String), so the exception was swallowed silently in error tracking."
```

---

## Task 5: Wire SENTRY_DSN into device-service K8s Deployment

**Repo:** `homelab-device-service`

**Files:**
- Modify: `k8s/deployment.yaml`

- [ ] **Step 1: Add SENTRY_DSN env var to deployment.yaml**

In `k8s/deployment.yaml`, add to the `env:` list of the `device-service` container (after the existing `JWKS_URI` entry):

```yaml
            - name: SENTRY_DSN
              valueFrom:
                secretKeyRef:
                  name: sentry-dsn
                  key: dsn
```

Full resulting `env:` block for reference:

```yaml
          env:
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: device-service-secrets
                  key: db-username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: device-service-secrets
                  key: db-password
            - name: MQTT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: device-service-secrets
                  key: mqtt-password
            - name: INFLUX_TOKEN
              valueFrom:
                secretKeyRef:
                  name: device-service-secrets
                  key: influx-token
            - name: MQTT_BROKER_URL
              value: "tcp://mosquitto.apps.svc.cluster.local:1883"
            - name: INFLUX_URL
              value: "http://influxdb.apps.svc.cluster.local:8086"
            - name: JWKS_URI
              value: "http://auth-service.apps.svc.cluster.local:8080/auth/jwks"
            - name: SENTRY_DSN
              valueFrom:
                secretKeyRef:
                  name: sentry-dsn
                  key: dsn
```

- [ ] **Step 2: Commit**

```bash
git add k8s/deployment.yaml
git commit -m "feat: add SENTRY_DSN env var to device-service K8s deployment"
```

---

## Task 6: Create sentry-dsn K8s Secret via Ansible

**Repo:** `homelab` (infrastructure)

**Files:**
- Modify: `infrastructure/infra/playbooks/50_apps_infra.yml`
- Modify: `infrastructure/infra/inventory/group_vars/all.sops.yml.example`

**Context:** All K8s secrets that hold sensitive values are provisioned via Ansible from SOPS-encrypted variables in `all.sops.yml`. The `sentry_dsn` variable must be added there (encrypted) by the user. The Ansible task creates the K8s Secret in the `apps` namespace so it is available to both deployments.

- [ ] **Step 1: Document sentry_dsn in all.sops.yml.example**

In `infrastructure/infra/inventory/group_vars/all.sops.yml.example`, add a new entry in the secrets section:

```yaml
# Sentry DSN — obtain from sentry.io project settings → Client Keys
# One DSN shared across all three homelab microservices (auth, device, data)
sentry_dsn: "https://REPLACE_ME@oXXXXXXXX.ingest.sentry.io/XXXXXXXX"
```

- [ ] **Step 2: Add sentry_dsn to all.sops.yml**

This step is a **user action** — Claude cannot touch SOPS-encrypted files.

1. Get your DSN from Sentry: **Project Settings → Client Keys (DSN) → DSN**
2. Open the encrypted file for editing:
   ```bash
   sops infrastructure/infra/inventory/group_vars/all.sops.yml
   ```
3. Add the line:
   ```yaml
   sentry_dsn: "https://YOUR_KEY@oXXXXXXXX.ingest.sentry.io/XXXXXXXX"
   ```
4. Save and close — SOPS re-encrypts automatically.

- [ ] **Step 3: Add assert guard + Sentry Secret task to 50_apps_infra.yml**

In `infrastructure/infra/playbooks/50_apps_infra.yml`, add both tasks after the "Apps Namespace anlegen" task (around line 28, before the `# --- PostgreSQL ---` comment). The assert must come first so the playbook fails fast if `sentry_dsn` is missing from SOPS:

```yaml
    - name: Prüfen dass sentry_dsn gesetzt ist
      ansible.builtin.assert:
        that:
          - sentry_dsn is defined
          - sentry_dsn | length > 0
        fail_msg: >-
          sentry_dsn ist nicht gesetzt.
          Bitte in infra/inventory/group_vars/all.sops.yml eintragen
          (Sentry → Project Settings → Client Keys → DSN).
      delegate_to: localhost

    # --- Sentry ---
    - name: Sentry DSN Secret anlegen
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: sentry-dsn
            namespace: "{{ apps_namespace }}"
          type: Opaque
          stringData:
            dsn: "{{ sentry_dsn }}"
      no_log: true
      delegate_to: localhost
```

- [ ] **Step 5: Verify ansible-lint passes**

```bash
ansible-lint infrastructure/infra/playbooks/50_apps_infra.yml
```

Expected: 0 violations.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/infra/playbooks/50_apps_infra.yml \
        infrastructure/infra/inventory/group_vars/all.sops.yml.example
git commit -m "feat: provision sentry-dsn K8s Secret via Ansible

Adds sentry_dsn SOPS variable and a kubernetes.core.k8s task in
50_apps_infra.yml to create the shared sentry-dsn Secret in the apps
namespace. Used by auth-service and device-service Deployments."
```

---

## Task 7: Verify end-to-end

**Repos:** homelab, homelab-auth-service, homelab-device-service

- [ ] **Step 1: Run Ansible to create the K8s secret**

Ensure `all.sops.yml` has `sentry_dsn` set (Task 6, Step 2), then:

```bash
ansible-playbook infrastructure/infra/playbooks/50_apps_infra.yml
```

Expected: Task "Sentry DSN Secret anlegen" → `changed` or `ok`. No failures.

- [ ] **Step 2: Confirm the secret exists in the cluster**

```bash
kubectl get secret sentry-dsn -n apps
```

Expected:
```
NAME         TYPE     DATA   AGE
sentry-dsn   Opaque   1      Xs
```

- [ ] **Step 3: Confirm secret has the right key**

```bash
kubectl get secret sentry-dsn -n apps -o jsonpath='{.data.dsn}' | base64 -d
```

Expected: your actual Sentry DSN URL.

- [ ] **Step 4: Trigger a test error in Sentry**

After deploying either service to the cluster, you can send a test event from the pod:

```bash
kubectl exec -n apps deploy/auth-service -- \
  curl -s http://localhost:8080/actuator/health
```

Or trigger a real error scenario. Alternatively, temporarily add a test controller endpoint in auth-service that throws an exception, deploy, hit it, then remove.

The simplest validation: check your Sentry project dashboard — within a few minutes of deployment, the "Issues" tab should show events if any errors occur.

---

## Data-Service Note

When `homelab-data-service` is implemented, include Sentry from day one:

1. Add `sentry-spring-boot-starter-jakarta:8.34.1` to `pom.xml` (same as above)
2. Add the same `sentry:` block to `application.yaml` with `service: data-service`
3. Add `SENTRY_DSN` from `sentry-dsn` secret to `k8s/deployment.yaml`
4. The K8s Secret already exists (created by Task 6) — no Ansible change needed

No background threads expected in data-service (REST + DB queries only), so logging integration alone is sufficient.
