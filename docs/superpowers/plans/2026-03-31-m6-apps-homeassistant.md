# M6: App Infrastructure + Home Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy PostgreSQL 17, InfluxDB 2, Mosquitto 2 in the `apps` namespace and Home Assistant in the `homeassistant` namespace, all accessible on the LAN, with Longhorn PVCs for persistence.

**Architecture:** Two new playbooks (`50_apps_infra.yml`, `51_homeassistant.yml`) following the established `40_platform.yml` pattern (delegate_to: localhost, Helm via helm_binary). Mosquitto deployed as raw Kubernetes manifests (no Helm — k8s-at-home chart is archived). Home Assistant deployed via pajikos Helm chart with `hostNetwork: true` for mDNS discovery.

**Tech Stack:** Ansible `kubernetes.core.helm` + `kubernetes.core.k8s`, bitnami/postgresql, influxdata/influxdb2, eclipse/mosquitto:2.0.x (raw manifests), pajikos/home-assistant Helm chart, SOPS+age for secrets, Longhorn PVCs.

> **CLAUDE.md requirement:** Before implementing, create a worklog at `.agent/worklogs/YYYYMMDD-HHMMSS-m6-apps-homeassistant-<rand4>.md` and follow the 5-phase workflow. This plan covers Phase 4 (implement) in detail.

---

## File Map

| Action | File | Purpose |
|---|---|---|
| Create | `infra/playbooks/50_apps_infra.yml` | PostgreSQL + InfluxDB + Mosquitto deploy |
| Create | `infra/playbooks/51_homeassistant.yml` | Home Assistant deploy |
| Create | `cluster/values/postgresql.yaml` | bitnami/postgresql Helm values |
| Create | `cluster/values/influxdb2.yaml` | influxdata/influxdb2 Helm values |
| Create | `cluster/values/home-assistant.yaml` | pajikos/home-assistant Helm values |
| Modify | `infra/inventory/group_vars/all.sops.yml` | Add 4 new secrets |
| Modify | `infra/inventory/group_vars/all.sops.yml.example` | Document new secrets |
| Modify | `infra/inventory/group_vars/all.yml` | Remove obsolete `ha_host` variable |
| Modify | `docs/01-homelab-platform.md` | Update M6 status |
| Modify | `README.md` | Mark M6 done |
| Modify | `OPERATIONS.md` | Add app-infra + HA runbooks |
| Modify | `APPS.md` | Update with deployed services |
| Modify | `.agent/memory.md` | Add M6-DONE entry |

---

## Part 1: App Infrastructure (`50_apps_infra.yml`)

---

### Task 1: Research — Pin Helm chart versions

**Files:** None changed — output feeds into Tasks 3–5.

- [ ] **Step 1: Add Helm repos and search for latest chart versions**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add influxdata https://helm.influxdata.com/
helm repo update
helm search repo bitnami/postgresql --versions | head -5
helm search repo influxdata/influxdb2 --versions | head -5
```

Expected: table with `CHART VERSION` and `APP VERSION`. Record the latest chart version that ships **PostgreSQL 17.x** and the latest **influxdb2 2.x** chart.

- [ ] **Step 2: Search for pajikos/home-assistant chart version**

```bash
helm repo add pajikos https://pajikos.github.io/home-assistant-helm-chart/
helm repo update
helm search repo pajikos/home-assistant --versions | head -5
```

Expected: table with latest chart version. Record it.

- [ ] **Step 3: Find latest eclipse/mosquitto image tag**

```bash
# Check https://hub.docker.com/_/eclipse-mosquitto/tags for latest 2.0.x tag
# At time of writing: 2.0.21 — verify and record current patch version
```

- [ ] **Step 4: Record versions**

Write the four pinned versions into the worklog (§1 research):
```
bitnami/postgresql chart: X.Y.Z  (app: 17.x)
influxdata/influxdb2 chart: X.Y.Z
pajikos/home-assistant chart: X.Y.Z
eclipse/mosquitto image: 2.0.X
```

These replace every `X.Y.Z` placeholder in the tasks below.

---

### Task 2: Add new secrets to all.sops.yml

**Files:**
- Modify: `infra/inventory/group_vars/all.sops.yml` (decrypt → edit → re-encrypt)
- Modify: `infra/inventory/group_vars/all.sops.yml.example`

- [ ] **Step 1: Decrypt the SOPS file for editing**

```bash
sops infra/inventory/group_vars/all.sops.yml
```

This opens the file in `$EDITOR`. Add the following four variables at the end:

```yaml
# PostgreSQL — Passwörter für Primary und Replication
# Generieren: openssl rand -base64 24
postgresql_password: "CHANGE_ME_generate_with_openssl_rand"
postgresql_replication_password: "CHANGE_ME_generate_with_openssl_rand"

# InfluxDB 2 — Admin-Passwort (min 8 Zeichen) und API-Token
# Token generieren: openssl rand -hex 32
influxdb_admin_password: "CHANGE_ME_min_8_zeichen"
influxdb_admin_token: "CHANGE_ME_generate_with_openssl_rand_hex_32"
```

Save and exit. SOPS re-encrypts automatically on save.

- [ ] **Step 2: Verify the secrets are accessible**

```bash
sops -d infra/inventory/group_vars/all.sops.yml | grep -E "postgresql|influxdb"
```

Expected: four lines with the values you entered (plaintext in terminal only, never in git).

- [ ] **Step 3: Update all.sops.yml.example**

Add the same four entries to `infra/inventory/group_vars/all.sops.yml.example` with `CHANGE_ME` placeholders and generation instructions (match the style of existing entries in that file):

```yaml
# PostgreSQL Passwörter
# Generieren: openssl rand -base64 24
postgresql_password: "CHANGE_ME_generate_with_openssl_rand"
postgresql_replication_password: "CHANGE_ME_generate_with_openssl_rand"

# InfluxDB 2 Admin-Passwort und API Token
# Passwort: mind. 8 Zeichen
# Token generieren: openssl rand -hex 32
influxdb_admin_password: "CHANGE_ME_min_8_zeichen"
influxdb_admin_token: "CHANGE_ME_openssl_rand_hex_32"
```

---

### Task 3: Create PostgreSQL Helm values

**Files:**
- Create: `cluster/values/postgresql.yaml`

- [ ] **Step 1: Verify no existing postgresql values file exists**

```bash
ls cluster/values/
```

Expected: no `postgresql.yaml` listed.

- [ ] **Step 2: Create `cluster/values/postgresql.yaml`**

```yaml
---
# PostgreSQL Helm Values
# Chart: bitnami/postgresql vX.Y.Z  ← replace with version from Task 1
#
# auth.postgresPassword + auth.replicationPassword:
#   injected from 50_apps_infra.yml via all.sops.yml — not stored here.
#
# Storage: 5Gi Longhorn (default StorageClass — no storageClassName needed).
# Replicas: 0 read replicas (single primary, homelab workload).

auth:
  database: "postgres"

primary:
  persistence:
    enabled: true
    size: 5Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

readReplicas:
  replicaCount: 0
```

- [ ] **Step 3: Lint the values file**

```bash
helm lint cluster/values/postgresql.yaml 2>/dev/null || echo "values-only file, lint via template"
helm template postgresql bitnami/postgresql \
  --version X.Y.Z \
  -f cluster/values/postgresql.yaml \
  --set auth.postgresPassword=test \
  --set auth.replicationPassword=test \
  | head -40
```

Expected: YAML output with a StatefulSet for postgresql, no errors.

---

### Task 4: Create InfluxDB 2 Helm values

**Files:**
- Create: `cluster/values/influxdb2.yaml`

- [ ] **Step 1: Create `cluster/values/influxdb2.yaml`**

```yaml
---
# InfluxDB 2 Helm Values
# Chart: influxdata/influxdb2 vX.Y.Z  ← replace with version from Task 1
#
# adminUser.password + adminUser.token:
#   injected from 50_apps_infra.yml via all.sops.yml — not stored here.
#
# Storage: 10Gi Longhorn (default StorageClass).

adminUser:
  organization: "homelab"
  bucket: "default"
  retention_policy: "30d"

persistence:
  enabled: true
  size: 10Gi

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

- [ ] **Step 2: Render template to verify**

```bash
helm template influxdb2 influxdata/influxdb2 \
  --version X.Y.Z \
  -f cluster/values/influxdb2.yaml \
  --set adminUser.password=testpassword \
  --set adminUser.token=testtoken \
  | head -40
```

Expected: YAML output with a StatefulSet or Deployment for influxdb2, no errors.

---

### Task 5: Create Mosquitto Kubernetes manifests (inline in playbook)

Mosquitto is deployed as raw Kubernetes manifests (no Helm chart — k8s-at-home is archived). The manifests are defined inline in `50_apps_infra.yml` via `kubernetes.core.k8s`. A LoadBalancer Service exposes port 1883 on the node IP for LAN IoT devices; in-cluster services (HA) use `mosquitto.apps.svc.cluster.local:1883`.

**Files:**
- No separate file — manifests live inline in `50_apps_infra.yml` (next task).

- [ ] **Step 1: Note the mosquitto image tag from Task 1 research**

The Deployment will use `eclipse-mosquitto:2.0.X` — replace X with the tag found in Task 1.

---

### Task 6: Create `infra/playbooks/50_apps_infra.yml`

**Files:**
- Create: `infra/playbooks/50_apps_infra.yml`

- [ ] **Step 1: Create the playbook**

```yaml
---
# App Infrastructure: PostgreSQL 17, InfluxDB 2, Mosquitto 2
# Namespace: apps
#
# Voraussetzung: 30_longhorn.yml ausgeführt (Longhorn Default StorageClass)
# Voraussetzung: all.sops.yml enthält postgresql_password, postgresql_replication_password,
#                influxdb_admin_password, influxdb_admin_token
#
# Ausführen: ansible-playbook infra/playbooks/50_apps_infra.yml
- name: App Infrastructure — PostgreSQL, InfluxDB 2, Mosquitto
  hosts: k3s_server
  gather_facts: false
  run_once: true
  vars:
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/homelab.yaml"
    apps_namespace: apps

  tasks:
    # --- Namespace ---
    - name: Apps Namespace anlegen
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Namespace
          metadata:
            name: "{{ apps_namespace }}"
      delegate_to: localhost

    # --- PostgreSQL ---
    - name: Bitnami Helm Repo hinzufügen
      kubernetes.core.helm_repository:
        name: bitnami
        repo_url: https://charts.bitnami.com/bitnami
        binary_path: "{{ helm_binary }}"
      delegate_to: localhost

    - name: PostgreSQL deployen
      kubernetes.core.helm:
        name: postgresql
        chart_ref: bitnami/postgresql
        chart_version: "X.Y.Z"  # ← pin from Task 1
        release_namespace: "{{ apps_namespace }}"
        kubeconfig: "{{ kubeconfig }}"
        binary_path: "{{ helm_binary }}"
        values_files:
          - "{{ playbook_dir }}/../../cluster/values/postgresql.yaml"
        values:
          auth:
            postgresPassword: "{{ postgresql_password }}"
            replicationPassword: "{{ postgresql_replication_password }}"
        wait: true
        wait_timeout: "5m"
      delegate_to: localhost

    # --- InfluxDB 2 ---
    - name: InfluxData Helm Repo hinzufügen
      kubernetes.core.helm_repository:
        name: influxdata
        repo_url: https://helm.influxdata.com/
        binary_path: "{{ helm_binary }}"
      delegate_to: localhost

    - name: InfluxDB 2 deployen
      kubernetes.core.helm:
        name: influxdb2
        chart_ref: influxdata/influxdb2
        chart_version: "X.Y.Z"  # ← pin from Task 1
        release_namespace: "{{ apps_namespace }}"
        kubeconfig: "{{ kubeconfig }}"
        binary_path: "{{ helm_binary }}"
        values_files:
          - "{{ playbook_dir }}/../../cluster/values/influxdb2.yaml"
        values:
          adminUser:
            password: "{{ influxdb_admin_password }}"
            token: "{{ influxdb_admin_token }}"
        wait: true
        wait_timeout: "5m"
      delegate_to: localhost

    # --- Mosquitto (raw manifests — no Helm chart, k8s-at-home archived) ---
    - name: Mosquitto ConfigMap anlegen
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: mosquitto-config
            namespace: "{{ apps_namespace }}"
          data:
            mosquitto.conf: |
              listener 1883
              allow_anonymous true
              persistence true
              persistence_location /mosquitto/data/
              log_dest stdout
      delegate_to: localhost

    - name: Mosquitto PVC anlegen
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: mosquitto-data
            namespace: "{{ apps_namespace }}"
          spec:
            accessModes: [ReadWriteOnce]
            resources:
              requests:
                storage: 1Gi
      delegate_to: localhost

    - name: Mosquitto Deployment anlegen
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: mosquitto
            namespace: "{{ apps_namespace }}"
          spec:
            replicas: 1
            selector:
              matchLabels:
                app: mosquitto
            template:
              metadata:
                labels:
                  app: mosquitto
              spec:
                containers:
                  - name: mosquitto
                    image: "eclipse-mosquitto:2.0.X"  # ← pin from Task 1
                    ports:
                      - containerPort: 1883
                    volumeMounts:
                      - name: config
                        mountPath: /mosquitto/config
                      - name: data
                        mountPath: /mosquitto/data
                    resources:
                      requests:
                        cpu: 50m
                        memory: 64Mi
                      limits:
                        cpu: 200m
                        memory: 128Mi
                volumes:
                  - name: config
                    configMap:
                      name: mosquitto-config
                  - name: data
                    persistentVolumeClaim:
                      claimName: mosquitto-data
      delegate_to: localhost

    - name: Mosquitto Service anlegen
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Service
          metadata:
            name: mosquitto
            namespace: "{{ apps_namespace }}"
          spec:
            type: LoadBalancer
            selector:
              app: mosquitto
            ports:
              - port: 1883
                targetPort: 1883
                protocol: TCP
      delegate_to: localhost
```

- [ ] **Step 2: Ansible lint**

```bash
ansible-lint infra/playbooks/50_apps_infra.yml
```

Expected: no violations (or only warnings about `latest` — there is none here since versions are pinned).

- [ ] **Step 3: Dry-run against raspi5**

```bash
ansible-playbook infra/playbooks/50_apps_infra.yml --check --diff
```

Expected: tasks show as `changed` (namespace, repos, Helm releases, manifests). No errors. Note: Helm tasks may show "skipped" in check mode — that is expected behaviour.

---

### Task 7: Deploy and validate app infrastructure

- [ ] **Step 1: Pre-flight — confirm Longhorn is default StorageClass**

```bash
kubectl get storageclass
```

Expected: `longhorn` has `(default)` annotation. `local-path` does not.

- [ ] **Step 2: Deploy**

```bash
ansible-playbook infra/playbooks/50_apps_infra.yml
```

Expected: all tasks `ok` or `changed`, no failures. `PLAY RECAP` shows `failed=0`.

- [ ] **Step 3: Validate PostgreSQL**

```bash
kubectl get pods -n apps -l app.kubernetes.io/name=postgresql
```

Expected: `postgresql-0` in `Running` state, `1/1` ready.

```bash
kubectl exec -n apps postgresql-0 -- psql -U postgres -c "\l"
```

Expected: list of databases including `postgres`. (May need `-c "select 1"` first if psql isn't directly available — use `kubectl exec -n apps postgresql-0 -- env PGPASSWORD=<your-password> psql -U postgres -c "\l"`)

- [ ] **Step 4: Validate InfluxDB 2**

```bash
kubectl get pods -n apps -l app.kubernetes.io/name=influxdb2
```

Expected: pod in `Running` state, `1/1` ready.

```bash
kubectl port-forward -n apps svc/influxdb2 8086:8086 &
curl -s http://localhost:8086/ping
kill %1
```

Expected: HTTP 204 response from `/ping`.

- [ ] **Step 5: Validate Mosquitto**

```bash
kubectl get pods -n apps -l app=mosquitto
kubectl get svc -n apps mosquitto
```

Expected: pod `Running`, service shows `TYPE=LoadBalancer` with an `EXTERNAL-IP` (the node IP assigned by k3s ServiceLB).

```bash
# From your Mac on the LAN (install mosquitto-clients if needed: brew install mosquitto)
MQTT_IP=$(kubectl get svc -n apps mosquitto -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
mosquitto_sub -h $MQTT_IP -p 1883 -t test/# &
mosquitto_pub -h $MQTT_IP -p 1883 -t test/hello -m "world"
```

Expected: subscriber receives `world` on `test/hello`. Kill background sub with `kill %1`.

- [ ] **Step 6: Idempotency check**

```bash
ansible-playbook infra/playbooks/50_apps_infra.yml
```

Expected: `PLAY RECAP` shows `changed=0` (or only 1 for Helm repo update). `failed=0`.

---

## Part 2: Home Assistant (`51_homeassistant.yml`)

---

### Task 8: Create Home Assistant Helm values

**Files:**
- Create: `cluster/values/home-assistant.yaml`

- [ ] **Step 1: Create `cluster/values/home-assistant.yaml`**

```yaml
---
# Home Assistant Helm Values
# Chart: pajikos/home-assistant vX.Y.Z  ← replace with version from Task 1
#
# hostNetwork: true — required for mDNS/multicast LAN device auto-discovery.
# dnsPolicy must be ClusterFirstWithHostNet when hostNetwork is enabled.
#
# No Ingress — LAN access only via http://<node-ip>:8123
# (hostNetwork means port 8123 is directly on the node IP)
#
# Storage: 5Gi Longhorn PVC for /config (HA config, automations, history).
# No credentials in this file — HA manages its own users in /config.

hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet

env:
  - name: TZ
    value: "Europe/Zurich"

persistence:
  config:
    enabled: true
    size: 5Gi

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi

ingress:
  enabled: false
```

- [ ] **Step 2: Render template to verify hostNetwork is set**

```bash
helm template home-assistant pajikos/home-assistant \
  --version X.Y.Z \
  -f cluster/values/home-assistant.yaml \
  | grep -A2 "hostNetwork"
```

Expected: `hostNetwork: true` in the rendered Pod spec.

---

### Task 9: Create `infra/playbooks/51_homeassistant.yml`

**Files:**
- Create: `infra/playbooks/51_homeassistant.yml`

- [ ] **Step 1: Create the playbook**

```yaml
---
# Home Assistant in k3s
# Namespace: homeassistant
#
# Voraussetzung: 30_longhorn.yml ausgeführt (Longhorn Default StorageClass)
# Voraussetzung: 50_apps_infra.yml ausgeführt (Mosquitto läuft in apps namespace)
#
# Zugriff: http://<node-ip>:8123 (LAN only, hostNetwork)
# MQTT: mosquitto.apps.svc.cluster.local:1883 (anonym, in-cluster)
#
# Ausführen: ansible-playbook infra/playbooks/51_homeassistant.yml
- name: Home Assistant
  hosts: k3s_server
  gather_facts: false
  run_once: true
  vars:
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/homelab.yaml"
    ha_namespace: homeassistant

  tasks:
    # --- Namespace ---
    - name: homeassistant Namespace anlegen
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Namespace
          metadata:
            name: "{{ ha_namespace }}"
      delegate_to: localhost

    # --- Home Assistant ---
    - name: pajikos Helm Repo hinzufügen
      kubernetes.core.helm_repository:
        name: pajikos
        repo_url: https://pajikos.github.io/home-assistant-helm-chart/
        binary_path: "{{ helm_binary }}"
      delegate_to: localhost

    - name: Home Assistant deployen
      kubernetes.core.helm:
        name: home-assistant
        chart_ref: pajikos/home-assistant
        chart_version: "X.Y.Z"  # ← pin from Task 1
        release_namespace: "{{ ha_namespace }}"
        kubeconfig: "{{ kubeconfig }}"
        binary_path: "{{ helm_binary }}"
        values_files:
          - "{{ playbook_dir }}/../../cluster/values/home-assistant.yaml"
        wait: true
        wait_timeout: "5m"
      delegate_to: localhost
```

- [ ] **Step 2: Ansible lint**

```bash
ansible-lint infra/playbooks/51_homeassistant.yml
```

Expected: no violations.

- [ ] **Step 3: Dry-run**

```bash
ansible-playbook infra/playbooks/51_homeassistant.yml --check --diff
```

Expected: tasks show as `changed`, no errors.

---

### Task 10: Deploy and validate Home Assistant

- [ ] **Step 1: Deploy**

```bash
ansible-playbook infra/playbooks/51_homeassistant.yml
```

Expected: all tasks `ok` or `changed`. `PLAY RECAP` shows `failed=0`.

- [ ] **Step 2: Verify pod is running**

```bash
kubectl get pods -n homeassistant
```

Expected: `home-assistant-0` (or similar) in `Running` state, `1/1` ready.

- [ ] **Step 3: Verify hostNetwork and PVC**

```bash
kubectl get pod -n homeassistant -o jsonpath='{.items[0].spec.hostNetwork}'
```

Expected: `true`

```bash
kubectl get pvc -n homeassistant
```

Expected: PVC `Bound` to a Longhorn volume.

- [ ] **Step 4: Validate LAN access**

```bash
# Find node IP where HA pod is running
kubectl get pod -n homeassistant -o wide
```

Open in browser on the LAN: `http://<node-ip>:8123`

Expected: Home Assistant onboarding wizard appears ("Welcome to Home Assistant").

- [ ] **Step 5: Idempotency check**

```bash
ansible-playbook infra/playbooks/51_homeassistant.yml
```

Expected: `changed=0`, `failed=0`.

---

### Task 11: Cleanup, docs, and memory

**Files:**
- Modify: `infra/inventory/group_vars/all.yml`
- Modify: `docs/01-homelab-platform.md`
- Modify: `README.md`
- Modify: `OPERATIONS.md`
- Modify: `APPS.md`
- Modify: `.agent/memory.md`

- [ ] **Step 1: Remove obsolete `ha_host` from all.yml**

In `infra/inventory/group_vars/all.yml`, remove the `ha_host` variable and its comment block:

```yaml
# DELETE these two lines:
# ha_host: Node auf dem Docker + Home Assistant läuft (ausserhalb k3s)
# Gesetzt auf mba1 — kann bei Bedarf auf anderen Node geändert werden
ha_host: "mba1"
```

HA now runs in k3s (`homeassistant` namespace). The variable is no longer used.

- [ ] **Step 2: Invoke doc-auditor subagent**

Per CLAUDE.md Phase 5 requirement: invoke the `doc-auditor` subagent to check `README.md`, `OPERATIONS.md`, `CONTRIBUTING.md`, and `APPS.md`. Implement all changes it identifies.

Key expected updates:
- `README.md`: Mark M6 ✅ done in Milestones table
- `OPERATIONS.md`: Add runbooks for PostgreSQL, InfluxDB 2, Mosquitto, Home Assistant
- `APPS.md`: Update with deployed services and MQTT endpoint
- `docs/01-homelab-platform.md`: Note HA moved from Docker to k3s

- [ ] **Step 3: Add M6-DONE block to `.agent/memory.md`**

Insert a new block at the top of `.agent/memory.md` (above the M5-DONE block) following the established format:

```
[YYYY-MM-DD] M6-DONE — PostgreSQL 17 + InfluxDB 2 + Mosquitto 2 + Home Assistant in k3s
Worklog: .agent/worklogs/YYYYMMDD-HHMMSS-m6-apps-homeassistant-<rand4>.md
Was: 50_apps_infra.yml + 51_homeassistant.yml erstellt; 4 Services deployed
Entscheidungen:
  - Mosquitto: raw Kubernetes manifests (k8s-at-home Helm chart archived)
  - Mosquitto Service: LoadBalancer (k3s ServiceLB) → LAN-Zugriff auf Port 1883
  - Home Assistant: pajikos Helm chart, hostNetwork:true, namespace homeassistant
  - ha_host Variable aus all.yml entfernt (HA nicht mehr auf Docker/mba1)
  - MQTT auth + WSS endpoint: explizit Post-M6 deferred (→ memory)
Kritische Fallstricke: (fill in during implementation)
Offen:
  - Post-M6: mqtt.furchert.ch WSS + MQTT auth als Bundle
  - mba1/mba2 join (deferred seit M1)
  - raspi4 SSH tunnel
Status: done
```
