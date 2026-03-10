# memory.md — Claude Code Running Memory
<!-- Claude: Lies diese Datei von oben. Neueste Einträge zuerst. -->
<!-- Format: Beim Abschluss jeder Session/Change einen Block OBEN einfügen. -->
<!-- Behalte maximal ~30 Einträge; ältere unter "## Archiv" verschieben. -->

---

## Aktuelle Entscheidungen & offene Punkte

> Beim Start eines neuen Projekts hier den initialen Stand eintragen.

```
[YYYY-MM-DD] INIT
- Repo initialisiert, noch keine Nodes provisioniert
- Offene Entscheidung: ha_host Variable (pi4 empfohlen) noch nicht gesetzt
- Gepinnte Versionen in cluster/values/ noch ausstehend (alle auf vX.Y.Z)
- T2-Chip Kompatibilitätstest (apple-bce Modul) auf mba1/mba2 noch ausstehend
```

---

## Eintragsformat (für Claude beim Schreiben)

Jeden neuen Block **oben** unter dem Trennstrich einfügen:

```
[YYYY-MM-DD] <SLUG> — <ein-Satz-Zusammenfassung>
Worklog: .agent/worklogs/YYYYMMDD-HHMMSS-<slug>-<rand4>.md
Was: <was wurde geändert>
Entscheidung: <warum so und nicht anders — die wichtigste Info für Claude>
Offen: <was noch fehlt oder Folgefragen>
Status: done | in_progress | blocked
```

---

## Archiv
<!-- Einträge die älter als ~30 Blöcke sind hierher verschieben. -->
<!-- Claude liest diesen Abschnitt normalerweise nicht mehr. -->
