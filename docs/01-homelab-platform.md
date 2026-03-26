# Homelab Platform — Ansible IaC, k3s, wartbar, Tunnel-ready

## Kurzbeschreibung

Dieses Repository ist die **vollständige Infrastructure-as-Code Grundlage** für ein heterogenes Homelab-Cluster bestehend aus Raspberry Pis und MacBook Airs. Es provisioniert alle Nodes via **Ansible**, richtet ein **k3s-Cluster** ein und stellt eine stabile, erweiterbare Plattform bereit, auf der beliebige Workloads (Apps, DBs, Services) deployed werden können.

**Was dieses Repo ist:**
- IaC für OS-Provisioning, Hardening, k3s, Storage, Networking, Monitoring, Backups
- Betriebshandbuch für den laufenden Cluster-Betrieb
- Entwicklerdokumentation für Beiträge am Repo selbst
- Referenz und Einstiegspunkt für App-Deployments (Beispiel-Manifeste, Helm Values Templates)

**Was dieses Repo nicht ist:**
- App-Code oder App-spezifische Deployments (diese leben in eigenen Repos)
- CI/CD-Pipelines für Apps (diese liegen bei den jeweiligen App-Repos)

---

## Ziel

- **Homogene Baseline** für alle Nodes: OS, Users, SSH, Security, Mounts, Updates, Monitoring Agents.
- **k3s Cluster** inkl. Ingress, TLS, Observability, Backups.
- **Selbsterkennende Provisionierung**: Ein Playbook gegen alle Hosts — jeder Node erkennt via Ansible Facts (Arch, RAM, Hostname-Gruppe) was er tun muss. Keine manuelle Anpassung der Playbooks für neue Nodes.
- **Nahtloser Node-Join**: "Ubuntu installieren → Inventory ergänzen → Ansible run → fertig (<30 min)".
- **Workloads anywhere**: Dank Longhorn können DBs und Apps auf beliebigen Nodes laufen und bei Node-Ausfall automatisch migrieren.
- **Nicht überkomplizieren**: klare Defaults, minimaler Overhead, alles dokumentiert.

---

## Node Inventory

| Hostname | Hardware            | Arch  | RAM  | k3s-Rolle             | Besonderheiten              |
|----------|---------------------|-------|------|-----------------------|-----------------------------|
| `raspi5` | Raspberry Pi 5      | arm64 | 8 GB | Control-Plane + Worker | Backup-Target (USB/SSD)    |
| `raspi4` | Raspberry Pi 4      | arm64 | 4 GB | Worker                | —                           |
| `mba1`   | MacBook Air 2020 i5 | amd64 | 8 GB | Worker                | T2-Chip, Lid-close-Fix, Quad-Core |
| `mba2`   | MacBook Air 2019 i5 | amd64 | 8 GB | Worker                | T2-Chip, Lid-close-Fix, Dual-Core |

> ⚠️ **Vor M1 (MBAs):** T2-Chip Ubuntu-Kompatibilität auf beiden MBAs testen (`apple-bce` Modul, USB-C Ethernet empfohlen). Pi-Nodes sind bereits provisioniert.

> **`ha_host` gesetzt:** `mba1` — MacBook Air 2020 (8 GB, Quad-Core). Home Assistant läuft bewusst ausserhalb von k3s (Docker). Entscheidung getroffen in M1, abweichend von ursprünglicher Empfehlung (pi4), da mba1 mehr Ressourcen bietet.

**Netzwerk-Voraussetzungen:**
- Statische IPs oder DHCP-Reservierungen für alle Nodes (k3s erfordert stabile IPs)
- Intern offene Ports: `6443` (k3s API), `10250` (kubelet), `8472/UDP` (Flannel VXLAN), `2379-2380` (etcd), `9500-9502` (Longhorn)

---

## Wie die Selbsterkennung funktioniert

Ansible sammelt beim Start automatisch **Facts** über jeden Host:

```
ansible_architecture   → "aarch64" (Pi) oder "x86_64" (MBA)
ansible_memtotal_mb    → RAM
ansible_hostname       → "pi5", "mba1", ...
```

Die **Rolle** (Control-Plane vs. Worker) wird einmalig in `hosts.yml` via Gruppe gesetzt. Danach ist kein manueller Eingriff in Playbooks nötig:

- MBA-spezifische Tasks (Lid-close, T2-Fixes) laufen nur wenn `ansible_architecture == "x86_64"`
- arm64-spezifische Pakete nur wenn `ansible_architecture == "aarch64"`
- Control-Plane-Setup nur für die Gruppe `k3s_server`

**Neuen Node einbinden:** Hostname + IP in `hosts.yml`, Gruppe zuweisen, Playbooks ausführen — fertig.

---

## Scope

### In Scope
- Ansible: Base OS, Hardening, Storage Mounts, Docker (für HA), k3s, MBA-spezifische Tweaks
- k3s: 1 Control-Plane (Pi5) + 3 Worker, beliebig erweiterbar
- Storage: Longhorn als Default StorageClass (Replication Factor 2)
- Ingress/TLS: Traefik + cert-manager
- External Access: Cloudflare Tunnel (nur explizit freigegebene Subdomains)
- Observability: Prometheus + Grafana, optional Loki + Promtail
- Backups: Restic auf USB/SSD (an Pi5), DB-Dumps, Longhorn Snapshots
- Secrets: SOPS + age (verschlüsselt im Git)
- Dokumentation: Betriebshandbuch, Entwicklerdoku, App-Deployment-Referenz

### Out of Scope
- App-Code und App-Deployments (eigene Repos)
- Multi-arch CI/CD Pipelines (liegen bei App-Repos)
- Multi-Control-Plane HA
- Service Mesh, Vault, GitOps-Controller (ArgoCD/Flux)

---

## Fixierte Entscheidungen

| Thema          | Entscheidung                                 |
|----------------|----------------------------------------------|
| Tunnel         | Cloudflare Tunnel                            |
| Secrets        | SOPS + age                                   |
| Storage        | Longhorn (Replication Factor 2)              |
| Backup-Ziel    | Externer USB/SSD am Pi5, Restic              |
| Host-Detection | Ansible Facts (Arch, RAM) + Rolle via Gruppe |
| Home Assistant | Docker (nicht in k3s), `ha_host=mba1`        |
| DNS            | `furchert.ch` via Cloudflare DNS             |

---

## Tech Stack

### IaC / Provisioning
- **Ansible** (roles + inventory), idempotent, selbsterkennend via Facts
- **SOPS + age** — alle Secrets im Git verschlüsselt, kein Klartext

### Platform
- **k3s** (containerd)
- **Helm** (gepinnte Chart-Versionen)
- **Traefik** (Ingress, via k3s mitgeliefert, konfiguriert nicht ersetzt)
- **cert-manager** (TLS via Let's Encrypt)
- **Longhorn** (replizierter Block-Storage)
- Optional: MetalLB (bei Bedarf für LAN-interne LoadBalancer IPs)

### Observability
- Prometheus + Grafana (`kube-prometheus-stack`)
- Optional: Loki + Promtail (Logs)
- Alertmanager

### Storage / Backup
- StorageClass: **Longhorn** (Default, Replication Factor 2)
- DB-Backups: `pg_dump` / `influxd backup` → Restic → USB/SSD am Pi5
- PV-Backups: Longhorn Snapshots + Restic für kritische Volumes
- Cluster-Config: Git (vollständige IaC, kein manueller State)

### External Access
- **Cloudflare Tunnel** (cloudflared als Deployment im Cluster)
- Tunnel → Traefik Ingress → nur explizit konfigurierte Services
- Alles andere bleibt intern unerreichbar

### Gepinnte Versionen (bei Projektstart zu befüllen)

| Komponente            | Version |
|-----------------------|---------|
| k3s                   | v1.32.2+k3s1 |
| Longhorn              | 1.7.2        |
| cert-manager          | v1.17.1      |
| kube-prometheus-stack | 69.3.1       |
| cloudflared           | 2025.2.1     |

---

## Zielarchitektur

```
LAN
 ├─ pi5 (arm64, 8GB) — k3s Control-Plane + Worker
 │   ├─ k3s API Server, etcd, scheduler
 │   ├─ ns/platform: traefik, cert-manager, cloudflared
 │   ├─ ns/longhorn-system: longhorn (Helm-Chart-Konvention)
 │   ├─ ns/monitoring: prometheus, grafana, alertmanager
 │   ├─ ns/apps: Workloads (via Longhorn frei migrierbar)
 │   └─ Backup-Target: USB/SSD (Restic)
 │
 ├─ pi4 (arm64, 4GB) — k3s Worker
 │   ├─ Longhorn Replica Storage
 │   ├─ Workloads
 │   └─ Docker: Home Assistant (TBD)
 │
 ├─ mba1 (amd64, 8GB) — k3s Worker
 │   ├─ Longhorn Replica Storage
 │   └─ Workloads (Multi-arch Images Pflicht in App-Repos)
 │
 └─ mba2 (amd64, 8GB, Dual-Core) — k3s Worker
     ├─ Longhorn Replica Storage
     └─ Workloads

Internet → Cloudflare Tunnel → cloudflared (Cluster) → Traefik → explizite Services
```

---

## Repository-Struktur (Endprodukt)

```
homelab/                         ← GitHub Repo Root
│
├─ README.md                     ← Überblick, Architektur, Quick Start, Voraussetzungen
├─ OPERATIONS.md                 ← Betriebshandbuch (Runbooks, Upgrades, Monitoring)
├─ CONTRIBUTING.md               ← Entwicklerdokumentation (Setup, Testing, PR-Prozess)
├─ APPS.md                       ← App-Deployment Guide + Beispiele
│
├─ infra/                        ← Ansible
│   ├─ inventory/
│   │   ├─ hosts.yml             ← alle Nodes (IP, Hostname, Gruppe = Rolle)
│   │   └─ group_vars/
│   │       ├─ all.yml           ← gemeinsame Variablen (NTP, Timezone, User)
│   │       ├─ k3s_server.yml    ← Control-Plane spezifisch
│   │       ├─ k3s_agent.yml     ← Worker spezifisch
│   │       ├─ mac.yml           ← MBA-spezifische Overrides
│   │       └─ docker_hosts.yml  ← HA-Node
│   ├─ roles/
│   │   ├─ base/                 ← OS, User, SSH, NTP, unattended-upgrades
│   │   ├─ hardening/            ← UFW, fail2ban, SSH hardening
│   │   ├─ storage/              ← Mount-Points, Restic-Setup
│   │   ├─ docker/               ← Docker CE (nur HA-Node)
│   │   ├─ k3s/                  ← k3s install (server + agent, idempotent)
│   │   ├─ longhorn_prereqs/     ← open-iscsi, nfs-common, Kernel-Module
│   │   ├─ observability_agent/  ← Node Exporter
│   │   └─ mac_tweaks/           ← HandleLidSwitch=ignore, T2-Fixes, USB-C Ethernet
│   └─ playbooks/
│       ├─ 00_bootstrap.yml      ← python3, ansible-user, SSH key, sudo
│       ├─ 10_base.yml           ← base + hardening + storage
│       ├─ 20_k3s.yml            ← k3s server → agents joinen
│       ├─ 30_longhorn.yml       ← Longhorn Helm Chart + Default StorageClass
│       └─ 40_platform.yml       ← cert-manager, traefik, cloudflared, monitoring
│
├─ cluster/                      ← Helm / Kubernetes
│   ├─ platform/
│   │   ├─ cert-manager/
│   │   ├─ longhorn/
│   │   ├─ cloudflared/
│   │   └─ monitoring/
│   └─ values/                   ← Helm Values (gepinnt, versioniert)
│
└─ examples/                     ← App-Deployment Referenz
    ├─ simple-deployment.yml     ← minimales Deployment + Service + Ingress
    ├─ with-postgres.yml         ← App + Postgres + PVC
    ├─ with-ingress-public.yml   ← Cloudflare-fähiges Ingress Pattern
    └─ helm-values-template.yml  ← Startpunkt für eigene Helm Values
```

---

## Node Onboarding

### Raspberry Pi (arm64)
1. Ubuntu Server 24.04 LTS installieren, Hostname setzen, SSH Key hinterlegen
2. Statische IP / DHCP-Reservierung sicherstellen
3. Node in `hosts.yml` eintragen (IP, Gruppe)
4. `ansible-playbook playbooks/00_bootstrap.yml -l <node>`
5. `ansible-playbook playbooks/10_base.yml -l <node>`
6. `ansible-playbook playbooks/20_k3s.yml -l <node>` (joined automatisch als Agent)
7. `kubectl get nodes` → Node erscheint als Ready

**Ziel: <30 Minuten von frischem Ubuntu bis joined**

### MacBook Air (amd64) — zusätzliche Schritte vor Schritt 1
- Ubuntu 24.04 Server installieren (`modprobe apple-bce` im Installer erforderlich)
- USB-C Ethernet Adapter verwenden (WiFi auf T2 unter Linux nicht empfohlen)
- Ab Schritt 4: `mac_tweaks` Role läuft automatisch via Gruppe `mac`

---

## Dokumentation als Bestandteil des Repos

Das Repo ist erst fertig wenn alle vier Dokumente vollständig sind:

| Dokument         | Inhalt                                                                   | Zielgruppe     |
|------------------|--------------------------------------------------------------------------|----------------|
| `README.md`      | Überblick, Architektur, Quick Start, Voraussetzungen                     | Alle           |
| `OPERATIONS.md`  | Runbooks, Upgrade-Prozess, Monitoring, Backup/Restore, Troubleshooting   | Betreiber      |
| `CONTRIBUTING.md`| Lokale Entwicklungsumgebung, Ansible-Testing, PR-Prozess, Code Style     | Entwickler     |
| `APPS.md`        | App-Deployment-Guide, Namespace-Konventionen, Ingress-Pattern, Secrets   | App-Entwickler |

Jeder Meilenstein hat ein konkretes Dokumentations-Deliverable — Runbooks entstehen parallel zum Code, nicht am Ende.

---

## Betrieb (→ Details in OPERATIONS.md)

- **Pinned Versions**: k3s, Helm Charts — alle in Git, kein `latest` in Betrieb
- **Upgrade-Prozess**: Monitoring grün → Node drainieren → upgrade → rejoin → weiter (manuell, siehe OPERATIONS.md)
- **Rollback**: `helm rollback <release>` für Charts; k3s via gepinnter Ansible-Version
- **Geplant (post-M5)**: Automatisiertes Update-Skript mit Integrationstests und automatischem Rollback — siehe "Erweiterungen" unten
- **Runbooks vorhanden für:**
  - Node reboot / Drain & Upgrade
  - Longhorn Volume voll / Replica degraded
  - cert-manager Renewal-Fehler
  - Cloudflare Tunnel outage
  - Restic Backup-Fehler / Restore-Prozess
  - MBA: Lid-close-Reboot-Problem

---

## Entwicklung (→ Details in CONTRIBUTING.md)

- Lokale Entwicklungsumgebung: Ansible, kubectl, Helm, SOPS, age
- Ansible-Testing: `ansible-lint`, `--check` Mode vor jedem PR
- Secrets: age-Key lokal einrichten, nie ins Repo committen
- PR-Prozess: Feature Branch → PR → Review → Merge
- Idempotenz-Anforderung: Jede Role muss mehrfach ausführbar sein ohne Seiteneffekte

---

## Security Baseline

- SSH keys only, `PasswordAuthentication no`
- UFW: nur dokumentierte Ports offen
- Namespaces getrennt: `platform`, `monitoring`, `apps`
- RBAC: Service Accounts pro Namespace, keine cluster-admin Rechte für App-Pods
- Secrets: SOPS + age — kein Klartext im Git, age-Key ausserhalb des Repos aufbewahren
- Externe Exponierung **ausschließlich** via Cloudflare Tunnel
- Longhorn Dashboard: nur intern, kein öffentlicher Ingress

---

## Meilensteine

| #  | Inhalt                                                       | Technisches Deliverable                                              | Doku-Deliverable                        |
|----|--------------------------------------------------------------|----------------------------------------------------------------------|-----------------------------------------|
| M1 | Ansible baseline & hardening auf allen 4 Nodes              | Alle Nodes rebuild-bar, inkl. MBA T2-Fixes und Lid-close             | README fertig, CONTRIBUTING.md Entwurf |
| M2 | k3s + Traefik + cert-manager + Cloudflare Tunnel            | `*.furchert.ch` mit TLS, interner Traffic bleibt intern              | OPERATIONS.md: Tunnel-Runbook          |
| M3 | Longhorn deployed + Replication + Failover getestet         | Node offline → PV bleibt verfügbar, dokumentierter Failover-Test     | OPERATIONS.md: Storage-Runbook         |
| M4 | Monitoring + Backups + Restore-Test                         | Grafana zeigt alle 4 Nodes, Restore einer DB erfolgreich             | OPERATIONS.md: Backup/Restore-Runbook  |
| M5 | Plattform produktionsreif + alle Dokumente vollständig      | `examples/` fertig, alle 4 Docs reviewed, APPS.md vollständig        | Alle Dokumente abgenommen              |

---

## Definition of Done

- [ ] Vollständiger Rebuild eines beliebigen Nodes via Ansible möglich (inkl. MBA)
- [ ] Node-Join <30 Minuten (ohne Datenmigration)
- [ ] Longhorn Failover-Test bestanden (Node offline → PVs weiter verfügbar)
- [ ] Restore-Test für eine DB (Restic → Restore) dokumentiert und erfolgreich
- [ ] Cloudflare Tunnel: nur explizit konfigurierte Subdomains erreichbar
- [ ] Alle Secrets via SOPS verschlüsselt, kein Klartext im Git
- [ ] `README.md`, `OPERATIONS.md`, `CONTRIBUTING.md`, `APPS.md` vollständig
- [ ] `examples/` enthält mindestens 3 funktionierende Referenz-Manifeste
- [ ] Monitoring zeigt alle 4 Nodes grün, Alerting konfiguriert

---

## Erweiterungen (post-M5)

Ideen und geplante Verbesserungen die bewusst aus dem M1–M5-Scope ausgeschlossen sind.
Erst angehen wenn die Definition of Done vollständig erfüllt ist.

### Cloudflare Access Policy für SSH (Zero Trust)

**Aktuell:** SSH via Cloudflare Tunnel ist eingerichtet (`ssh://` Protokoll + `cloudflared access ssh` ProxyCommand).
Schutz: Cloudflare Tunnel-Token + SSH Key Auth.

**Ziel post-M5:** Cloudflare Zero Trust Access Policy als zweite Authentifizierungsschicht:
- Nur autorisierte E-Mail-Adressen / Identity Provider erhalten Zugang
- Policy über Cloudflare Dashboard oder Terraform (cloudflare/cloudflare Provider) automatisiert
- Kurzlebige SSH-Zertifikate (Cloudflare-signiert) statt statischer Keys möglich

**Minimal-Umsetzung:**
1. Zero Trust → Access → Applications → SSH-App für `ssh.furchert.ch` anlegen
2. Policy: Email `*@furchert.ch` oder spezifische Adresse
3. `cloudflare_access_application` Terraform-Resource für Automatisierung

### Automatisiertes Update-Skript mit Integrationstests + Rollback

**Ziel:** Ein einzelnes Skript (`scripts/update.sh` o.ä.) das alle Komponenten (k3s, Helm Charts)
in der richtigen Reihenfolge aktualisiert, danach Integrationstests ausführt und bei Fehler
automatisch rollback auslöst.

**Ablauf (Entwurf):**
1. Pre-flight: alle Nodes Ready, Longhorn-Volumes healthy, Monitoring grün
2. k3s upgrade: CP zuerst → Worker nacheinander (drain → upgrade → uncordon → wait Ready)
3. Helm Chart upgrades: version bump in `cluster/values/`, `helm upgrade`, wait rollout
4. Integrationstests:
   - `kubectl get nodes` — alle Ready
   - `kubectl get pods -A` — kein CrashLoopBackOff, kein Pending
   - Longhorn: alle Volumes healthy, RF=2
   - cert-manager: ClusterIssuer Ready, kein abgelaufenes Zertifikat
   - Cloudflare Tunnel: Pod Running, DNS-Auflösung für eine bekannte Subdomain
   - Smoke-Test: HTTP-Request gegen eine bekannte URL → HTTP 200
5. Bei Test-Fehler: automatischer Rollback (Helm: `helm rollback`, k3s: `k3s_version` zurücksetzen + Playbook)
6. Benachrichtigung (optional): Webhook / E-Mail bei Erfolg oder Fehler

**Anforderungen:**
- Idempotent: mehrfach ausführbar ohne Seiteneffekte
- Dry-run Modus: zeigt was getan würde ohne Änderungen
- Jede Phase explizit loggbar (Worklog-kompatibel)
- Kein externes CI/CD erforderlich — läuft lokal auf dem Betreiber-Mac
