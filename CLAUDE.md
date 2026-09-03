# CLAUDE.md — homelab (infrastructure)

> **Session start:** Read `.claude/memory/MEMORY.md` completely. The topmost entry shows the current state. If there is an entry with `status: in_progress`, read the linked worklog and ask the user: *"I see we were interrupted at [SLUG]. Continue?"* — before doing anything else.

> **After each completed change:** Insert a new block **at the top** of `.claude/memory/MEMORY.md`. The file grows top-down — newest entries always visible first.

> `.claude/` is fully gitignored in this repo — memory, worklogs, agents and rules exist only on this machine; cross-check `git log`/GitHub when they look stale.

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
**Operational runbooks:** `DEPLOYMENT.md` — see "Off-LAN kubectl" and "Backup & rollback for image updates".

## Scope & Precedence

- Claude Code reads `CLAUDE.md` before starting work. Nested `CLAUDE.md` files in subdirectories override the closest parent.
- The parent-level config at `../CLAUDE.md` covers cross-repo concerns; this file covers infrastructure-internal work.
- Optional overrides: `CLAUDE.override.md` (same precedence layer, takes priority over `CLAUDE.md`).

## Non-Negotiables

- Do **not** touch secrets, credentials, age keys, or `.sops.yaml` files — ever.
- Do **not** use `latest` for any Helm chart, container image, or k3s version. Always pin versions.
- Do **not** introduce new Ansible roles or Helm dependencies without explicit user approval.
- Commit, push and open PRs on feature branches without asking (standing permission, 2026-08-28). Merging, force-pushes, playbook runs, cluster mutations and anything touching SOPS/secrets need an explicit go for that task.
- Before any merge, wait for the Copilot review and trigger CodeRabbit with a PR comment `@coderabbitai review`; fix or answer every comment.
- Minimize diff size: no drive-by refactors, no style-only churn, no renames unless required.
- Every Ansible role **must be idempotent** — running a playbook twice must produce zero changes on the second run.
- Arch-conditional tasks use `ansible_architecture` facts (`aarch64` / `x86_64`), never hostname-based conditionals.
- Always run the relevant lint/check commands for the touched area and record results in the worklog.
- All committed code, comments, and documentation in **English**.

## Cluster context (quick reference)

- k3s v1.32.2+k3s1: control plane `raspi5` (arm64, 192.168.1.61), workers `raspi4` (arm64), `mba1`/`mba2` (amd64). Ubuntu 24.04.
- Namespaces: `apps`, `platform` (cert-manager, cloudflared), `monitoring` (kube-prometheus-stack), `longhorn-system` (Longhorn, replication 2), `flux-system` (Flux CD image automation), `homeassistant`.
- `apps` workloads: auth-service, device-service, furchert-ch, open-webui, litellm, n8n, postgresql (pgvector), influxdb2, mosquitto — see hostnames/ports in `DEPLOYMENT.md`.
- Home Assistant runs in k3s (namespace `homeassistant`, `51_homeassistant.yml`, pajikos Helm chart) — not in Docker.
- Ingress: Traefik (bundled with k3s) + cert-manager (Let's Encrypt). External access only via Cloudflare Tunnel.
- Playbooks (`infra/playbooks/`): `00_bootstrap 10_base 20_k3s 30_longhorn 40_platform 41_monitoring 50_apps_infra 51_homeassistant 52_n8n 53_litellm 54_club_assistant 59_app_services`.
- `cluster/apps/` manifests: Flux-managed `auth-service device-service furchert-ch` (Kustomization `apps` + image automation); Ansible-applied `n8n` (`52_n8n.yml`), `litellm` (`53_litellm.yml`), `open-webui` (`54_club_assistant.yml`) — a merge alone does not deploy those three, run the playbook.
- Secrets: SOPS + age, age key outside repo.

## Agent Team

Seven project-level agents in `.claude/agents/` for bigger implementations (local-only — not tracked in git):

| Agent | Model | Role |
|-------|-------|------|
| `architect` | opus | Defines role/Helm contracts before implementation |
| `implementer` | sonnet | Builds Ansible roles, Helm values, playbook wiring |
| `reviewer` | opus | Reviews for idempotency, security, version pinning |
| `documenter` | sonnet | Keeps `README.md`, `CONTRIBUTING.md`, `APP-DEPLOYMENT.md`, `INTERFACES.md`, `DEPLOYMENT.md` accurate |
| `devops` | sonnet | k3s/Helm/cluster wiring and rollout |
| `plan-reviewer` | (inherit) | Phase 3 plan defect review |
| `doc-auditor` | (inherit) | Phase 6 documentation gap audit |

---

## Process & Conventions

Detailed process rules live in `.claude/rules/` (auto-loaded by Claude Code; local-only — gitignored, not tracked in git):

| Rule file | Covers |
|-----------|--------|
| `workflow.md` | 6-phase milestone workflow (includes plan approval checklist) |
| `worklog-conventions.md` | Worklog location, naming, header, structure |
| `plan-structure.md` | 8-section plan template |
| `commands.md` | Ansible, Helm, k3s, kubectl, SOPS commands |
| `code-style-conventions.md` | Ansible, Kubernetes/Helm, secrets, boundaries |
| `review-guidelines.md` | Idempotency, security, version pinning, diff hygiene |
| `documentation-files.md` | `README.md`, `CONTRIBUTING.md`, `APP-DEPLOYMENT.md`, `DEPLOYMENT.md`, `INTERFACES.md`, `docs/` |
| `github-project.md` | GitHub Project #5 status transitions |

Worklog template: `.claude/worklog-template.md` — copy as the starting point for every new worklog. Worklogs live in `.claude/worklogs/`. Memory lives in `.claude/memory/MEMORY.md` (newest entry always at the top).
