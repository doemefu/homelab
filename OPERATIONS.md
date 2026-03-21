# OPERATIONS.md — Betriebshandbuch

Dieses Dokument enthält Runbooks für den laufenden Cluster-Betrieb.

> **Stand:** M2 (k3s + Cloudflare) — wird mit jedem Milestone ergänzt.

---

## Inhaltsverzeichnis

- [k3s Upgrade](#k3s-upgrade)
- [Node Drain & Reboot](#node-drain--reboot)
- [Cloudflare Tunnel](#cloudflare-tunnel)

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
cloudflared tunnel token homelab  # Token in secrets.sops.yml aktualisieren

# Secret neu verschlüsseln
sops -e -i infra/inventory/group_vars/secrets.sops.yml

# Cloudflared neu deployen
ansible-playbook infra/playbooks/40_platform.yml
```
