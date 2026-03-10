---
id: "20260310-120000-m1-baseline-hardening-k7f2"
title: "M1 — Ansible Baseline & Hardening"
phase: "review"
status: "in_progress"
created_at: "2026-03-10T12:00:00+01:00"
updated_at: "2026-03-10T12:00:00+01:00"
---

## 1. research

**Ziel:** Alle 4 Nodes (pi5, pi4, mba1, mba2) via Ansible vollständig provisioniert,
gehärtet und jederzeit rebuild-bar.

**Repo-Zustand beim Start:**
- Skeleton-Verzeichnisse vorhanden: `infra/inventory/`, `infra/playbooks/`, `infra/roles/`,
  `cluster/platform/`, `cluster/values/`, `examples/`
- Keine Dateien in diesen Verzeichnissen (leere Dirs)
- `.sops.yaml` fehlt noch
- `CLAUDE.md`, `docs/01-homelab-platform.md`, `.agent/memory.md` vorhanden
- `.claudeignore` und `.claude/settings.json` vorhanden und korrekt

**Offene Entscheidungen aus memory.md:**
- `ha_host`: noch offen — mba1 empfohlen (8GB, Quad-Core)
- Versionsnummern: alle bestätigt (k3s v1.32.2+k3s1, etc.)
- age-Key: noch nicht vorhanden, muss vor SOPS-Dateien erzeugt werden
- IPs: Platzhalter, werden später durch echte IPs ersetzt

**Relevante Constraints (CLAUDE.md):**
- `ansible-lint` + `--check --diff` vor jedem Schritt
- Keine IPs/Hostnames hardcoded in Role-Code — nur Inventory-Variablen
- Arch-conditional: `ansible_architecture == "x86_64"` / `"aarch64"`
- Idempotenz Pflicht

**Ansible-Version Check:** noch ausstehend (in Phase 4)

---

## 2. plan

```xml
<plan id="20260310-120000-m1-baseline-hardening-k7f2">
  <goal>Alle 4 Nodes (pi5, pi4, mba1, mba2) via Ansible vollständig provisioniert,
  gehärtet und jederzeit rebuild-bar. age-Key + SOPS-Setup als Fundament für Secrets.</goal>

  <context>
    <summary>Leeres Repo-Skeleton. Keine Ansible-Dateien vorhanden. Nodes laufen Ubuntu
    24.04, SSH-Key ist hinterlegt, ubuntu-User ist initial verfügbar. IPs sind Platzhalter
    (werden später ersetzt). ha_host ist noch offen — Empfehlung mba1.</summary>
    <assumptions>
      <assumption id="A1" confidence="high">Ubuntu 24.04 LTS auf allen Nodes installiert</assumption>
      <assumption id="A2" confidence="high">SSH-Key des Operators bereits auf allen Nodes hinterlegt</assumption>
      <assumption id="A3" confidence="high">Nodes sind im Subnetz 192.168.1.0/24 erreichbar</assumption>
      <assumption id="A4" confidence="medium">pi5 hat noch kein USB/SSD — storage role gibt Warning, bricht nicht ab</assumption>
      <assumption id="A5" confidence="medium">ha_host wird mba1 — kann in group_vars geändert werden</assumption>
    </assumptions>
    <open_questions>
      <question id="Q1" severity="non_blocker">ha_host final: mba1 oder bleibt offen?</question>
      <question id="Q2" severity="non_blocker">Konkrete IPs der Nodes (Platzhalter für jetzt)</question>
    </open_questions>
  </context>

  <options>
    <option id="O1" chosen="true">
      <description>Schrittweise Implementierung: erst .sops.yaml + Inventory, dann
      Roles einzeln, dann Playbooks. Nach jedem Schritt ansible-lint + --check.</description>
      <tradeoffs>
        <pro>Fehler früh erkennbar, User kann nach jedem Schritt bestätigen</pro>
        <con>Langsamer als alles auf einmal</con>
      </tradeoffs>
    </option>
  </options>

  <changes>
    <change id="C1">
      <files>
        <file path=".sops.yaml"/>
      </files>
      <steps>
        <step>Anleitung: age-keygen Befehl zeigen, User führt aus</step>
        <step>.sops.yaml mit Platzhalter für age public key anlegen</step>
      </steps>
    </change>
    <change id="C2">
      <files>
        <file path="infra/inventory/hosts.yml"/>
        <file path="infra/inventory/group_vars/all.yml"/>
        <file path="infra/inventory/group_vars/k3s_server.yml"/>
        <file path="infra/inventory/group_vars/k3s_agent.yml"/>
        <file path="infra/inventory/group_vars/mac.yml"/>
        <file path="infra/inventory/group_vars/docker_hosts.yml"/>
      </files>
      <steps>
        <step>hosts.yml: alle 4 Nodes, Gruppen k3s_server/k3s_agent/mac/docker_hosts</step>
        <step>all.yml: timezone, ntp, ansible_user, ssh_key_path</step>
        <step>Gruppen-spezifische group_vars anlegen</step>
      </steps>
    </change>
    <change id="C3">
      <files>
        <file path="infra/playbooks/00_bootstrap.yml"/>
      </files>
      <steps>
        <step>Python3 sicherstellen (gather_facts: false, raw module)</step>
        <step>ansible user anlegen, SSH key hinterlegen, sudo passwordless</step>
        <step>System-Packages aktualisieren (apt update + upgrade)</step>
      </steps>
    </change>
    <change id="C4">
      <files>
        <file path="infra/roles/base/tasks/main.yml"/>
        <file path="infra/roles/base/defaults/main.yml"/>
        <file path="infra/roles/base/handlers/main.yml"/>
      </files>
      <steps>
        <step>Hostname setzen, Timezone Europe/Zurich, chrony NTP</step>
        <step>unattended-upgrades konfigurieren</step>
        <step>Standard-Packages installieren (curl, git, htop, jq, vim)</step>
      </steps>
    </change>
    <change id="C5">
      <files>
        <file path="infra/roles/hardening/tasks/main.yml"/>
        <file path="infra/roles/hardening/defaults/main.yml"/>
        <file path="infra/roles/hardening/handlers/main.yml"/>
        <file path="infra/roles/hardening/templates/sshd_hardening.conf.j2"/>
      </files>
      <steps>
        <step>UFW: default deny incoming, allow outgoing</step>
        <step>UFW: SSH (22) von 192.168.1.0/24</step>
        <step>UFW: k3s-Ports (6443, 10250, 8472/udp, 2379-2380) von 192.168.1.0/24</step>
        <step>UFW: Longhorn (9500-9502) von 192.168.1.0/24</step>
        <step>UFW: Node Exporter (9100) von 192.168.1.0/24</step>
        <step>fail2ban installieren + aktivieren</step>
        <step>SSH-Hardening: PasswordAuthentication no, PermitRootLogin no,
        MaxAuthTries 3, Drop-in /etc/ssh/sshd_config.d/99-hardening.conf</step>
      </steps>
    </change>
    <change id="C6">
      <files>
        <file path="infra/roles/storage/tasks/main.yml"/>
        <file path="infra/roles/storage/defaults/main.yml"/>
      </files>
      <steps>
        <step>Restic installieren (apt)</step>
        <step>pi5: /mnt/backup anlegen; USB-Device mounten wenn vorhanden, sonst warn+skip</step>
        <step>MBAs + pi4: /var/lib/backup anlegen</step>
      </steps>
    </change>
    <change id="C7">
      <files>
        <file path="infra/roles/mac_tweaks/tasks/main.yml"/>
        <file path="infra/roles/mac_tweaks/defaults/main.yml"/>
        <file path="infra/roles/mac_tweaks/templates/logind-lid.conf.j2"/>
      </files>
      <steps>
        <step>HandleLidSwitch=ignore in /etc/systemd/logind.conf.d/lid.conf</step>
        <step>T2-Kernel-Module apple-bce + apple-ibridge in /etc/modules-load.d/</step>
        <step>Gesamte Role nur wenn ansible_architecture == "x86_64"</step>
      </steps>
    </change>
    <change id="C8">
      <files>
        <file path="infra/playbooks/10_base.yml"/>
      </files>
      <steps>
        <step>Kombiniert: base + hardening + storage + mac_tweaks (bedingt via when)</step>
      </steps>
    </change>
  </changes>

  <tests>
    <lint>
      <test>ansible-lint infra/ nach jeder neuen Datei</test>
    </lint>
    <idempotency>
      <test>ansible-playbook infra/playbooks/10_base.yml --check --diff — zweimal ausführen, zweiter Run: 0 changes</test>
    </idempotency>
    <integration>
      <test>ansible all -m ping — alle 4 Nodes antworten</test>
      <test>ansible all -m shell -a "ufw status verbose" — UFW active, Ports korrekt</test>
      <test>ansible all -m shell -a "sshd -T | grep -E 'passwordauth|permitroot'" — no/no</test>
    </integration>
  </tests>

  <validation>
    <command>ansible-lint infra/</command>
    <command>ansible-playbook infra/playbooks/10_base.yml --check --diff -l pi5</command>
    <command>ansible all -m ping</command>
  </validation>

  <risks>
    <risk id="R1" likelihood="low" impact="high">
      <description>SSH-Hardening sperrt Zugang aus wenn ansible_user noch nicht angelegt</description>
      <mitigation>00_bootstrap.yml läuft immer zuerst; hardening kommt erst in 10_base.yml</mitigation>
    </risk>
    <risk id="R2" likelihood="low" impact="medium">
      <description>UFW blockiert k3s-Kommunikation bei falschen Subnetz-Einträgen</description>
      <mitigation>Ports explizit mit from: 192.168.1.0/24, mit --check zuerst testen</mitigation>
    </risk>
    <risk id="R3" likelihood="medium" impact="low">
      <description>pi5 hat kein USB-Device — storage role bricht ab</description>
      <mitigation>storage role prüft Device-Existenz mit stat, gibt warn aus statt fail</mitigation>
    </risk>
  </risks>

  <ship>
    <notes>Nach erfolgreichem M1: memory.md updaten, README.md + CONTRIBUTING.md erstellen</notes>
  </ship>
</plan>
```

---

## 3. review

**Findings:**
1. **R1 (SSH lockout)**: Mitigiert durch Playbook-Reihenfolge. Aber zusätzlich: hardening role
   muss `ansible_ssh_port` berücksichtigen falls SSH-Port je geändert wird. Jetzt Port 22 fix —
   OK für M1.
2. **Fehlende UFW-Regel für Longhorn Manager UI (80/TCP intern)**: Port 80 intern sollte
   geöffnet sein für Longhorn Dashboard-Zugriff im LAN. Wird in C5 ergänzt.
3. **storage role**: `failed_when: false` allein reicht nicht — korrekt ist `ignore_errors` +
   `warn` via `debug`. Plan bleibt, Umsetzung beachtet das.
4. **mac_tweaks apple-bce**: Das Modul ist im Ubuntu-Mainline-Kernel seit 6.x nicht mehr
   nötig (backported). `/etc/modules-load.d/` Eintrag ist dennoch unschädlich. Bleibt drin.
5. **group_vars secrets**: all.yml enthält noch keine Secrets in M1 (kommt erst M2).
   Kein SOPS-Problem in diesem Milestone.

**Plan-Änderungen:** UFW Port 80 (intern) für Longhorn UI wird in C5 ergänzt.
