# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Claude Code Instructions

## Scope & Precedence
- Claude Code reads `CLAUDE.md` before starting work. Instructions may be layered by directory; nearer files override earlier guidance.
- **Laufendes Gedächtnis (zuerst lesen):** @.agent/memory.md
- **Vollständige Projektspezifikation:** @docs/01-homelab-platform.md
- Optional overrides: `CLAUDE.override.md` (same precedence layer, takes priority over `CLAUDE.md`).
- Keep this file concise; prefer nested `CLAUDE.md` files for subprojects if you approach size limits.

> **Session-Start:** Lies `.agent/memory.md` vollständig. Der oberste Eintrag zeigt den aktuellen
> Stand. Gibt es einen Eintrag mit `status: in_progress`, lies das verlinkte Worklog und frage den
> User: *"Ich sehe dass wir bei [SLUG] unterbrochen haben. Weitermachen?"* — bevor du eigenständig
> etwas tust.

> **Nach jedem abgeschlossenen Change:** Einen neuen Block **oben** in `.agent/memory.md` einfügen (Format siehe dort). Die Datei wächst von unten nach oben — neueste Einträge immer zuerst sichtbar.

---

## 0) Non-Negotiables (apply to every task)
- Do **not** touch secrets, credentials, age keys, or `.sops.yaml` files — ever.
- Do **not** use `latest` for any Helm chart, container image, or k3s version. Always pin versions.
- Do **not** introduce new Ansible roles or Helm dependencies without explicit user approval.
- Minimize diff size: no drive-by refactors, no style-only churn, no renames unless required.
- Every Ansible role **must be idempotent** — running a playbook twice must produce zero changes on the second run.
- Arch-conditional tasks use `ansible_architecture` facts (`aarch64` / `x86_64`), never hostname-based conditionals.
- Always run the relevant lint/check commands for the touched area and record results in the worklog.

---

## 1) Required Workflow for Every Change (MUST FOLLOW)
For every user request that results in a code change, follow this 5-phase workflow and document it in a single worklog Markdown file (see "Worklog per change").

### Phase 1 — research
High-level goal: understand what we're doing, why, and find all relevant code.
- Identify open questions and assumptions; if something is unclear, go one step back or ask the user.
- Inspect the local codebase: search with `rg`, check `git log`, check existing role structure.
- For Ansible: check if a role for this concern already exists before creating a new one.
- For Kubernetes/Helm: check `cluster/values/` for existing overrides before adding new files.

### Phase 2 — plan
Produce a concrete plan with alternatives and specific file changes.
- The plan MUST be emitted as valid XML (see XML schema below).
- Include: files to change, step-by-step edits, validation commands, risks & mitigations.

### Phase 3 — review
Review the plan for defects (idempotency gaps, secret exposure, missing handlers, version pinning).
- Apply findings directly by updating the XML plan.
- Output (a) the updated XML plan and (b) a concise list of findings and what changed.

### Phase 4 — implement
Implement the plan:
- Make the code changes.
- Run lint/check commands from the plan and capture results in the worklog.

### Phase 5 — ship
- Run integration checks (e.g. `--check` mode against a real or staging node if available).
- Ensure docs are updated if the change affects OPERATIONS.md, CONTRIBUTING.md, or APPS.md.
- Provide final summary: what changed, how verified, follow-ups.
- **Pflicht: Neuen Block oben in `.agent/memory.md` einfügen** — Entscheidung, Worklog-Link, offene Punkte.

If anything becomes unclear in any phase, go one step back or ask the user.

---

## 2) Worklog per Change
For each change, create ONE worklog Markdown file and append phase results sequentially.

### Location
`.agent/worklogs/`

### Filename convention
`YYYYMMDD-HHMMSS-<slug>-<rand4>.md`
Example: `.agent/worklogs/20260310-142000-longhorn-prereqs-b3x1.md`

### Worklog header (MUST be at the very top)
```yaml
---
id: "YYYYMMDD-HHMMSS-<slug>-<rand4>"
title: "<short human title>"
phase: "research|plan|review|implement|ship|done"
status: "in_progress|blocked|done"
created_at: "YYYY-MM-DDTHH:MM:SS+01:00"
updated_at: "YYYY-MM-DDTHH:MM:SS+01:00"
---
```

### Worklog structure (append-only, phases in order)
- `## 1. research`
- `## 2. plan` (XML block)
- `## 3. review` (updated XML + findings)
- `## 4. implement` (summary, commands, results)
- `## 5. ship` (final verification, release notes if needed)

Record every executed command and its outcome (pass/fail + key output).

---

## 3) Plan XML Schema (MUST be valid XML)

```xml
<plan id="YYYYMMDD-HHMMSS-<slug>-<rand4>">
  <goal>...</goal>

  <context>
    <summary>...</summary>
    <assumptions>
      <assumption id="A1" confidence="high|medium|low">...</assumption>
    </assumptions>
    <open_questions>
      <question id="Q1" severity="blocker|non_blocker">...</question>
    </open_questions>
  </context>

  <options>
    <option id="O1" chosen="true">
      <description>...</description>
      <tradeoffs>
        <pro>...</pro>
        <con>...</con>
      </tradeoffs>
    </option>
    <option id="O2" chosen="false">...</option>
  </options>

  <changes>
    <change id="C1">
      <files>
        <file path="..."/>
      </files>
      <steps>
        <step>...</step>
      </steps>
    </change>
  </changes>

  <tests>
    <lint><test>...</test></lint>
    <idempotency><test>...</test></idempotency>
    <integration><test>...</test></integration>
  </tests>

  <validation>
    <command>...</command>
  </validation>

  <risks>
    <risk id="R1" likelihood="low|medium|high" impact="low|medium|high">
      <description>...</description>
      <mitigation>...</mitigation>
    </risk>
  </risks>

  <ship>
    <notes>...</notes>
  </ship>
</plan>
```

---

## 4) Repository Commands

### Setup (local dev)
- Install Ansible deps: `pip install ansible ansible-lint --break-system-packages`
- Install SOPS: `brew install sops` / `apt install sops`
- Install age: `brew install age` / `apt install age`
- Install Helm: `brew install helm` / `snap install helm --classic`
- Install kubectl: `brew install kubectl` / `snap install kubectl --classic`

### Validate / Lint
- Ansible lint: `ansible-lint infra/`
- Ansible dry-run (single node): `ansible-playbook infra/playbooks/<playbook>.yml -l <node> --check --diff`
- Ansible dry-run (all): `ansible-playbook infra/playbooks/<playbook>.yml --check --diff`
- Helm lint: `helm lint cluster/<chart>/ -f cluster/values/<chart>.yaml`
- Helm template render: `helm template <name> cluster/<chart>/ -f cluster/values/<chart>.yaml`
- SOPS encrypt: `sops -e -i <file>`
- SOPS decrypt (view only): `sops -d <file>`

### Useful utilities
- Search: `rg "symbol"` (ripgrep)
- Git history: `git log -p -- <path>` / `git blame <path>`
- Cluster status: `kubectl get nodes -o wide`
- Longhorn status: `kubectl get -n longhorn-system pods`

---

## 5) Code Style & Conventions

### Ansible
- YAML: 2-space indent, no tabs, strings quoted where ambiguous
- Role tasks: use `name:` on every task, descriptive and action-oriented ("Install open-iscsi" not "iscsi")
- Variables: `snake_case`, prefixed by role name (e.g. `k3s_version`, `longhorn_replication_factor`)
- Handlers: defined in `roles/<role>/handlers/main.yml`, triggered via `notify:`
- No hardcoded IPs or hostnames in role code — use inventory variables
- Arch-conditional example:
  ```yaml
  when: ansible_architecture == "x86_64"
  ```

### Kubernetes / Helm
- Namespaces: `platform`, `monitoring`, `apps` — no cross-namespace dependencies from `apps`
- All Helm values in `cluster/values/<chart-name>.yaml`, not inline in playbooks
- Resource limits required for all workloads in `apps` namespace
- No `cluster-admin` for app ServiceAccounts

### Secrets
- Klartext-Secrets im Git: **verboten**
- Encrypt via SOPS + age before committing: `sops -e -i <file>`
- age key liegt **ausserhalb** des Repos

---

## 6) Boundaries — What NOT to Touch
- Do **not** modify: `*.sops.yaml`, `*.age`, any file containing `_secret`, `_token`, `_key` in the name
- Do **not** touch `infra/inventory/group_vars/all.yml` secrets section without explicit instruction
- Do **not** create new namespaces outside `platform`, `monitoring`, `apps` without discussion
- Do **not** change Longhorn replication factor below 2
- App code and app-specific deployments live in **separate repos** — do not add them here
- Multi-Control-Plane HA, Service Mesh (Istio/Linkerd), GitOps controllers (ArgoCD/Flux) are **out of scope**

---

## 7) Review Guidelines
- Never log secrets, tokens, or credentials in any form
- Verify idempotency: every Ansible task must be safe to run multiple times
- Validate that new Helm values reference pinned chart versions
- Ensure UFW rules are documented in OPERATIONS.md if new ports are opened
- Flag any task that requires `become: yes` and is not in the hardening or base role
- Keep diffs minimal; no unrelated refactors

---

## 8) Worklog Template
Starter file location: `.agent/worklog-template.md`

```markdown
---
id: "YYYYMMDD-HHMMSS-<slug>-<rand4>"
title: "<short human title>"
phase: "research"
status: "in_progress"
created_at: "YYYY-MM-DDTHH:MM:SS+01:00"
updated_at: "YYYY-MM-DDTHH:MM:SS+01:00"
---

## 1. research
- Goal:
- Open questions:
- Repo areas to inspect:
- Existing roles/charts relevant:
- Git history notes:

## 2. plan
```xml
<plan id="YYYYMMDD-HHMMSS-<slug>-<rand4>">
  <goal></goal>
  <context>
    <summary></summary>
    <assumptions></assumptions>
    <open_questions></open_questions>
  </context>
  <options></options>
  <changes></changes>
  <tests></tests>
  <validation></validation>
  <risks></risks>
  <ship></ship>
</plan>
```

## 3. review
- Findings (and what changed in the plan):

## 4. implement
- Changes made:
- Commands run + results:

## 5. ship
- Final verification:
- Docs updated (if applicable):
- Notes:
```
