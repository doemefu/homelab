# CLAUDE.md — homelab (infrastructure)

> **Session start:** Read `.claude/memory/MEMORY.md` completely. The topmost entry shows the current state. If there is an entry with `status: in_progress`, read the linked worklog and ask the user: *"I see we were interrupted at [SLUG]. Continue?"* — before doing anything else.

> **After each completed change:** Insert a new block **at the top** of `.claude/memory/MEMORY.md`. The file grows top-down — newest entries always visible first.

> `.claude/` is mostly gitignored: only `settings.json`, `agent-context.md`, `rules/` and `hooks/` are tracked. Memory, worklogs, worktrees and `settings.local.json` exist only on this machine; cross-check `git log`/GitHub when they look stale.

## Repo Overview

Infrastructure-as-Code for the doemefu homelab k3s cluster (Raspberry Pis + MacBook Airs). Provisions all nodes via Ansible, installs and configures k3s, deploys platform services (Traefik, cert-manager, Longhorn, cloudflared, kube-prometheus-stack), and provides app-deployment scaffolding for the namespace `apps` — including the self-hosted apps that run there: n8n, LiteLLM, Open WebUI, and the club-assistant platform stack (`52_n8n.yml`, `53_litellm.yml`, `54_club_assistant.yml`) — plus Home Assistant, which runs in its own `homeassistant` namespace (`51_homeassistant.yml`).

**This repo is:**
- IaC for OS provisioning, hardening, k3s, storage, networking, monitoring, backups
- Cluster operations handbook
- Reference and entry point for app deployments (example manifests, Helm values templates)

**This repo is not:**
- App code or app-specific deployments (those live in `auth-service/`, `device-service/`, `furchert-ch/`, etc.)
- CI/CD pipelines for those apps (each repo has its own)

**Full architecture spec:** `../docs/052-architecture-target.md` (forwarder at the parent level; canonical content currently at `docs/052-architecture-target.md` in this repo).
**Repo-level platform spec:** `docs/01-homelab-platform.md`.
**MQTT device auth spec:** `docs/053-mqtt-device-authentication.md`.
**LiteLLM gateway spec:** `docs/06-litellm-gateway.md`.
**Network monitoring spec:** `docs/060-network-monitoring.md` (data-service contract; ADR `../docs/adr/0002-network-telemetry-ownership.md`).
**MCP hub spec:** `docs/080-mcp-hub.md` + `docs/adr/0003-mcp-hub-authorization.md` (parent `../docs/080-mcp-hub.md` is a mirror; edit both together).
**Operational runbooks:** `DEPLOYMENT.md` — see "Off-LAN kubectl", "Backup & rollback for image updates", "App-data backups to the operator's Mac" and "Backup (Restic)".

## Scope & Precedence

- The parent-level config at `../CLAUDE.md` covers cross-repo concerns; this file covers infrastructure-internal work.
- Where this file and `../CLAUDE.md` differ, this file wins for infrastructure-internal work.

## Non-Negotiables

- Do **not** read or edit secrets, credentials, age keys, or `*.sops.*` files — ever.
- Do **not** use `latest` for any Helm chart, container image, or k3s version. Always pin versions.
- Do **not** introduce new Ansible roles or Helm dependencies without explicit user approval.
- Commit, push and open PRs on feature branches without asking. Merging PRs is always the user's. Rolling out changes the user has already merged needs no extra go; force-pushes, playbook runs and other cluster mutations need an explicit go. SOPS files are never read or edited by Claude — the user edits them.
- Before any merge, wait for the Copilot review and trigger CodeRabbit with a PR comment `@coderabbitai review`; fix or answer every comment.
- Minimize diff size: no drive-by refactors, no style-only churn, no renames unless required.
- Every Ansible role **must be idempotent** — running a playbook twice must produce zero changes on the second run.
- Arch-conditional tasks use `ansible_architecture` facts (`aarch64` / `x86_64`), never hostname-based conditionals.
- Always run the relevant lint/check commands for the touched area and record results in the worklog.
- All committed code, comments, and documentation in **English**.

## Cluster context (quick reference)

- k3s v1.32.2+k3s1: control plane `raspi5` (arm64, 192.168.1.61), workers `raspi4` (arm64), `mba1`/`mba2` (amd64). Ubuntu 24.04.
- Namespaces: `apps`, `platform` (cert-manager, cloudflared), `monitoring` (kube-prometheus-stack), `longhorn-system` (Longhorn, replication 2; `daily-snapshot` 02:00 local-only; Prometheus TSDB PVC excluded into the `metrics` group, which trims nightly instead of snapshotting (#101, #106); no BackupTarget — app data is dumped manually to the operator's Mac, restic 03:00 on raspi5 covers k3s config/token + a SQLite datastore copy — #64), `flux-system` (Flux CD image automation), `homeassistant`.
- `apps` workloads: auth-service, device-service, furchert-ch, data-service, mcp-hub, open-webui, litellm, n8n, postgresql (pgvector), influxdb2, mosquitto — see hostnames/ports in `DEPLOYMENT.md`.
- Home Assistant runs in k3s (namespace `homeassistant`, `51_homeassistant.yml`, pajikos Helm chart) — not in Docker.
- Ingress: Traefik (bundled with k3s) + cert-manager (Let's Encrypt). External access only via Cloudflare Tunnel.
- Playbooks (`infra/playbooks/`): `00_bootstrap 10_base 20_k3s 30_longhorn 40_platform 41_monitoring 50_apps_infra 51_homeassistant 52_n8n 53_litellm 54_club_assistant 59_app_services`.
- `cluster/apps/` manifests: Flux-managed `auth-service device-service furchert-ch data-service mcp-hub` (Kustomization `apps` + image automation); Ansible-applied `n8n` (`52_n8n.yml`), `litellm` (`53_litellm.yml`), `open-webui` (`54_club_assistant.yml`) — a merge alone does not deploy those three, run the playbook.
- Secrets: SOPS + age, age key outside repo.

## Agent Team

Agents come from the `homelab-workflow` plugin (`homelab-workflow:<role>`: `architect`, `implementer`, `reviewer`, `documenter`, `devops`, `plan-reviewer`, `doc-auditor`). Repo specifics for each role live in `.claude/agent-context.md`; there are no repo-only agents.

---

## Process & Conventions

Process comes from the plugin skills: `/homelab-workflow:start-task`, `workflow` (phases, plans, worklogs), `review-gate`, `project-board`, `cross-repo`. Repo rules in `.claude/rules/` (path-scoped, tracked):

| Rule file | Covers |
|-----------|--------|
| `code-style-conventions.md` | Ansible, Kubernetes/Helm, secrets, boundaries (loads for `infra/`, `cluster/`, `policy/` files) |
| `documentation-files.md` | `README.md`, `CONTRIBUTING.md`, `APP-DEPLOYMENT.md`, `DEPLOYMENT.md`, `INTERFACES.md`, `docs/` |

Worklogs live in `.claude/worklogs/`. Memory lives in `.claude/memory/MEMORY.md` (newest entry always at the top).

## Commands

```bash
# Setup: pip install ansible ansible-lint; brew install sops age helm kubectl
ansible-lint infra/                                                   # lint
yamllint -c .yamllint .                                               # YAML lint (CI scope)
ansible-playbook infra/playbooks/<pb>.yml -l <node> --check --diff    # dry-run one node
ansible-playbook infra/playbooks/<pb>.yml --check --diff              # dry-run all
helm lint cluster/<chart>/ -f cluster/values/<chart>.yaml
helm template <name> cluster/<chart>/ -f cluster/values/<chart>.yaml
conftest verify --policy policy/kubernetes/                           # policy tests (as in CI)
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n longhorn-system get pods
kubectl -n apps rollout status deployment/<name>
# Stale Helm repo ("Repository already have a repository named X", kubernetes.core >=6.5.0 trailing slash):
helm repo remove influxdata && helm repo add influxdata https://helm.influxdata.com
```
