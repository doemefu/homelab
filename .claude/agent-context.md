# Agent context — infrastructure

Repo-specific additions for the `homelab-workflow` agents (Ansible + k3s + Helm + Flux, conftest policies, SOPS + age). Each agent reads only its own section.

## architect

- Contract documents: `INTERFACES.md` for anything another repo consumes (namespaces, Cloudflare Tunnel hostnames, internal service DNS, secret key names, storage class, observability labels); `APP-DEPLOYMENT.md` for app-facing deployment conventions. Cross-repo changes go into `docs/052-architecture-target.md`, never duplicated inline.
- Read first: `CLAUDE.md`, `INTERFACES.md`, `docs/01-homelab-platform.md`, and the touched `infra/playbooks/`, `infra/roles/` or `cluster/` files.
- A contract change must define:
  - Ansible role variable names and defaults, and the playbook that wires them.
  - Helm chart name, pinned version, and the shape of `cluster/values/<chart>.yaml`.
  - Namespace, Service name and internal DNS (`<service>.<namespace>.svc.cluster.local`).
  - Cloudflare Tunnel ingress entry (hostname, internal service URL) if publicly exposed.
  - Secret keys materialized into Kubernetes (name only, never values) and their SOPS source.
  - Resource limits and storage class expectations.
- Backwards-incompatible changes: this repo ships first, consumer repos (auth-service, device-service, furchert-ch) adapt after; propose that migration order.
- Namespaces are limited to the allowlist in `policy/kubernetes/namespace-allowlist.rego` (platform, monitoring, apps, longhorn-system, flux-system, homeassistant). A new namespace needs discussion with the user and a rego update.

## implementer

- Read `INTERFACES.md` (if the change touches a contract), the worklog plan, `CLAUDE.md`, and the Commands block in `CLAUDE.md`.
- Stack: Ansible roles in `infra/roles/`, playbooks `infra/playbooks/00_bootstrap.yml` to `59_app_services.yml`; Helm values in `cluster/values/<chart>.yaml` (never inline in playbooks); Flux bundles in `cluster/apps/<app>/`; SOPS + age for secrets.
- Every Ansible task has a descriptive, action-oriented `name:`. Variables are `snake_case`, prefixed with the role name (`k3s_version`, `longhorn_replication_factor`). Handlers live in `roles/<role>/handlers/main.yml` and are triggered via `notify:`.
- Idempotency: every role must be idempotent; a second run reports zero changes (`command`/`shell` need `creates:` or `changed_when:`).
- Arch-conditional tasks use `ansible_architecture` (`aarch64` / `x86_64`), never hostname-based `when:`. No hardcoded IPs or hostnames in role code; use inventory variables.
- Pin every Helm chart, container image and Ansible collection version (`infra/requirements.yml`); no `latest`, no ranges.
- Do not add new Ansible roles or Helm dependencies without explicit user approval.
- Never touch `*.sops.*`, `*.age`, or any `*secret*`/`*key*`/`*token*` file. Do not touch the secrets section of `infra/inventory/group_vars/all.yml` without explicit instruction. The age key stays outside the repo.
- Do not change the Longhorn replication factor below 2.
- Resource limits are required on all workloads in the `apps` namespace; no `cluster-admin` for app ServiceAccounts; no cross-namespace dependencies from `apps`.
- Out of scope: Multi-Control-Plane HA, service mesh (Istio/Linkerd), ArgoCD. App code and app-specific deployments belong in the app's own repo.
- If `INTERFACES.md` is ambiguous or a new contract is needed, ask the architect before guessing. After reviewer approval, involve devops if the rollout is affected (new secret, new playbook step, new Flux bundle).

## reviewer

- Read `INTERFACES.md` and verify every documented namespace, endpoint and secret contract. Check `infra/requirements.yml` and Helm chart references for exact pins.
- Security: only SOPS-encrypted values or `secretKeyRef`; `*.sops.*`, `*.age` and `*secret*`/`*key*` files untouched unless the task required it; no new `cluster-admin` bindings; resource limits set for `apps` workloads.
- Idempotency: each task run twice yields zero changes (check `creates:`/`changed_when:`/state guards).
- Arch conditionals use `ansible_architecture`, never hostnames.
- Every image tag and chart version is pinned and exists for the target arch (arm64 Pis and amd64 MacBooks).
- Cloudflare Tunnel ingress changes replace the full list (not merge) and keep `http_status:404` last.
- Namespace, Service name and internal DNS match `INTERFACES.md`; changes stay within `platform`/`monitoring`/`apps`/`longhorn-system` (plus the allowlist); no new namespace without discussion.
- App-specific code or deployments must not be added here.
- Flag any task needing `become: yes` outside the hardening or base role.
- New ports opened: UFW rules must be documented in `DEPLOYMENT.md`.
- Longhorn replication factor stays at 2 or higher.
- Keep diffs minimal: no unrelated refactors, style-only churn or renames.
- Gates to confirm (the reviewer has no Bash, so check the worklog or CI output instead of running them): `ansible-lint infra/`, `helm lint`, kubeconform, conftest (`conftest verify` plus enforcement on rendered manifests).

## documenter

- Documents maintained: `CLAUDE.md` (non-negotiables, cluster context; keep concise), `README.md` (architecture, milestones, repository structure), `DEPLOYMENT.md` (deployment order, runbooks, upgrades, health checks), `APP-DEPLOYMENT.md`, `INTERFACES.md` (kept in sync with the architect), `CONTRIBUTING.md` (local dev, lint/test commands).
- New playbook step: add it to `DEPLOYMENT.md` "Deployment Order (Step-by-Step)" with the exact `ansible-playbook` command.
- New secret key: document in `INTERFACES.md` section Secrets Interface (name and SOPS source only, never values).
- New port opened: document the UFW rule in `DEPLOYMENT.md`.
- Docs are written in parallel with the code change; every milestone ends with all relevant docs updated, runbooks included.
- File purposes: `README.md` everyone; `CONTRIBUTING.md` contributors; `APP-DEPLOYMENT.md` app developers (namespaces, ingress, storage, secrets, Flux wiring); `DEPLOYMENT.md` runbooks, upgrades, monitoring, backup/restore, troubleshooting; `INTERFACES.md` integrators; `docs/` architecture specs and ADRs.

## devops

- Files owned: `infra/playbooks/*.yml` (`00_bootstrap` to `59_app_services`), `cluster/values/<chart>.yaml`, `cluster/apps/<app>/`.
- Pattern split:
  - Flux-managed (apps with their own CI-built images; a merge deploys them): auth-service, device-service, furchert-ch, data-service, mcp-hub.
  - Pattern B (raw manifests applied by a numbered Ansible playbook; a merge alone does not deploy, the playbook run needs the user's go): n8n (`52_n8n.yml`), litellm (`53_litellm.yml`), open-webui (`54_club_assistant.yml`).
  - Do not `kubectl rollout restart` Flux-managed Deployments (Flux reverts it); delete the pod instead.
- Deploy sequence:
  1. Lint green: `ansible-lint infra/`, `helm lint cluster/<chart>/ -f cluster/values/<chart>.yaml`.
  2. Dry-run: `ansible-playbook infra/playbooks/<playbook>.yml --check --diff`. Never run `--check` while the target Deployment is scaled to `replicas: 0` (the wait loop in `54_club_assistant.yml` hangs indefinitely).
  3. Known failure: `helm_repository` trailing slash (`kubernetes.core` 6.5.0 or newer): `helm repo remove <name> && helm repo add <name> <url-without-trailing-slash>`.
  4. For playbooks whose wait step does not gate on the new pod (e.g. `53_litellm.yml`): `kubectl -n apps rollout status deployment/<name>`.
  5. After rollout, read-only checks: `kubectl get nodes -o wide`, `kubectl -n apps get pods`, `kubectl -n apps logs deployment/<name> --tail=50`.
- Permissions: a `--check --diff` dry-run and read-only `kubectl` are fine. A real `ansible-playbook` apply, `helm upgrade` and `kubectl apply/delete/set image` need an explicit go. Rolling out changes the user already merged needs no extra go.
- SOPS re-encryption is a user action. Take a backup before image updates per `DEPLOYMENT.md`.

## plan-reviewer

Checklist items specific to this repo (apply in addition to the generic checks):

- **Secrets**: no secret, token or credential in a committed file, task output or log (`no_log`). The plan must not ask Claude to read or edit `*.sops.*`; it names file and key as a user action.
- **Version pinning**: Helm charts, images, k3s version pinned exactly; `policy/kubernetes/deny-latest-image.rego` enforces it for manifests.
- **Idempotency**: second playbook run yields zero changes; flag `command`/`shell` without `creates`/`changed_when`.
- **Architecture conditionals**: keyed on `ansible_architecture` (`aarch64`/`x86_64`), not hostnames; the cluster mixes arm64 Pis and amd64 MacBooks.
- **Handlers and restarts**: config changes trigger the right handler; Flux-managed Deployments avoid `kubectl rollout restart`.
- **Resources and RBAC**: requests and limits on every `apps` workload (`require-resource-limits.rego`); no `cluster-admin` for app ServiceAccounts (`deny-app-cluster-admin.rego`).
- **Namespace allowlist**: every namespaced object lives in a namespace allowed by `namespace-allowlist.rego`; new namespaces need user discussion and a rego update.
- **Longhorn**: replication factor stays at 2 or higher.
- **Cloudflare tunnel ingress**: `cf_ingress_body` in `infra/playbooks/40_platform.yml` replaces the full ingress list; keep all existing routes and the `http_status:404` catch-all last.
- **Flux vs Pattern B**: auth-service, device-service, furchert-ch, data-service, mcp-hub are Flux-managed (merge deploys). n8n (`52`), litellm (`53`), open-webui (`54_club_assistant.yml`) are Pattern B (raw manifests applied by a numbered Ansible playbook); the plan must include the playbook run as a user-approved step.
- **UFW / become**: new ports need UFW docs in `DEPLOYMENT.md`; `become: yes` outside the hardening or base role is flagged.
- **CI gates** (`.github/workflows/ci.yml`): yamllint, shell lint, actionlint, `ansible-lint infra/`, kubeconform per app overlay, conftest (`conftest verify` plus enforcement on rendered manifests). The plan lists the local commands.
- **Rollback path**: git revert + Flux reconcile, previous Helm revision, or previous image tag; backup before image updates per `DEPLOYMENT.md`.
- **Plan tests** must include the idempotency run (2nd run, 0 changes) and a `--check` run.
- Architectural questions: is an existing role/chart reusable (new roles or Helm dependencies need user approval); does it fit `cluster/values/` and `cluster/apps/<app>/`; what happens on node loss or reboot (MacBook nodes hard-reset periodically); is the failure mode acceptable if PostgreSQL, InfluxDB or Mosquitto is temporarily down.

## doc-auditor

- Context: playbooks `00_bootstrap` to `59_app_services`, Helm, Flux CD. App code and app-specific deployments live in other repos and are documented there.
- Read in full: `README.md`, `INTERFACES.md`, `DEPLOYMENT.md`, `APP-DEPLOYMENT.md`, `CONTRIBUTING.md`. Check `docs/052-architecture-target.md` and other `docs/*.md` only if the target architecture changes.
- Per document:
  - `README.md`: milestone/status table current; new node, namespace or platform component in architecture and repository-structure sections.
  - `INTERFACES.md`: new or changed namespace, Cloudflare Tunnel hostname, internal service DNS, secret key, storage or observability contract.
  - `DEPLOYMENT.md`: new playbook or step in "Deployment Order"; component in "Cluster Health Checks" or "Component-Specific Operations"; new gotcha (idempotency hang, wait-loop bug) in troubleshooting; UFW rules for newly opened ports.
  - `APP-DEPLOYMENT.md`: new pattern app developers must follow (ingress, storage, secrets, resource limits).
  - `CONTRIBUTING.md`: new local-dev prerequisite, lint command, or Ansible/Helm workflow step.
