# LiteLLM SSO Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the LiteLLM UI login at `https://ai.furchert.ch/ui` to auth-service via OIDC Authorization Code flow so users can sign in with their auth-service credentials; authenticated users receive the `admin` role.

**Architecture:** LiteLLM's built-in generic OIDC SSO is configured to point at auth-service's existing endpoints. A new `litellm` OIDC client is registered in auth-service (same pattern as n8n/grafana). The client secret flows from SOPS → Ansible → two k8s Secrets (`homelab-auth-secrets` for auth-service, `litellm-secrets` for LiteLLM). Master-key login is not removed.

**Tech Stack:** Ansible (59_app_services.yml, 53_litellm.yml), Kubernetes/kubectl, Flux CD (auth-service sync), LiteLLM generic OIDC, Spring Boot YAML (auth-service), SOPS+age

---

## File Map

| File | Change |
|------|--------|
| `infra/inventory/group_vars/all.sops.yml.example` | Add `litellm_client_secret` placeholder |
| `infra/inventory/group_vars/all.sops.yml` | Add `litellm_client_secret` value (**user action, not committed in plain**) |
| `infra/playbooks/59_app_services.yml` | Assert guard + `homelab-auth-secrets` key + `litellm-secrets` key |
| `cluster/apps/litellm/configmap.yaml` | Add SSO settings to `general_settings` |
| `cluster/apps/litellm/deployment.yaml` | Add `LITELLM_OIDC_CLIENT_SECRET` env var |
| `auth-service/src/main/resources/application.yaml` | Add `litellm` OIDC client entry |
| `auth-service/k8s/deployment.yaml` | Add `LITELLM_CLIENT_SECRET` env var |

---

## Task 1: Add `litellm_client_secret` to SOPS example and secrets file

**Files:**
- Modify: `infra/inventory/group_vars/all.sops.yml.example`
- Modify (user action): `infra/inventory/group_vars/all.sops.yml` (gitignored, SOPS-encrypted)

- [ ] **Step 1.1: Add placeholder to all.sops.yml.example**

In `infra/inventory/group_vars/all.sops.yml.example`, add after the `mistral_api_key` line at the bottom:

```yaml
# LiteLLM OIDC client secret — shared with auth-service for SSO UI login
# Generate: openssl rand -hex 32
litellm_client_secret: "CHANGE_ME_openssl_rand_hex_32"
```

- [ ] **Step 1.2: Add the real value to all.sops.yml (user action)**

Generate and add to the encrypted SOPS file:

```bash
openssl rand -hex 32
# Copy the output, then:
sops infra/inventory/group_vars/all.sops.yml
# Add at the bottom:
# litellm_client_secret: "<generated value>"
# Save and close — SOPS re-encrypts automatically
```

- [ ] **Step 1.3: Commit the example file**

```bash
git add infra/inventory/group_vars/all.sops.yml.example
git commit -m "feat(secrets): add litellm_client_secret placeholder to SOPS example"
```

---

## Task 2: Update 59_app_services.yml — assert + secrets

**Files:**
- Modify: `infra/playbooks/59_app_services.yml`

- [ ] **Step 2.1: Add `litellm_client_secret` to the LiteLLM assert guard**

In `infra/playbooks/59_app_services.yml`, find the existing LiteLLM assert block (around line 246–258):

```yaml
    - name: LiteLLM — Prüfen dass alle benötigten SOPS-Variablen gesetzt sind
      ansible.builtin.assert:
        that:
          - litellm_master_key | default('') | length > 0
          - litellm_master_key is match('^sk-')
          - litellm_salt_key | default('') | length > 0
          - litellm_db_password | default('') | length > 0
          - mistral_api_key | default('') | length > 0
        fail_msg: >-
          One or more required LiteLLM SOPS variables are missing or invalid.
          litellm_master_key must start with 'sk-'.
          Add them to infra/inventory/group_vars/all.sops.yml — see all.sops.yml.example for commands.
      delegate_to: localhost
```

Replace with (add `litellm_client_secret` assertion):

```yaml
    - name: LiteLLM — Prüfen dass alle benötigten SOPS-Variablen gesetzt sind
      ansible.builtin.assert:
        that:
          - litellm_master_key | default('') | length > 0
          - litellm_master_key is match('^sk-')
          - litellm_salt_key | default('') | length > 0
          - litellm_db_password | default('') | length > 0
          - mistral_api_key | default('') | length > 0
          - litellm_client_secret | default('') | length > 0
        fail_msg: >-
          One or more required LiteLLM SOPS variables are missing or invalid.
          litellm_master_key must start with 'sk-'.
          Add them to infra/inventory/group_vars/all.sops.yml — see all.sops.yml.example for commands.
      delegate_to: localhost
```

- [ ] **Step 2.2: Add `litellm-client-secret-authservice` to `homelab-auth-secrets`**

Find the `homelab-auth-secrets` task (around line 194–211):

```yaml
    - name: Homelab-auth-secrets anlegen (OAuth2 client secrets)
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: homelab-auth-secrets
            namespace: "{{ apps_namespace }}"
          type: Opaque
          stringData:
            grafana-client-secret: "{{ auth_service_grafana_client_secret }}"
            ha-client-secret: "{{ auth_service_ha_client_secret }}"
            device-service-client-secret: "{noop}{{ auth_service_device_service_client_secret }}"
            n8n-client-secret-authservice: "{noop}{{ auth_service_n8n_client_secret }}"
            n8n-client-secret: "{{ auth_service_n8n_client_secret }}"
      no_log: true
      delegate_to: localhost
```

Replace with (add `litellm-client-secret-authservice`):

```yaml
    - name: Homelab-auth-secrets anlegen (OAuth2 client secrets)
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: homelab-auth-secrets
            namespace: "{{ apps_namespace }}"
          type: Opaque
          stringData:
            grafana-client-secret: "{{ auth_service_grafana_client_secret }}"
            ha-client-secret: "{{ auth_service_ha_client_secret }}"
            device-service-client-secret: "{noop}{{ auth_service_device_service_client_secret }}"
            n8n-client-secret-authservice: "{noop}{{ auth_service_n8n_client_secret }}"
            n8n-client-secret: "{{ auth_service_n8n_client_secret }}"
            litellm-client-secret-authservice: "{noop}{{ litellm_client_secret }}"
      no_log: true
      delegate_to: localhost
```

- [ ] **Step 2.3: Add `LITELLM_OIDC_CLIENT_SECRET` to `litellm-secrets`**

Find the `LiteLLM-secrets anlegen` task (around line 331–348):

```yaml
    - name: LiteLLM-secrets anlegen (API keys, master key, salt key, DB URL)
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: litellm-secrets
            namespace: "{{ apps_namespace }}"
          type: Opaque
          stringData:
            LITELLM_MASTER_KEY: "{{ litellm_master_key }}"
            LITELLM_SALT_KEY: "{{ litellm_salt_key }}"
            DATABASE_URL: "postgresql://litellm:{{ litellm_db_password }}@postgresql.apps.svc.cluster.local:5432/litellm"
            ANTHROPIC_API_KEY: "{{ anthropic_api_key | default('') }}"
            MISTRAL_API_KEY: "{{ mistral_api_key }}"
      no_log: true
      delegate_to: localhost
```

Replace with (add `LITELLM_OIDC_CLIENT_SECRET`):

```yaml
    - name: LiteLLM-secrets anlegen (API keys, master key, salt key, DB URL)
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: litellm-secrets
            namespace: "{{ apps_namespace }}"
          type: Opaque
          stringData:
            LITELLM_MASTER_KEY: "{{ litellm_master_key }}"
            LITELLM_SALT_KEY: "{{ litellm_salt_key }}"
            DATABASE_URL: "postgresql://litellm:{{ litellm_db_password }}@postgresql.apps.svc.cluster.local:5432/litellm"
            ANTHROPIC_API_KEY: "{{ anthropic_api_key | default('') }}"
            MISTRAL_API_KEY: "{{ mistral_api_key }}"
            LITELLM_OIDC_CLIENT_SECRET: "{{ litellm_client_secret }}"
      no_log: true
      delegate_to: localhost
```

- [ ] **Step 2.4: Update the header comment in 59_app_services.yml**

Find the LiteLLM variables comment block in the header (around line 32–38):

```
# LiteLLM variables (generate with commands in all.sops.yml.example):
#   litellm_master_key:   sk-<openssl rand -hex 16>   # Bearer token for API access
#   litellm_salt_key:     <openssl rand -hex 32>       # WARNING: permanent — never rotate after first use
#   litellm_db_password:  <openssl rand -hex 16>       # Postgres password for litellm user
#   anthropic_api_key:    <from console.anthropic.com>
#   mistral_api_key:      <from console.mistral.ai>
```

Replace with:

```
# LiteLLM variables (generate with commands in all.sops.yml.example):
#   litellm_master_key:     sk-<openssl rand -hex 16>   # Bearer token for API access
#   litellm_salt_key:       <openssl rand -hex 32>       # WARNING: permanent — never rotate after first use
#   litellm_db_password:    <openssl rand -hex 16>       # Postgres password for litellm user
#   anthropic_api_key:      <from console.anthropic.com>
#   mistral_api_key:        <from console.mistral.ai>
#   litellm_client_secret:  <openssl rand -hex 32>       # OIDC client secret for SSO UI login
```

- [ ] **Step 2.5: Lint check**

```bash
ansible-lint infra/playbooks/59_app_services.yml
```

Expected: `Passed: 0 failure(s), 0 warning(s)`

- [ ] **Step 2.6: Commit**

```bash
git add infra/playbooks/59_app_services.yml
git commit -m "feat(secrets): add litellm OIDC client secret to homelab-auth-secrets and litellm-secrets"
```

---

## Task 3: Update LiteLLM ConfigMap — add SSO settings

**Files:**
- Modify: `cluster/apps/litellm/configmap.yaml`

- [ ] **Step 3.1: Add SSO settings to `general_settings`**

The current `general_settings` block in `cluster/apps/litellm/configmap.yaml` (lines 45–50):

```yaml
    general_settings:
      # os.environ/ syntax: LiteLLM reads value from env var at runtime.
      # The literal key values must NEVER appear here — they live in litellm-secrets only.
      master_key: os.environ/LITELLM_MASTER_KEY
      database_url: os.environ/DATABASE_URL
      store_model_in_db: false
```

Replace with:

```yaml
    general_settings:
      # os.environ/ syntax: LiteLLM reads value from env var at runtime.
      # The literal key values must NEVER appear here — they live in litellm-secrets only.
      master_key: os.environ/LITELLM_MASTER_KEY
      database_url: os.environ/DATABASE_URL
      store_model_in_db: false
      sso_callback_url: https://ai.furchert.ch/sso/callback
      generic_client_id: litellm
      generic_client_secret: os.environ/LITELLM_OIDC_CLIENT_SECRET
      generic_authorization_endpoint: https://auth.furchert.ch/oauth2/authorize
      generic_token_endpoint: https://auth.furchert.ch/oauth2/token
      generic_userinfo_endpoint: https://auth.furchert.ch/userinfo
      default_user_params:
        user_role: admin
```

- [ ] **Step 3.2: Commit**

```bash
git add cluster/apps/litellm/configmap.yaml
git commit -m "feat(litellm): add generic OIDC SSO settings pointing at auth-service"
```

---

## Task 4: Update LiteLLM Deployment — add env var

**Files:**
- Modify: `cluster/apps/litellm/deployment.yaml`

- [ ] **Step 4.1: Add `LITELLM_OIDC_CLIENT_SECRET` env var**

In `cluster/apps/litellm/deployment.yaml`, find the `env:` block. After the `ANTHROPIC_API_KEY` entry (around line 53–57):

```yaml
            - name: ANTHROPIC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-secrets
                  key: ANTHROPIC_API_KEY
```

Add after it:

```yaml
            - name: LITELLM_OIDC_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: litellm-secrets
                  key: LITELLM_OIDC_CLIENT_SECRET
```

- [ ] **Step 4.2: Commit**

```bash
git add cluster/apps/litellm/deployment.yaml
git commit -m "feat(litellm): add LITELLM_OIDC_CLIENT_SECRET env var for SSO"
```

---

## Task 5: Register `litellm` OIDC client in auth-service

**Files:**
- Modify: `../auth-service/src/main/resources/application.yaml`

> Note: auth-service lives in a separate git repo (`homelab/auth-service`). Changes here require a commit to that repo; Flux CD reconciles within 10 minutes or on demand.

- [ ] **Step 5.1: Add `litellm` OIDC client to application.yaml**

In `auth-service/src/main/resources/application.yaml`, find the `clients:` list under `app.oidc`. After the `n8n` client entry (currently last in the list, ending around line 66):

```yaml
      - client-id: n8n
        # The env var must include the Spring Security {id} prefix, e.g. "{noop}secret" or "{bcrypt}$2a$...".
        client-secret: "${N8N_CLIENT_SECRET}"
        redirect-uris:
          - https://n8n.furchert.ch/rest/sso/oidc/callback
        post-logout-redirect-uris:
          - https://n8n.furchert.ch
        scopes: [openid, profile, email]
```

Add after it:

```yaml
      - client-id: litellm
        # The env var must include the Spring Security {id} prefix, e.g. "{noop}secret" or "{bcrypt}$2a$...".
        client-secret: "${LITELLM_CLIENT_SECRET}"
        redirect-uris:
          - https://ai.furchert.ch/sso/callback
        post-logout-redirect-uris:
          - https://ai.furchert.ch
        scopes: [openid, profile, email]
```

- [ ] **Step 5.2: Commit to auth-service repo**

```bash
cd ../auth-service
git add src/main/resources/application.yaml
git commit -m "feat(oidc): register litellm OIDC client for SSO UI login"
```

---

## Task 6: Add `LITELLM_CLIENT_SECRET` env var to auth-service deployment

**Files:**
- Modify: `../auth-service/k8s/deployment.yaml`

> Same repo as Task 5. Flux syncs `auth-service/k8s/` on each commit.

- [ ] **Step 6.1: Add `LITELLM_CLIENT_SECRET` env var**

In `auth-service/k8s/deployment.yaml`, find the `N8N_CLIENT_SECRET` env var entry (around line 57–64):

```yaml
            - name: N8N_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: homelab-auth-secrets
                  # auth-service expects Spring Security encoded secret ({noop}/{bcrypt}).
                  # We keep a dedicated key so n8n can consume the same client secret in raw form
                  # from a different key without the Spring prefix.
                  key: n8n-client-secret-authservice
```

Add after it:

```yaml
            - name: LITELLM_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: homelab-auth-secrets
                  key: litellm-client-secret-authservice
```

- [ ] **Step 6.2: Commit to auth-service repo**

```bash
git add k8s/deployment.yaml
git commit -m "feat(k8s): inject LITELLM_CLIENT_SECRET env var from homelab-auth-secrets"
cd ../infrastructure
```

---

## Task 7: Apply changes and validate

- [ ] **Step 7.1: Bootstrap updated k8s Secrets**

Run `59_app_services.yml` to push `litellm-client-secret-authservice` into `homelab-auth-secrets` and `LITELLM_OIDC_CLIENT_SECRET` into `litellm-secrets`:

```bash
ansible-playbook infra/playbooks/59_app_services.yml
```

Expected output: tasks for `homelab-auth-secrets` and `LiteLLM-secrets` show `changed` (Secret updated with new keys).

- [ ] **Step 7.2: Trigger Flux reconcile for auth-service**

Flux syncs every 10 minutes automatically. To force immediately:

```bash
flux reconcile kustomization auth-service --with-source -n flux-system
```

Expected: `► annotating GitRepository auth-service ... ✔ GitRepository annotated` then `✔ applied revision`

- [ ] **Step 7.3: Verify auth-service rollout**

```bash
kubectl rollout status -n apps deployment/auth-service --timeout=120s
```

Expected: `deployment "auth-service" successfully rolled out`

- [ ] **Step 7.4: Confirm auth-service picked up the new client**

```bash
kubectl logs -n apps deployment/auth-service --tail=30 | grep -i "litellm\|oidc\|client\|error"
```

Expected: no errors; the Spring Boot startup log should not show any `litellm` binding errors. If `LITELLM_CLIENT_SECRET` is missing from the Secret, the pod will fail with `No such property: LITELLM_CLIENT_SECRET` — check Step 7.1.

- [ ] **Step 7.5: Deploy updated LiteLLM ConfigMap + Deployment**

```bash
ansible-playbook infra/playbooks/53_litellm.yml
```

Expected: `LiteLLM ConfigMap anlegen` shows `changed`; hash annotation task triggers rollout; `LiteLLM Rollout warten` waits up to 600s.

- [ ] **Step 7.6: Verify SSO button appears on login page**

Browse to `https://ai.furchert.ch/ui`. The login page should show a **"Sign in with SSO"** button below the email/password fields.

If the button is absent: check LiteLLM pod logs for SSO config errors:

```bash
kubectl logs -n apps deployment/litellm | grep -i "sso\|oidc\|generic\|error" | tail -20
```

- [ ] **Step 7.7: End-to-end SSO login test**

1. Click **"Sign in with SSO"** on `https://ai.furchert.ch/ui`
2. Confirm redirect to `https://auth.furchert.ch/oauth2/authorize`
3. Log in with auth-service credentials
4. Confirm redirect back to `https://ai.furchert.ch/ui` — you should be logged in
5. Navigate to **Internal Users** in the LiteLLM dashboard — your email should appear with role `admin`

- [ ] **Step 7.8: Verify master-key login still works**

Log out of LiteLLM UI. On the login page, enter the master key (`litellm_master_key` from SOPS) directly in the API key field and confirm login succeeds.

- [ ] **Step 7.9: Final lint check on all modified infrastructure files**

```bash
ansible-lint infra/playbooks/59_app_services.yml infra/playbooks/53_litellm.yml
```

Expected: `Passed: 0 failure(s), 0 warning(s)`

- [ ] **Step 7.10: Commit infrastructure repo summary commit**

```bash
git add infra/inventory/group_vars/all.sops.yml.example \
        infra/playbooks/59_app_services.yml \
        cluster/apps/litellm/configmap.yaml \
        cluster/apps/litellm/deployment.yaml
git commit -m "feat(litellm): SSO UI login via auth-service OIDC

- 59_app_services.yml: litellm_client_secret assert + homelab-auth-secrets + litellm-secrets
- configmap.yaml: generic OIDC SSO settings (auth.furchert.ch endpoints, admin role)
- deployment.yaml: LITELLM_OIDC_CLIENT_SECRET env var from litellm-secrets
- all.sops.yml.example: litellm_client_secret placeholder"
```
