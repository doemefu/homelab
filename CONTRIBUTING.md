# Contributing

Development guide for the homelab IaC repository.

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

# Secrets
brew install sops age
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
# Werte eintragen, dann verschlüsseln:
sops -e -i infra/inventory/group_vars/all.sops.yml
```

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
- Namespaces: `platform`, `longhorn-system`, `monitoring`, `apps`
  (Exception: `longhorn-system` ist Helm-Chart-Konvention und wird nicht durch dieses Repo gewählt)
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

---

## Repository Conventions

- **Worklog**: every change gets a worklog in `.agent/worklogs/` (see CLAUDE.md)
- **Secrets**: use SOPS, age key is at `~/.config/age/homelab.key` (not in repo)
- **IPs**: static or DHCP-reserved — k3s requires stable node IPs
- **No `latest`**: all versions pinned in inventory or Helm values
