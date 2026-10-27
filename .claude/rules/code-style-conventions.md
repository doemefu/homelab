---
paths:
  - "infra/**/*.yml"
  - "infra/**/*.yaml"
  - "cluster/**/*.yml"
  - "cluster/**/*.yaml"
  - "policy/**/*.rego"
---

# Code Style & Conventions

### Ansible
- YAML: 2-space indent, no tabs, strings quoted where ambiguous.
- Role tasks: use `name:` on every task, descriptive and action-oriented ("Install open-iscsi" not "iscsi").
- Variables: `snake_case`, prefixed by role name (e.g. `k3s_version`, `longhorn_replication_factor`).
- Handlers: defined in `roles/<role>/handlers/main.yml`, triggered via `notify:`.
- No hardcoded IPs or hostnames in role code — use inventory variables.
- Arch-conditional tasks use `ansible_architecture` facts (`aarch64` / `x86_64`), never hostname-based conditionals:
  ```yaml
  when: ansible_architecture == "x86_64"
  ```
- Every Ansible role **must be idempotent** — running a playbook twice must produce zero changes on the second run.

### Kubernetes / Helm
- Namespaces in use: platform, monitoring, apps, longhorn-system, flux-system, homeassistant (allowlist: `policy/kubernetes/namespace-allowlist.rego`). Do not add new ones without discussion. No cross-namespace dependencies from `apps`.
- All Helm values in `cluster/values/<chart-name>.yaml`, not inline in playbooks.
- Resource limits required for all workloads in `apps` namespace.
- No `cluster-admin` for app ServiceAccounts.

### Secrets
- Plaintext secrets in git: **forbidden**.
- Plaintext secrets in git are forbidden. Secrets are SOPS + age encrypted by the user, never by Claude; Claude never reads or edits `*.sops.*` files — name the file and key and hand it to the user.
- age key lives **outside** the repo.

### Boundaries — What NOT to touch
- Do **not** read or modify: `*.sops.*`, `*.age`, or any file with `_secret`, `_token`, `_key` in the name.
- Do **not** touch `infra/inventory/group_vars/all.yml` secrets section without explicit instruction.
- Do **not** change Longhorn replication factor below 2.
- App code and app-specific deployments live in **separate repos** — do not add them here.
- Multi-Control-Plane HA, Service Mesh (Istio/Linkerd), ArgoCD are **out of scope**. Flux CD is used for automated app deployments in the `apps` namespace — see `cluster/apps/`.
