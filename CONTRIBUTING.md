# Development Guide — Working on This Infrastructure Repository

This document provides instructions, reminders, and useful information for developers and agents working on **this infrastructure repository itself** (not for deploying apps on the platform — see [APP-DEPLOYMENT.md](APP-DEPLOYMENT.md) for that).

---

## Working Model

Follow this loop for **every change** to this repository:

1. **Research first**: Find source-of-truth files before editing
2. **Keep diffs small**: No unrelated refactors, no opportunistic rewrites
3. **Respect ownership**: Flux-managed and Ansible-managed areas must not be mixed
4. **Protect secrets**: Plaintext secrets never belong in Git; use SOPS-backed vars
5. **Prove consistency**: Commands/URLs/ports in docs must match manifests/playbooks
6. **Lint always**: Run `ansible-lint` before committing
7. **Verify idempotency**: Second Ansible run must produce 0 changes

---

## Fast File Map

**Where to change what**:

| Topic | File(s) | Playbook |
|-------|---------|----------|
| Node bootstrap / base hardening | `infra/playbooks/00_bootstrap.yml`, `10_base.yml` | - |
| SSH hardening (keys only, no password, no root) | `infra/roles/hardening/` | `10_base.yml` |
| UFW firewall rules | `infra/roles/hardening/tasks/main.yml` | `10_base.yml` |
| k3s installation / configuration | `infra/playbooks/20_k3s.yml`, `infra/roles/k3s/` | `20_k3s.yml` |
| k3s version pinning | `infra/roles/k3s/defaults/main.yml` (`k3s_version`) | `20_k3s.yml` |
| Longhorn storage | `infra/playbooks/30_longhorn.yml`, `cluster/values/longhorn.yaml` | `30_longhorn.yml` |
| Default StorageClass | `infra/playbooks/30_longhorn.yml` (sets longhorn as default) | `30_longhorn.yml` |
| cert-manager / TLS | `infra/playbooks/40_platform.yml`, `cluster/values/cert-manager.yaml` | `40_platform.yml` |
| Cloudflare Tunnel | `infra/playbooks/40_platform.yml`, `cluster/values/cloudflared.yaml` | `40_platform.yml` |
| Cloudflare Tunnel ingress list | `infra/playbooks/40_platform.yml` (`cf_ingress_body` fact) | `40_platform.yml` |
| Traefik configuration | `infra/playbooks/40_platform.yml` (HelmChartConfig) | `40_platform.yml` |
| Monitoring (Prometheus/Grafana/Alertmanager) | `infra/playbooks/41_monitoring.yml`, `cluster/values/kube-prometheus-stack.yaml` | `41_monitoring.yml` |
| Alertmanager Discord webhook | `infra/playbooks/41_monitoring.yml` (Helm values) | `41_monitoring.yml` |
| Shared app infrastructure | `infra/playbooks/50_apps_infra.yml`, `cluster/values/{postgresql,influxdb2}.yaml` | `50_apps_infra.yml` |
| Home Assistant | `infra/playbooks/51_homeassistant.yml`, `cluster/values/home-assistant.yaml` | `51_homeassistant.yml` |
| n8n runtime | `infra/playbooks/52_n8n.yml`, `cluster/apps/n8n/` | `52_n8n.yml` |
| LiteLLM runtime | `infra/playbooks/53_litellm.yml`, `cluster/apps/litellm/` | `53_litellm.yml` |
| App secrets / DB bootstrap | `infra/playbooks/59_app_services.yml` | `59_app_services.yml` |
| Flux GitOps | `cluster/apps/{auth-service,device-service}/`, `cluster/flux-system/apps-sync.yaml` | manual `kubectl apply` |
| Node inventory / IPs | `infra/inventory/hosts.yml` | - |
| Common variables (non-secret) | `infra/inventory/group_vars/all.yml` | - |
| Secrets (SOPS) | `infra/inventory/group_vars/all.sops.yml` | - |
| Control-plane specific vars | `infra/inventory/group_vars/k3s_server.yml` | - |
| Worker specific vars | `infra/inventory/group_vars/k3s_agent.yml` | - |
| Mac-specific vars | `infra/inventory/group_vars/mac.yml` | - |
| Helm values | `cluster/values/<chart>.yaml` | Referenced by playbooks |

---

## Local Setup

### Prerequisites (Mac)

```bash
# Ansible + lint
pip install ansible ansible-lint --break-system-packages
ansible-galaxy collection install -r infra/requirements.yml -p ~/.ansible/collections

# Kubernetes tooling (for M2+)
# Note: kubernetes.core.helm requires Helm <4.0.0
brew install helm@3 kubectl

# helm-diff plugin (eliminates idempotency warnings)
# Intel Mac:
/usr/local/opt/helm@3/bin/helm plugin install https://github.com/databus23/helm-diff
# Apple Silicon:
/opt/homebrew/opt/helm@3/bin/helm plugin install https://github.com/databus23/helm-diff

# Secrets + GitOps CLI
brew install sops age fluxcd/tap/flux
```

> **Helm 4 Warning**: `brew install helm` installs Helm 4.x, which is NOT supported by `kubernetes.core.helm` (constraint `<4.0.0`). You **MUST** use helm@3. Set the path in `infra/inventory/group_vars/all.yml`:
> - Intel-Mac: `/usr/local/opt/helm@3/bin/helm`
> - Apple Silicon: `/opt/homebrew/opt/helm@3/bin/helm`

### age Key Setup (Once, Stored Outside Repo)

```bash
# Generate key
mkdir -p ~/.config/age
age-keygen -o ~/.config/age/homelab.key

# Add to shell profile (required by sops and Ansible vars plugin)
echo 'export SOPS_AGE_KEY_FILE=~/.config/age/homelab.key' >> ~/.zshrc
source ~/.zshrc
```

The public key in `.sops.yaml` must match your age key. Contact the repo owner if you need access.

### Initialize Secrets (One-Time After Clone)

```bash
# Copy the example file
cp infra/inventory/group_vars/all.sops.yml.example \
   infra/inventory/group_vars/all.sops.yml

# Edit the file, replacing all CHANGE_ME entries with actual values
# Then encrypt in-place:
sops -e -i infra/inventory/group_vars/all.sops.yml
```

---

## Ansible Development Workflow

### Before Every Change

```bash
# Lint everything
ansible-lint infra/

# Dry-run against a single node
ansible-playbook infra/playbooks/<playbook>.yml --check --diff -l <node>
```

### After Changes

```bash
# Real run, single node
ansible-playbook infra/playbooks/<playbook>.yml -l <node>

# Idempotency check — second run must produce 0 changes
ansible-playbook infra/playbooks/<playbook>.yml -l <node>
# → Expect: PLAY RECAP: changed=0
```

### For Documentation-Only Changes

```bash
# Verify referenced facts against source files
# Search for references in docs:
rg -n "playbook|host|port|service>" OVERVIEW.md INTERFACES.md DEPLOYMENT.md APP-DEPLOYMENT.md

# Verify those references exist in actual files:
rg -n "<same_pattern>" infra/playbooks/ cluster/apps/ cluster/values/ infra/inventory/
```

### Bootstrap a New Node (Initial Setup, Run Once)

```bash
ansible-playbook infra/playbooks/00_bootstrap.yml \
  -e ansible_user=<initial-node-user> -l <node> --become
```

> **Note**: The `-e ansible_user=<initial-user>` sets the **connection user** (existing account on the node). The **created** user is always `ansible` (hardcoded). After bootstrap, all subsequent playbooks connect as the `ansible` user.

> **Important**: Use `-e`, not `-u` — `group_vars/all.yml` sets `ansible_user: ansible` and takes precedence over `-u`.

---

## Code Style

### Ansible

- **Indentation**: 2 spaces, no tabs
- **Task names**: Every task MUST have a descriptive `name:` starting with uppercase letter
- **Variable naming**: Prefix with role name (e.g., `hardening_lan_subnet`, `mac_tweaks_kernel_modules`)
- **No hardcoded IPs/hostnames**: Use inventory variables
- **Architecture conditions**: Use `ansible_architecture`, never hostname-based conditionals:
  ```yaml
  when: ansible_architecture == "x86_64"   # MBA nodes
  when: ansible_architecture == "aarch64"  # Raspberry Pi nodes
  ```
- **Service start tasks**: Newly installed services need `ignore_errors: "{{ ansible_check_mode }}"` on start/restart tasks and handlers so `--check` mode doesn't fail
- **Handlers**: Use handlers for service restarts, not inline tasks

### Kubernetes / Helm

- **Helm values**: All overrides in `cluster/values/<chart-name>.yaml` — nothing inline in playbooks
- **Pinned versions**: NO `latest` for images, charts, or k3s — always pin versions
- **Namespaces**: Only these are permitted: `platform`, `longhorn-system`, `monitoring`, `apps`, `homeassistant`, `flux-system`
- **ServiceMonitors**: Must live in `monitoring` namespace with label `release: kube-prometheus-stack` — never in `apps`
- **Resource limits**: REQUIRED for all workloads in `apps` namespace

### Secrets

- **NEVER** commit plaintext secrets — ever
- **Always** encrypt with SOPS before committing: `sops -e -i <file>`
- Files matching `.sops.yaml` rules are auto-encrypted on `sops -e -i`
- Use `no_log: true` on sensitive Ansible tasks

### YAML

- 2-space indentation
- No trailing whitespace
- Quotes around strings that could be misinterpreted (e.g., `"yes"`, `"no"`, strings with colons)

---

## Known Lint Rules (ansible-lint production profile)

| Issue | Fix |
|-------|-----|
| Task name starts lowercase | Capitalize: `"Fail2ban ..."` not `"fail2ban ..."` |
| `var-naming[no-role-prefix]` | Prefix vars with role name: `mac_tweaks_*` |
| `args[module]` on loop with template value | Use explicit tasks instead of loop for static choices |
| `stdout_callback = yaml` | Use `stdout_callback = ansible.builtin.default` + `result_format = yaml` |
| `validate:` on SSH drop-in | Don't use `validate:` for `/etc/ssh/sshd_config.d/*.conf` — `sshd -t` needs a full config file |

---

## Repository Conventions

### Worklog Requirement

**Every change** to this repository MUST have a corresponding worklog in `.agent/worklogs/`.

Worklog template: `.agent/worklog-template.md`

### Version Pinning

- **NO `latest` tags** — all versions must be pinned
- k3s version: `infra/roles/k3s/defaults/main.yml` (`k3s_version`)
- Helm chart versions: In `cluster/values/<chart>.yaml` (`version:` field) or in playbook `chart_version:`
- Container images: Pinned tags in deployment manifests
- Python packages: `infra/requirements.yml`

### IP Addresses

- Node IPs are **static or DHCP-reserved** in `infra/inventory/hosts.yml`
- k3s requires **stable node IPs**
- Never hardcode IPs in role code — use inventory variables

### File Ownership Guardrails

**NEVER mix these ownership models**:

| Resource | Owner | Do NOT |
|----------|-------|-------|
| n8n resources | Ansible (`52_n8n.yml`) | Add to `cluster/apps/kustomization.yaml` |
| LiteLLM resources | Ansible (`53_litellm.yml`) | Add to `cluster/apps/kustomization.yaml` |
| Flux resources | Flux CD | Manually `kubectl apply` |
| App secrets | Ansible (`59_app_services.yml`) | Commit plaintext to git |

### Standard App Ownership

- **Flux-managed**: `auth-service`, `device-service`
- **Ansible-managed**: `n8n`, `litellm`, `homeassistant`, PostgreSQL, InfluxDB, Mosquitto
- **Platform-managed**: cert-manager, cloudflared, Traefik, Longhorn, kube-prometheus-stack

---

## Documentation Ownership

Each file has a specific purpose to prevent drift:

| File | Responsibility | What belongs here |
|------|---------------|-------------------|
| **OVERVIEW.md** | Platform context | What this repo is, architecture, features, public URLs, APIs, status, repo structure |
| **INTERFACES.md** | Integration contracts | How services interact with the platform, namespace contract, service discovery, API/auth interfaces |
| **DEVELOPMENT.md** | Contributor workflow | This file — how to work on the repo, local setup, Ansible workflow, style guides |
| **DEPLOYMENT.md** | Cluster operations | How to deploy/operate the cluster, prerequisites, step-by-step, health checks, troubleshooting |
| **APP-DEPLOYMENT.md** | App developer guide | How external developers deploy THEIR apps on this platform |

---

## Adding New Components

### Adding a Flux-Managed App

**Prerequisites**:
- App has its own Git repository
- App uses timestamped image tags (`main-YYYYMMDDTHHmmss`)
- App needs automatic image updates

**Steps**:

1. Create Flux config directory:
   ```bash
   mkdir -p cluster/apps/<app-name>
   ```

2. Create these files in `cluster/apps/<app-name>/`:
   
   **kustomization.yaml**:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - source.yaml
     - sync.yaml
     - imagerepo.yaml
     - imagepolicy.yaml
     - imageupdate.yaml
   ```
   
   **source.yaml**:
   ```yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: <app-name>
     namespace: flux-system
   spec:
     interval: 10m
     url: git@github.com:doemefu/<app-name>.git
     secretRef:
       name: <app-name>-flux-auth
     branch: main
   ```
   
   **imagerepo.yaml**:
   ```yaml
   apiVersion: image.toolkit.fluxcd.io/v1
   kind: ImageRepository
   metadata:
     name: <app-name>
     namespace: flux-system
   spec:
     image: ghcr.io/doemefu/<app-name>
     interval: 10m
     secretRef:
       name: ghcr-auth
   ```
   
   **imagepolicy.yaml**:
   ```yaml
   apiVersion: image.toolkit.fluxcd.io/v1
   kind: ImagePolicy
   metadata:
     name: <app-name>
     namespace: flux-system
   spec:
     imageRepositoryRef:
       name: <app-name>
       namespace: flux-system
     filter:
       pattern: "^main-[0-9]{8}T[0-9]{6}$"
     policy:
       alphabetical:
         order: asc
   ```
   
   **imageupdate.yaml**:
   ```yaml
   apiVersion: image.toolkit.fluxcd.io/v1
   kind: ImageUpdateAutomation
   metadata:
     name: <app-name>
     namespace: flux-system
   spec:
     interval: 5m
     sourceRef:
       kind: GitRepository
       name: <app-name>
       namespace: flux-system
     update:
       strategy: Setters
       path: ./k8s
     git:
       commit:
         author:
           name: flux
           email: flux@example.com
         messageTemplate: "{{ .Object }}"
       push:
         branch: main
   ```

3. Add to cluster apps:
   ```bash
   # Edit cluster/apps/kustomization.yaml
   # Add <app-name> to resources list
   ```

4. **App repository setup**:
   - Create `k8s/` directory with all manifests
   - Create `k8s/kustomization.yaml` listing all manifest files
   - Add marker: `image: ghcr.io/...:main-<timestamp> # {"$imagepolicy": "flux-system:<app-name>"}`
   - Create SSH deploy key (write access) and store as Secret in `flux-system` namespace

5. Register Flux:
   ```bash
   kubectl apply -f cluster/flux-system/apps-sync.yaml
   ```

**Reference**: See `cluster/apps/device-service/` as a complete example.

### Adding a New Ansible Role

1. Get explicit approval (CLAUDE.md non-negotiable)
2. Check for existing coverage: `rg <concern> infra/roles/`
3. Structure:
   ```
   infra/roles/<role>/
     defaults/
       main.yml
     tasks/
       main.yml
     handlers/
       main.yml
   ```
4. All variables default in `defaults/main.yml`, prefixed with role name
5. Lint: `ansible-lint infra/roles/<role>/` must pass production profile
6. Verify idempotency: second run produces 0 changes

---

## Useful Commands Cheat Sheet

### Git

```bash
git status
git diff --stat
git log --oneline -- <path>
git grep "search_string"
```

### Ansible

```bash
ansible all --list-hosts
ansible-playbook <playbook>.yml --list-tags
ansible-playbook <playbook>.yml --tags "tag1,tag2"
ansible-playbook <playbook>.yml --check --diff
ansible-playbook <playbook>.yml -l <node>
ansible <node> -m setup
ansible <node> -m command -a "<command>"
```

### Kubernetes

```bash
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get all -A
kubectl get pods -A -o wide
kubectl get events -A --sort-by='.lastTimestamp'
kubectl top nodes
kubectl top pods -A
kubectl port-forward -n <ns> svc/<svc> <local>:<remote>
kubectl logs -n <ns> <pod> [-f | --previous]
kubectl exec -it -n <ns> <pod> -- /bin/bash
kubectl describe -n <ns> <type>/<name>
```

### Flux

```bash
flux check
flux get all -A
flux get sources git -n flux-system
flux get kustomizations -n flux-system
flux reconcile kustomization <app> -n flux-system --with-source
flux logs -n flux-system --kind=Kustomization --name=<app>
flux suspend image update <app> -n flux-system
flux resume image update <app> -n flux-system
```

### SOPS

```bash
sops infra/inventory/group_vars/all.sops.yml
sops -e -i <file>
sops -d <file>
sops --decrypt --extract '["key"]' <file>
```

### Search

```bash
rg "pattern" .
rg -n "pattern"
rg -l "pattern"
rg -A 2 -B 2 "pattern"
rg --type yaml "pattern"
```

---

## Common Pitfalls

1. **Secrets in plaintext**: Run `git grep -n "password\|secret\|token\|key" --and --not -- ".sops.yml"` before committing
2. **Mixed ownership**: Don't add `n8n` or `litellm` to Flux `kustomization.yaml`
3. **Latest tags**: Always pin versions. Use `rg "latest" infra/ cluster/` to find violations
4. **Architecture**: Always verify images support both architectures before deploying
5. **Resource limits**: Always set for `apps` namespace. Check with `kubectl top pods -n apps`
6. **Documentation consistency**: After any code change, verify all references in docs match
