# CLAUDE.md — homelab (infrastructure)

> **Session start:** Read `.claude/memory/MEMORY.md` completely. The topmost entry shows the current state. If there is an entry with `status: in_progress`, read the linked worklog and ask the user: *"I see we were interrupted at [SLUG]. Continue?"* — before doing anything else.

> **After each completed change:** Insert a new block **at the top** of `.claude/memory/MEMORY.md`. The file grows top-down — newest entries always visible first.

## Repo Overview

Infrastructure-as-Code for the doemefu homelab k3s cluster (Raspberry Pis + MacBook Airs). Provisions all nodes via Ansible, installs and configures k3s, deploys platform services (Traefik, cert-manager, Longhorn, cloudflared, kube-prometheus-stack), and provides app-deployment scaffolding for the namespace `apps`.

**This repo is:**
- IaC for OS provisioning, hardening, k3s, storage, networking, monitoring, backups
- Cluster operations handbook
- Reference and entry point for app deployments (example manifests, Helm values templates)

**This repo is not:**
- App code or app-specific deployments (those live in `auth-service/`, `device-service/`, `furchert-ch/`, etc.)
- CI/CD pipelines for those apps (each repo has its own)

**Full architecture spec:** `../docs/052-architecture-target.md` (forwarder at the parent level; canonical content currently at `docs/052-architecture-target.md` in this repo).
**Repo-level platform spec:** `docs/01-homelab-platform.md`.

## Scope & Precedence

- Claude Code reads `CLAUDE.md` before starting work. Nested `CLAUDE.md` files in subdirectories override the closest parent.
- The parent-level config at `../CLAUDE.md` covers cross-repo concerns; this file covers infrastructure-internal work.
- Optional overrides: `CLAUDE.override.md` (same precedence layer, takes priority over `CLAUDE.md`).

## Non-Negotiables

- Do **not** touch secrets, credentials, age keys, or `.sops.yaml` files — ever.
- Do **not** use `latest` for any Helm chart, container image, or k3s version. Always pin versions.
- Do **not** introduce new Ansible roles or Helm dependencies without explicit user approval.
- Do **not** commit. Provide a commit message and wait for the user.
- Minimize diff size: no drive-by refactors, no style-only churn, no renames unless required.
- Every Ansible role **must be idempotent** — running a playbook twice must produce zero changes on the second run.
- Arch-conditional tasks use `ansible_architecture` facts (`aarch64` / `x86_64`), never hostname-based conditionals.
- Always run the relevant lint/check commands for the touched area and record results in the worklog.
- All committed code, comments, and documentation in **English**.

## Cluster context (quick reference)

- 1 control plane + 3 workers: `raspi5` (arm64, control), `raspi4` (arm64), `mba1`/`mba2` (amd64).
- Namespaces: `platform`, `monitoring`, `apps`.
- StorageClass: Longhorn (replication factor 2).
- Ingress: Traefik (bundled with k3s) + cert-manager (Let's Encrypt).
- External access only via Cloudflare Tunnel.
- Secrets: SOPS + age, age key outside repo.
- Home Assistant runs in Docker (not k3s) on `mba1`.

## Agent Team

Seven project-level agents in `.claude/agents/` for bigger implementations:

| Agent | Model | Role |
|-------|-------|------|
| `architect` | opus | Defines role/Helm contracts before implementation |
| `implementer` | sonnet | Builds Ansible roles, Helm values, playbook wiring |
| `reviewer` | opus | Reviews for idempotency, security, version pinning |
| `documenter` | sonnet | Keeps `README.md`, `OPERATIONS.md`, `CONTRIBUTING.md`, `APP-DEPLOYMENT.md`, `INTERFACES.md`, `DEPLOYMENT.md` accurate |
| `devops` | sonnet | k3s/Helm/cluster wiring and rollout |
| `plan-reviewer` | (inherit) | Phase 3 plan defect review |
| `doc-auditor` | (inherit) | Phase 6 documentation gap audit |

---

## Process & Conventions

Detailed process rules live in `.claude/rules/` (auto-loaded by Claude Code):

| Rule file | Covers |
|-----------|--------|
| `workflow.md` | 6-phase milestone workflow (includes plan approval checklist) |
| `worklog-conventions.md` | Worklog location, naming, header, structure |
| `plan-structure.md` | 8-section plan template |
| `commands.md` | Ansible, Helm, k3s, kubectl, SOPS commands |
| `code-style-conventions.md` | Ansible, Kubernetes/Helm, secrets, boundaries |
| `review-guidelines.md` | Idempotency, security, version pinning, diff hygiene |
| `documentation-files.md` | `README.md`, `OPERATIONS.md`, `CONTRIBUTING.md`, `APP-DEPLOYMENT.md`, `DEPLOYMENT.md`, `INTERFACES.md`, `CHANGELOG.md`, `docs/` |
| `github-project.md` | GitHub Project #5 status transitions |

Worklog template: `.claude/worklog-template.md` — copy as the starting point for every new worklog. Worklogs live in `.claude/worklogs/`. Memory lives in `.claude/memory/MEMORY.md` (newest entry always at the top).
