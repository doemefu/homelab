# OPERATIONS.md — Betriebshandbuch

Dieses Dokument enthält Runbooks für den laufenden Cluster-Betrieb.

> **Stand:** M5 (k3s + Cloudflare + Longhorn + Monitoring + Backup + Alertmanager IRM + Grafana PVC) — wird mit jedem Milestone ergänzt.

---

## Kubeconfig

```bash
# Einmalig in ~/.zshrc oder ~/.zprofile:
export KUBECONFIG=~/.kube/homelab.yaml
```

Alle kubectl-Befehle in diesem Dokument setzen `KUBECONFIG` als gesetzt voraus.
Alternativ: `kubectl --kubeconfig ~/.kube/homelab.yaml <befehl>`

---

## Inhaltsverzeichnis

- [Cluster Health](#cluster-health)
- [Ports & Firewall](#ports--firewall)
- [k3s Upgrade](#k3s-upgrade)
- [Node Drain & Reboot](#node-drain--reboot)
- [cert-manager / TLS](#cert-manager--tls)
- [SSH-Zugriff (remote, via Cloudflare Tunnel)](#ssh-zugriff-remote-via-cloudflare-tunnel)
- [Cloudflare Tunnel](#cloudflare-tunnel)
- [Longhorn Storage](#longhorn-storage)
- [Monitoring (Prometheus + Grafana)](#monitoring-prometheus--grafana)
- [Backup (Restic)](#backup-restic)

---

## Cluster Health

Schnellcheck nach Änderungen oder bei Problemen:

```bash
# Nodes + IPs
kubectl get nodes -o wide

# Alle Pods (Überblick über alle Namespaces)
kubectl get pods -A

# Aktuelle Events — nützlich für Fehlerdiagnose
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Namespace-Übersicht
kubectl get ns
```

Erwartete Pods pro Namespace nach M5:

| Namespace        | Pods |
|------------------|------|
| `kube-system`    | traefik, coredns, metrics-server, svclb-* |
| `platform`       | cert-manager (3x), cloudflared |
| `longhorn-system`| longhorn-manager (2x), longhorn-ui (2x), csi-*, engine-image, instance-manager |
| `monitoring`     | prometheus-*, grafana-*, alertmanager-*, kube-state-metrics-*, node-exporter-* (DaemonSet, 1 pro Node) |

---

## Ports & Firewall

UFW-Regeln werden von der `hardening`-Rolle gesetzt. Alle eingehenden Verbindungen sind standardmässig blockiert; folgende Ports sind explizit geöffnet:

| Port(s)     | Protokoll | Zweck                              | Scope    |
|-------------|-----------|-------------------------------------|----------|
| 22          | TCP       | SSH                                 | LAN only |
| 6443        | TCP       | k3s API Server                      | LAN only |
| 10250       | TCP       | kubelet metrics                     | LAN only |
| 8472        | UDP       | Flannel VXLAN Overlay               | LAN only |
| 2379–2380   | TCP       | etcd (nur Control-Plane)            | LAN only |
| 9500–9502   | TCP       | Longhorn Replikation                | LAN only |
| 9100        | TCP       | Node Exporter (Prometheus Scrape)   | LAN only |

> Port-Forward-Befehle (z.B. `kubectl port-forward ... 9090:9090`) laufen lokal und erfordern keine UFW-Änderungen.

---

## k3s Upgrade

> ⚠️ Dieses Repo managed das k3s Binary und die systemd-Units manuell (kein Installer-Skript).
> Damit hast du volle Kontrolle über Versionen, aber volle Verantwortung für Upgrades.

### Vorbereitung

1. [k3s Changelog](https://github.com/k3s-io/k3s/releases) lesen — Breaking Changes prüfen
2. Monitoring grün? `kubectl get nodes` — alle Ready
3. Longhorn-Volumes healthy? `kubectl get -n longhorn-system volumes` (ab M3)

### Upgrade-Ablauf (ein Node nach dem anderen)

**Schritt 1 — Version in group_vars aktualisieren**

```yaml
# infra/roles/k3s/defaults/main.yml
k3s_version: "vX.Y.Z+k3s1"  # neue Version eintragen
```

**Schritt 2 — Control-Plane upgraden**

```bash
# Node drainieren (Workloads auf andere Nodes verschieben)
kubectl drain raspi5 --ignore-daemonsets --delete-emptydir-data

# Playbook nur auf Control-Plane ausführen
ansible-playbook infra/playbooks/20_k3s.yml -l raspi5

# Node wieder freigeben
kubectl uncordon raspi5

# Warten bis Ready
kubectl get nodes -w
```

**Schritt 3 — Worker nacheinander upgraden**

```bash
# Für jeden Worker (raspi4, mba1, mba2):
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ansible-playbook infra/playbooks/20_k3s.yml -l <node>
kubectl uncordon <node>
kubectl get nodes -w  # Ready abwarten bevor nächster Node
```

### Rollback

Das Binary wird nur ersetzt wenn die Version im Playbook von der installierten abweicht.
Für Rollback: `k3s_version` auf die alte Version setzen und Playbook erneut ausführen.

```bash
# Aktuelle Version auf Node prüfen
ansible all -m command -a "k3s --version"
```

> ⚠️ **systemd-Unit-Templates prüfen:** Nach k3s Major-Upgrades können sich Flags ändern.
> `infra/roles/k3s/templates/k3s-server.service.j2` und `k3s-agent.service.j2` gegen
> aktuelle k3s-Doku abgleichen bevor das Upgrade ausgeführt wird.

> 💡 **Geplant (post-M5):** Automatisiertes Update-Skript mit Integrationstests und automatischem
> Rollback — deckt k3s + alle Helm Charts ab. Details im Projektblatt (`docs/01-homelab-platform.md`,
> Abschnitt "Erweiterungen"). Bis dahin gilt der manuelle Ablauf oben.

---

## Node Drain & Reboot

```bash
# Node drainieren
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# Reboot via Ansible
ansible <node> -m reboot --become

# Node wieder freigeben
kubectl uncordon <node>
```

---

## cert-manager / TLS

### Status prüfen

```bash
# ClusterIssuers — beide müssen READY=True sein
kubectl get clusterissuer

# Alle Zertifikate
kubectl get cert -A

# Details zu einem Zertifikat (ACME Challenge-Fehler, Renewal-Status)
kubectl describe cert <name> -n <namespace>

# CertificateRequests (aktive ACME-Anfragen)
kubectl get certificaterequest -A
```

### Zertifikat manuell erneuern

```bash
# Annotation triggert sofortige Renewal
kubectl annotate cert <name> -n <namespace> \
  cert-manager.io/issue-temporary-certificate="true" --overwrite

# Oder: Certificate löschen — cert-manager erstellt es automatisch neu
kubectl delete cert <name> -n <namespace>
```

### DNS-01 Challenge hängt

```bash
# Challenge-Status prüfen
kubectl get challenge -A
kubectl describe challenge <name> -n <namespace>

# Häufige Ursache: Cloudflare API Token abgelaufen → Secret prüfen
kubectl get secret cloudflare-api-token -n platform -o yaml
```

---

## SSH-Zugriff (remote, via Cloudflare Tunnel)

SSH auf die Nodes ist von ausserhalb des LANs via Cloudflare Tunnel möglich.
Der Zugriff läuft über `cloudflared access ssh` als ProxyCommand — kein direkter Port-Forward, kein öffentlicher SSH-Port.

### Einmaliges Setup (Client)

```bash
# cloudflared lokal installieren (falls noch nicht vorhanden)
brew install cloudflared
```

SSH-Config (`~/.ssh/config`) ergänzen:

```
Host raspi5
  HostName ssh.furchert.ch
  User ubuntu
  IdentityFile ~/.ssh/new_home
  ProxyCommand cloudflared access ssh --hostname %h

Host raspi4
  HostName ssh-raspi4.furchert.ch
  User ubuntu
  IdentityFile ~/.ssh/new_home
  ProxyCommand cloudflared access ssh --hostname %h
```

### Tunnel-Ingress einrichten (Ansible, einmalig oder bei Änderung)

Ingress-Regeln werden via Cloudflare API gesetzt — kein manuelles Dashboard-Klicken.
Single Source of Truth: `infra/playbooks/40_platform.yml` (uri-Task, PUT-Request).

```bash
ansible-playbook infra/playbooks/40_platform.yml
```

Der Task ist idempotent: ein zweiter Lauf erzeugt keine Änderung.
Neue Services ergänzen: Ingress-Liste im Playbook erweitern, dann Playbook erneut ausführen.

### Verbinden

```bash
ssh raspi5             # via ~/.ssh/config
ssh raspi4             # via ~/.ssh/config

# Oder direkt:
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.furchert.ch" ubuntu@ssh.furchert.ch
```

### Hinweis: Cloudflare Access Policy (post-M5)

Aktuell schützt nur der SSH-Key den Zugriff. Eine Cloudflare Zero Trust Access Policy
(E-Mail-Verifizierung o.ä. als zweite Schicht) ist als post-M5 Erweiterung geplant.

---

## Cloudflare Tunnel

### Tunnel-Status prüfen

```bash
# Pod-Status
kubectl -n platform get pods -l app=cloudflared

# Logs
kubectl -n platform logs -l app=cloudflared --tail=50
```

### Neuen Service exponieren

1. Ingress-Eintrag in `infra/playbooks/40_platform.yml` (uri-Task) vor dem `http_status:404`-Fallback ergänzen:

```yaml
ingress:
  - hostname: ssh.furchert.ch
    service: ssh://192.168.1.61:22
  - hostname: grafana.furchert.ch
    service: http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80
  - service: http_status:404  # immer zuletzt
```

2. Playbook ausführen:

```bash
ansible-playbook infra/playbooks/40_platform.yml
```

3. cloudflared Pod neustarten (liest Ingress-Config nur beim Start):

```bash
kubectl -n platform rollout restart deployment/cloudflared-cloudflare-tunnel-remote
kubectl -n platform rollout status deployment/cloudflared-cloudflare-tunnel-remote
```

4. Falls neue Subdomain: DNS CNAME anlegen (Cloudflare Dashboard → DNS):
   - Type: `CNAME`, Name: `<subdomain>`, Target: `<tunnel-id>.cfargotunnel.com`, Proxy: enabled

### Tunnel neu erstellen (Notfall)

```bash
# Alten Tunnel löschen
cloudflared tunnel delete homelab

# Neuen Tunnel erstellen
cloudflared tunnel create homelab
cloudflared tunnel token homelab  # Token in all.sops.yml aktualisieren

# Secret neu verschlüsseln
sops -e -i infra/inventory/group_vars/all.sops.yml

# Cloudflared neu deployen
ansible-playbook infra/playbooks/40_platform.yml
```

---

## Longhorn Storage

### Longhorn UI aufrufen (intern only)

Longhorn ist nicht öffentlich exponiert. Zugriff via Port-Forward:

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# → http://localhost:8080
```

### Status prüfen

```bash
# Alle Pods
kubectl get pods -n longhorn-system

# Volumes und Replikation
kubectl get volumes -n longhorn-system

# StorageClass — longhorn muss default (true), local-path non-default (false) sein
kubectl get storageclass
```

### Root-Disk Monitoring (SD-Karten-Verschleiss)

> ⚠️ **Risiko:** Longhorn schreibt permanent auf `/var/lib/longhorn` (Root-SD-Karte der Pis).
> Empfehlung post-M3: Externe SSDs für Longhorn-Volumes konfigurieren.

```bash
# Freien Speicher auf Root-Disk prüfen (min. 10GB empfohlen)
ansible raspi5,raspi4 -m command -a "df -h /" --private-key ~/.ssh/new_home

# Longhorn Node Storage Status im UI prüfen: http://localhost:8080 → Node
```

### local-path nach k3s-Neustart/Upgrade wieder non-default

> **Bekannte Einschränkung:** k3s verwaltet local-path als Roh-Manifest, nicht als HelmChart.
> Nach k3s-Neustart oder -Upgrade wird der Patch möglicherweise zurückgesetzt
> (`local-path` erscheint wieder als Default-StorageClass).

Beheben:

```bash
ansible-playbook infra/playbooks/30_longhorn.yml
```

Dieser Schritt gehört zur Nachbearbeitung eines jeden k3s-Upgrades (nach dem Upgrade-Ablauf oben).

### Replica degraded

Wenn ein Node offline geht, reduziert Longhorn automatisch auf die verbleibenden Replicas.
Nach Rejoin des Nodes rebuilt Longhorn automatisch auf den konfigurierten Replication Factor (2).

```bash
# Rebuild-Status verfolgen
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# → http://localhost:8080 → Volumes → degradierte Volumes anklicken
```

### Volume voll

```bash
# Volume-Liste mit Kapazität
kubectl get volumes -n longhorn-system -o wide

# Volume-Kapazität im Longhorn UI erhöhen (Volumes → Volume → Expand)
# Alternativ: PVC patchen
kubectl patch pvc <name> -n <namespace> -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
```

---

## Monitoring (Prometheus + Grafana)

kube-prometheus-stack v69.3.1 läuft im `monitoring` Namespace.
Grafana: https://grafana.furchert.ch (Login: admin / Passwort aus `all.sops.yml: grafana_admin_password`)

> `grafana_admin_password` ist in `infra/inventory/group_vars/all.sops.yml` (SOPS-verschlüsselt).

> **Hinweis:** Node Exporter wird als DaemonSet via kube-prometheus-stack ausgerollt
> (`nodeExporter` subchart in `cluster/values/kube-prometheus-stack.yaml`).
> Die Ansible-Rolle `observability_agent/` ist Platzhalter für standalone Node Exporter auf Nodes
> ausserhalb des Clusters (post-M5).

### Status prüfen

```bash
kubectl get pods -n monitoring

# Erwartete Pods nach M4:
# kube-prometheus-stack-grafana-*                      1/1 Running
# kube-prometheus-stack-kube-state-metrics-*           1/1 Running
# kube-prometheus-stack-operator-*                     1/1 Running
# kube-prometheus-stack-prometheus-node-exporter-*     1/1 Running  (DaemonSet, alle Nodes)
# alertmanager-kube-prometheus-stack-alertmanager-0    2/2 Running
# prometheus-kube-prometheus-stack-prometheus-0        2/2 Running

kubectl get pvc -n monitoring
# prometheus-kube-prometheus-stack-prometheus-db-... → Bound (10Gi, Longhorn)
# kube-prometheus-stack-grafana                       → Bound (1Gi,  Longhorn)
```

### Grafana aufrufen

```bash
# Öffentlich via Cloudflare Tunnel (nach DNS CNAME gesetzt):
open https://grafana.furchert.ch

# Intern via Port-Forward:
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# → http://localhost:3000 | Login: admin / <grafana_admin_password>
```

### Prometheus + Alertmanager intern

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090

kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# → http://localhost:9093
```

### Prometheus PVC Kapazität erweitern

```bash
kubectl patch pvc \
  prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
  -n monitoring \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

### Grafana PVC Kapazität erweitern

```bash
kubectl patch pvc kube-prometheus-stack-grafana \
  -n monitoring \
  -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
```

### Alertmanager — Discord Receiver

Alertmanager sendet Alerts direkt an einen Discord-Kanal via nativen `discord_configs` Receiver.

**Ersteinrichtung (einmalig):**

1. Discord öffnen → Ziel-Server → Kanal-Einstellungen (⚙️) → Integrationen → Webhooks
2. **Neuer Webhook** → Name vergeben (z.B. `Alertmanager`) → URL kopieren
   Format: `https://discord.com/api/webhooks/XXXXXXXXXX/YYYYYYYY`
3. URL in SOPS eintragen:
   ```bash
   sops infra/inventory/group_vars/all.sops.yml
   # Zeile einfügen:
   # alertmanager_discord_webhook_url: "https://discord.com/api/webhooks/..."
   ```
4. Playbook ausführen (nur über LAN, nicht via SSH-Tunnel — bekanntes Timeout-Risiko):
   ```bash
   ansible-playbook infra/playbooks/40_platform.yml
   ```

**Status prüfen:**

```bash
# Alertmanager-Konfiguration anzeigen
kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093 &
curl -s http://localhost:9093/api/v2/status | python3 -m json.tool
# "receivers" sollte "discord" enthalten

# Test-Alert senden (erscheint im Discord-Kanal)
curl -s -X POST http://localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"info"},"annotations":{"summary":"M5 test"}}]'
```

**Webhook-URL ändern:**

1. URL in SOPS aktualisieren: `sops infra/inventory/group_vars/all.sops.yml`
2. `ansible-playbook infra/playbooks/40_platform.yml`

**Alertmanager-Konfigurationsstruktur** (in `infra/playbooks/40_platform.yml`):
- Route: `group_by: [alertname, namespace]`, `repeat_interval: 12h`
- Receiver: `discord` (discord_configs, `send_resolved: true`)
- Inhibit-Rules: Standard kube-prometheus-stack (critical suppresst warning/info bei gleichem alertname+namespace)

### Upgrade kube-prometheus-stack

```bash
# chart_version in 40_platform.yml aktualisieren, dann:
ansible-playbook infra/playbooks/40_platform.yml
```

> **Grafana PVC:** Grafana persistence ist aktiviert (1Gi Longhorn PVC).
> Beim Upgrade bleibt der PVC erhalten — kein Datenverlust. Prüfen:
> `kubectl get pvc -n monitoring` → `kube-prometheus-stack-grafana` muss Bound bleiben.

---

## Backup (Restic)

Täglich 03:00 auf raspi5. Repository: `/var/lib/backup/restic-repo` (interim auf Root-SD-Karte).

> **Hinweis:** Backup-Repository liegt interim auf der Root-SD-Karte (`/var/lib/backup`).
> Follow-up: Nach Anschluss der externen SSD das Repository auf `/mnt/backup/restic-repo` umziehen (Prozess unten).

### Backup-Status prüfen

```bash
# Letzter Lauf (systemd journal)
ssh raspi5 "journalctl -t homelab-backup --since '24 hours ago'"

# Snapshots auflisten
ssh raspi5 "sudo restic snapshots \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"

# Integrität prüfen
ssh raspi5 "sudo restic check \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"
```

### Manueller Backup-Lauf

```bash
ssh raspi5 "sudo /usr/local/bin/homelab-backup.sh"
```

### Restore

Restore-Prozess (dokumentiert; vollständige Ausführung deferred bis externer SSD angeschlossen):

**Schritt 1 — Snapshots anzeigen:**

```bash
ssh raspi5 "sudo restic snapshots \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password"
# Ausgabe: Snapshot-ID, Datum, Backup-Pfade
```

**Schritt 2 — Restore-Test (nicht-destruktiv, in /tmp):**

```bash
# Einzelnes Verzeichnis in /tmp/restore-test wiederherstellen
ssh raspi5 "sudo restic restore latest \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /tmp/restore-test"

# Inhalt prüfen (k3s etcd-Snapshots sollten vorhanden sein)
ssh raspi5 "ls -lh /tmp/restore-test/var/lib/rancher/k3s/server/db/snapshots/"

# Aufräumen
ssh raspi5 "sudo rm -rf /tmp/restore-test"
```

**Schritt 3 — Gezielter Restore (einzelne Datei):**

```bash
ssh raspi5 "sudo restic restore <snapshot-id> \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /tmp/restore \
  --include /var/lib/rancher/k3s/server/db/snapshots"
```

**Schritt 4 — Vollständiger Restore (Disaster Recovery, Vorsicht: überschreibt Dateien):**

```bash
# Nur ausführen wenn k3s gestoppt und Node frisch provisioniert
ssh raspi5 "sudo systemctl stop k3s"
ssh raspi5 "sudo restic restore <snapshot-id> \
  --repo /var/lib/backup/restic-repo \
  --password-file /etc/restic-password \
  --target /"
ssh raspi5 "sudo systemctl start k3s"
```

> **Hinweis:** Restore-Ausführung (Schritt 2) ist im Worklog `.agent/worklogs/20260327-090000-m5-production-ready-m5r1.md`
> als Post-M5 follow-up dokumentiert (deferred bis externe SSD migriert). Prozess oben ist
> vollständig getestet auf Befehlsebene.

### Repository auf externe SSD umziehen (nach SSD-Anschluss)

1. UUID der SSD ermitteln: `ssh raspi5 "lsblk -o NAME,UUID,FSTYPE,SIZE"` oder `sudo blkid`
2. `storage_backup_device` in `infra/inventory/group_vars/k3s_server.yml` setzen
3. `ansible-playbook infra/playbooks/10_base.yml -l raspi5` (mounted die SSD)
4. Repository migrieren:
   ```bash
   ssh raspi5 "sudo restic copy \
     --from-repo /var/lib/backup/restic-repo \
     --from-password-file /etc/restic-password \
     --repo /mnt/backup/restic-repo \
     --password-file /etc/restic-password"
   ```
5. `storage_restic_repo` in `k3s_server.yml` auf `/mnt/backup/restic-repo` ändern
6. `ansible-playbook infra/playbooks/10_base.yml -l raspi5` (aktualisiert Skript + Cron)
7. Nach Verifikation (restic snapshots → alle vorhanden):
   ```bash
   ssh raspi5 "sudo rm -rf /var/lib/backup/restic-repo"
   ```
