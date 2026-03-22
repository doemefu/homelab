# OPERATIONS.md — Betriebshandbuch

Dieses Dokument enthält Runbooks für den laufenden Cluster-Betrieb.

> **Stand:** M3 (k3s + Cloudflare + Longhorn) — wird mit jedem Milestone ergänzt.

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
- [k3s Upgrade](#k3s-upgrade)
- [Node Drain & Reboot](#node-drain--reboot)
- [cert-manager / TLS](#cert-manager--tls)
- [Cloudflare Tunnel](#cloudflare-tunnel)
- [Longhorn Storage](#longhorn-storage)

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

Erwartete Pods pro Namespace nach M3:

| Namespace        | Pods |
|------------------|------|
| `kube-system`    | traefik, coredns, metrics-server, svclb-* |
| `platform`       | cert-manager (3x), cloudflared |
| `longhorn-system`| longhorn-manager (2x), longhorn-ui (2x), csi-*, engine-image, instance-manager |

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

## Cloudflare Tunnel

### Tunnel-Status prüfen

```bash
# Pod-Status
kubectl -n platform get pods -l app=cloudflared

# Logs
kubectl -n platform logs -l app=cloudflared --tail=50
```

### Neuen Service exponieren

1. Eintrag in `cluster/values/cloudflared.yaml` vor dem `http_status:404`-Fallback ergänzen:

```yaml
ingress:
  - hostname: grafana.furchert.ch
    service: http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80
  - service: http_status:404  # immer zuletzt
```

2. Playbook ausführen:

```bash
ansible-playbook infra/playbooks/40_platform.yml
```

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
