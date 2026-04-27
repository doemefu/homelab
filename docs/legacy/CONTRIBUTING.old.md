# Contributing

Development guide for the homelab IaC repository.

## Working Model (Human or Agent)

Use this loop for every change:
1. **Research first**: find source-of-truth files before editing (`infra/playbooks`, `cluster/apps`, `cluster/values`, inventory vars).
2. **Keep diffs small**: no unrelated refactors, no opportunistic rewrites.
3. **Respect ownership**: Flux-managed and Ansible-managed app areas must not be mixed.
4. **Protect secrets**: plaintext secrets never belong in Git; use SOPS-backed vars + playbook-created Secrets.
5. **Prove consistency**: commands/URLs/ports in docs must be backed by manifests/playbooks.

---

## Fast File Map (Where to change what)

| Topic | Canonical files |
|------|------------------|
| Node bootstrap/base hardening | `infra/playbooks/00_bootstrap.yml`, `10_base.yml`, `infra/roles/{base,hardening,storage,mac_tweaks}` |
| k3s and platform ingress/TLS | `infra/playbooks/20_k3s.yml`, `40_platform.yml`, `cluster/values/{cert-manager,cloudflared}.yaml` |
| Monitoring/alerts | `infra/playbooks/41_monitoring.yml`, `cluster/values/kube-prometheus-stack.yaml` |
| Shared app infrastructure | `infra/playbooks/50_apps_infra.yml`, `cluster/values/influxdb2.yaml` |
| App runtimes | `infra/playbooks/51_homeassistant.yml`, `52_n8n.yml`, `53_litellm.yml` |
| App secrets/bootstrap | `infra/playbooks/59_app_services.yml`, `infra/inventory/group_vars/all.sops.yml(.example)` |
| Flux app onboarding | `cluster/apps/<app>/`, `cluster/apps/kustomization.yaml`, `cluster/flux-system/apps-sync.yaml` |
| Operations runbooks | `OPERATIONS.md` |
| App/platform interfaces | `APPS.md` |
| Platform overview and public surfaces | `README.md` |

## Local Setup

```bash
# Ansible + lint
pip install ansible ansible-lint --break-system-packages
ansible-galaxy collection install -r infra/requirements.yml -p ~/.ansible/collections

# Kubernetes tooling (for M2+)
# Note: kubernetes.core.helm requires Helm <4.0.0 — install helm@3 explicitly
brew install helm@3 kubectl

# helm-diff plugin (eliminates idempotency warnings in Helm tasks)
/usr/local/opt/helm@3/bin/helm plugin install https://github.com/databus23/helm-diff
# Apple Silicon: /opt/homebrew/opt/helm@3/bin/helm plugin install ...

# Secrets + GitOps CLI
brew install sops age fluxcd/tap/flux
```

> **Helm 4 Hinweis:** `brew install helm` installiert aktuell Helm 4.x, welches von
> `kubernetes.core.helm` (Constraint `<4.0.0`) noch nicht unterstützt wird.
> `helm@3` wird keg-only installiert — der Pfad ist in `group_vars/all.yml` als `helm_binary`
> zentralisiert (kein Hardcode in einzelnen Playbooks):
> - Intel-Mac: `/usr/local/opt/helm@3/bin/helm`
> - Apple Silicon: `/opt/homebrew/opt/helm@3/bin/helm` → `helm_binary` in inventory überschreiben

age key (once, stored outside the repo):
```bash
mkdir -p ~/.config/age
age-keygen -o ~/.config/age/homelab.key

# Dauerhaft in ~/.zshrc eintragen — wird von sops und dem Ansible vars plugin benötigt:
echo 'export SOPS_AGE_KEY_FILE=~/.config/age/homelab.key' >> ~/.zshrc
source ~/.zshrc
```

The public key for this repo is in `.sops.yaml`. Contact the repo owner for access.

Secrets anlegen (einmalig nach Clone):
```bash
cp infra/inventory/group_vars/all.sops.yml.example \
   infra/inventory/group_vars/all.sops.yml
# Alle CHANGE_ME-Einträge ersetzen, dann verschlüsseln:
sops -e -i infra/inventory/group_vars/all.sops.yml
```

> **Pflichtfeld für `41_monitoring.yml`:** `alertmanager_discord_webhook_url` muss gesetzt sein —
> das Playbook enthält eine `assert`-Guard und schlägt ohne diesen Wert fehl.
> URL erhalten: Discord → Kanal-Einstellungen → Integrationen → Webhooks → URL kopieren.

> **Pflichtfelder für `50_apps_infra.yml`:** `postgresql_password`, `influxdb_admin_password` und
> `influxdb_admin_token` sowie `sentry_dsn` müssen in `all.sops.yml` gesetzt sein — das Playbook schlägt ohne diese Werte fehl.

> **Pflichtfelder für `59_app_services.yml`:** Dieses Playbook hat mehrere `assert`-Guards.
> Mindestens folgende Variablen müssen in `all.sops.yml` gesetzt sein:
> `homelab_db_username`, `homelab_db_password`, `device_service_mqtt_password`,
> `influxdb_admin_token`, `auth_service_grafana_client_secret`, `auth_service_ha_client_secret`,
> `auth_service_device_service_client_secret`, `auth_service_n8n_client_secret`,
> `n8n_encryption_key`, `auth_service_rsa_private_key`, `auth_service_rsa_public_key`,
> sowie die LiteLLM-Variablen unten.
> Empfehlung: `n8n_encryption_key` mit `openssl rand -hex 32` generieren.

> **Pflichtfelder für `53_litellm.yml` / `59_app_services.yml` (LiteLLM):** `litellm_master_key`,
> `litellm_salt_key`, `litellm_db_password`, `mistral_api_key`, `mistral_codestral_api_key`, und
> `litellm_client_secret` müssen in
> `all.sops.yml` gesetzt sein. `litellm_salt_key` einmalig generieren (`openssl rand -hex 32`) und
> **niemals** nachträglich rotieren; dies gilt nur für die Erstbereitstellung — ein Wechsel macht alle gespeicherten Virtual Keys unlesbar.
>
> **Kanonische Quelle für Pflichtvariablen:** `assert`-Tasks in den jeweiligen Playbooks und
> `infra/inventory/group_vars/all.sops.yml.example`.

---

## Ansible Development Workflow

### Before every change
```bash
# Lint everything
ansible-lint infra/

# Dry-run against a single node
ansible-playbook infra/playbooks/<playbook>.yml --check --diff -l <node>
```

### After changes
```bash
# Real run, single node
ansible-playbook infra/playbooks/<playbook>.yml -l <node>

# Idempotency check — second run must produce 0 changes
ansible-playbook infra/playbooks/<playbook>.yml -l <node>
# → PLAY RECAP: changed=0
```

### For documentation-only changes
```bash
# Verify referenced facts against source files
rg -n "<hostname|playbook|port|path>" README.md APPS.md CONTRIBUTING.md OPERATIONS.md
rg -n "<same token>" infra/playbooks/ cluster/apps/ cluster/values/ infra/inventory/
```

### Bootstrap a new node (initial setup, run once)
```bash
ansible-playbook infra/playbooks/00_bootstrap.yml \
  -e ansible_user=<initial-node-user> -l <node> --become
```
After bootstrap, all subsequent playbooks connect as the `ansible` user.

> **Note:** `-e ansible_user=<initial-user>` sets the **connection** user (the existing account on
> the node). The **created** user is always `ansible` (hardcoded in the playbook). Use `-e`, not
> `-u` — `group_vars/all.yml` sets `ansible_user: ansible` and takes precedence over the `-u` flag.

---

## Code Style

### Ansible
- 2-space indent, no tabs
- Every task has a descriptive `name:` starting with an uppercase letter
- Variables prefixed with role name: `hardening_lan_subnet`, `mac_tweaks_kernel_modules`
- No hardcoded IPs or hostnames in role code — use inventory variables
- Arch-conditional tasks use `ansible_architecture`, never hostname-based conditionals:
  ```yaml
  when: ansible_architecture == "x86_64"   # MBA
  when: ansible_architecture == "aarch64"  # Raspberry Pi
  ```
- Services that are newly installed need `ignore_errors: "{{ ansible_check_mode }}"` on
  start/restart tasks and handlers so `--check` mode doesn't fail

### Kubernetes / Helm
- All Helm values in `cluster/values/<chart-name>.yaml` — nothing inline in playbooks
- Pinned versions only — no `latest` for images, charts, or k3s
- Namespaces: `platform`, `longhorn-system`, `monitoring`, `apps`, `homeassistant`
  (Exception: `longhorn-system` ist Helm-Chart-Konvention und wird nicht durch dieses Repo gewählt)
- ServiceMonitors targeting app-namespace services are placed in the `monitoring` namespace with label `release: kube-prometheus-stack` — do not place them in `apps`
- Resource limits required for all workloads in `apps` namespace

### Secrets
- No plaintext secrets in git — ever
- Encrypt with SOPS before committing: `sops -e -i <file>`
- Files matching `.sops.yaml` rules are auto-encrypted on `sops -e -i`

---

## Known Lint Rules (ansible-lint production profile)

| Issue                                      | Fix                                                                                                           |
|--------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Task name starts lowercase                 | Capitalise: `"Fail2ban..."` not `"fail2ban..."`                                                               |
| `var-naming[no-role-prefix]`               | Prefix vars with role name: `mac_tweaks_*`                                                                    |
| `args[module]` on loop with template value | Use explicit tasks instead of loop for static choices                                                         |
| `stdout_callback = yaml`                   | Use `stdout_callback = ansible.builtin.default` + `result_format = yaml`                                      |
| `validate:` on SSH drop-in                 | Don't use `validate:` for `/etc/ssh/sshd_config.d/*.conf` — `sshd -t` needs a full config file, not a drop-in |

---

## Adding a Flux-managed App

`auth-service` and `device-service` are deployed via Flux CD. To add another app under Flux management:

1. **Create Flux config files** under `cluster/apps/<app-name>/`:
   - `kustomization.yaml` — lists the other files
   - `source.yaml` — `GitRepository` pointing to the app repo (SSH URL + `secretRef`)
   - `sync.yaml` — `Kustomization` CRD applying `./k8s` from the source
   - `imagerepo.yaml` — `ImageRepository` scanning GHCR
   - `imagepolicy.yaml` — `ImagePolicy` filtering `^main-[0-9]{8}T[0-9]{6}$`, `alphabetical: asc`
   - `imageupdate.yaml` — `ImageUpdateAutomation` writing updated tag back to the app repo

2. **Add the app to** `cluster/apps/kustomization.yaml` resources list.

3. **Add a `$imagepolicy` marker** to the app's `k8s/deployment.yaml`:
   ```yaml
   image: ghcr.io/doemefu/<app>:main-<timestamp> # {"$imagepolicy": "flux-system:<app>"}
   ```

4. **Add a `k8s/kustomization.yaml`** to the app repo listing all manifest files.

5. **Create SSH deploy keys** for write-back (one per app — see `imageupdate.yaml` for the pattern).

6. **Register the Flux config** by committing to the infrastructure repo — Flux picks it up within the next reconciliation interval.

See `cluster/apps/device-service/` as a reference implementation.

---

## Adding a New Role

1. Check if an existing role already covers the concern (`rg` + `git log`)
2. Get explicit approval before introducing a new role (CLAUDE.md non-negotiable)
3. Structure: `tasks/main.yml`, `defaults/main.yml`, `handlers/main.yml`
4. All variables default in `defaults/main.yml`, prefixed with the role name
5. Run `ansible-lint infra/roles/<role>/` — must pass `production` profile
6. Verify idempotency: second run produces 0 changes

## Adding a New Helm Chart

1. Check `cluster/values/` for existing overrides first
2. Add chart reference under `cluster/platform/<name>/`
3. All values in `cluster/values/<name>.yaml` with pinned `version:`
4. Validate: `helm lint cluster/platform/<name>/ -f cluster/values/<name>.yaml`

> **Remote-only charts** (z.B. kube-prometheus-stack): Chart-Repo und Version werden direkt im
> Playbook referenziert — kein lokales `cluster/platform/<name>/` Verzeichnis. `helm lint` entfällt.
> Validierung: `helm template <name> <repo>/<chart> --version <ver> -f cluster/values/<name>.yaml`

---

## Repository Conventions

- **Worklog**: every change gets a worklog in `.agent/worklogs/` (see CLAUDE.md)
- **Secrets**: use SOPS, age key is at `~/.config/age/homelab.key` (not in repo)
- **IPs**: static or DHCP-reserved — k3s requires stable node IPs
- **No `latest`**: all versions pinned in inventory or Helm values
- **group_vars/k3s_server.yml**: overrides `storage_*` defaults for raspi5 (Restic enabled, repo path, backup paths). When adding new backup paths, edit this file — not `storage/defaults/main.yml`.
- **Standard app ownership**: standard infra apps are Ansible-managed unless explicitly listed as Flux-managed.
- **n8n ownership guard**: n8n base resources are Ansible-managed via `infra/playbooks/52_n8n.yml`; do not add `n8n` back to `cluster/apps/kustomization.yaml`.
- **n8n secrets**: do not add `cluster/apps/n8n/secret.yaml`; n8n secrets are provisioned via `infra/playbooks/59_app_services.yml` from SOPS variables.
- **LiteLLM ownership guard**: LiteLLM resources are Ansible-managed via `infra/playbooks/53_litellm.yml`; do not add `litellm` to `cluster/apps/kustomization.yaml` — Flux must not reconcile it.
- **LiteLLM salt key**: `litellm_salt_key` must never be rotated after initial provisioning. Rotation invalidates all virtual keys stored in the LiteLLM database.

## Documentation Ownership Rules

Keep responsibilities split to avoid drift:
- `README.md`: platform context, feature inventory, public URL/API overview.
- `APPS.md`: integration/interface contracts for apps and services.
- `CONTRIBUTING.md`: contributor/agent workflow and guardrails.
- `OPERATIONS.md`: deploy/run/health/troubleshooting procedures.
