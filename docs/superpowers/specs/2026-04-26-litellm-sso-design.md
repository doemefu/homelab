# LiteLLM SSO Integration — Design Spec

**Date:** 2026-04-26
**Scope:** Wire LiteLLM UI login to auth-service via OIDC Authorization Code flow (SSO button). API key management remains in LiteLLM dashboard. Master-key login is not removed.

---

## Goal

Users can log into the LiteLLM UI at `https://ai.furchert.ch/ui` using their auth-service credentials via the SSO button. Authenticated SSO users receive the `admin` role in LiteLLM.

---

## Architecture & Data Flow

```
User browser
    │
    ▼
https://ai.furchert.ch/ui   (LiteLLM login page — SSO button visible)
    │  clicks "Sign in with SSO"
    ▼
https://auth.furchert.ch/oauth2/authorize
    │  Authorization Code flow, scope: openid profile email
    ▼
User authenticates at auth-service
    │
    ▼
auth-service redirects to https://ai.furchert.ch/sso/callback
    │  with ?code=...
    ▼
LiteLLM exchanges code for token via auth-service /oauth2/token
    │
    ▼
LiteLLM fetches user info via auth-service /userinfo
    │  claims: email, name
    ▼
LiteLLM creates/finds user in Postgres, assigns role: admin
    │
    ▼
User is logged into LiteLLM UI
```

Auth-service already exposes all required endpoints. No auth-service code changes — only config additions.

---

## Components & Changes

### 1. auth-service — `src/main/resources/application.yaml`

Add a `litellm` OIDC client entry (identical structure to existing `n8n` client):

```yaml
- client-id: litellm
  client-secret: "${LITELLM_CLIENT_SECRET}"
  redirect-uris:
    - https://ai.furchert.ch/sso/callback
  post-logout-redirect-uris:
    - https://ai.furchert.ch
  scopes: [openid, profile, email]
```

### 2. auth-service k8s deployment — `auth-service/k8s/deployment.yaml`

Add env var sourced from `homelab-auth-secrets` (same pattern as `N8N_CLIENT_SECRET`):

```yaml
- name: LITELLM_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: homelab-auth-secrets
      key: litellm-client-secret-authservice
```

### 3. LiteLLM ConfigMap — `cluster/apps/litellm/configmap.yaml`

Add to `general_settings`:

```yaml
sso_callback_url: https://ai.furchert.ch/sso/callback
generic_client_id: litellm
generic_client_secret: os.environ/LITELLM_OIDC_CLIENT_SECRET
generic_authorization_endpoint: https://auth.furchert.ch/oauth2/authorize
generic_token_endpoint: https://auth.furchert.ch/oauth2/token
generic_userinfo_endpoint: https://auth.furchert.ch/userinfo
default_user_params:
  user_role: admin
```

`generic_client_id` is hardcoded (`litellm`) — it is not sensitive. Only the client secret goes through env var.

### 4. LiteLLM Deployment — `cluster/apps/litellm/deployment.yaml`

Add one env var from `litellm-secrets`:

```yaml
- name: LITELLM_OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: litellm-secrets
      key: LITELLM_OIDC_CLIENT_SECRET
```

### 5. Secret bootstrapping — `infra/playbooks/59_app_services.yml`

- Add `litellm_client_secret` to the LiteLLM assert guard
- Write `litellm-client-secret-authservice` (with `{noop}` prefix) into `homelab-auth-secrets` k8s Secret
- Write `LITELLM_OIDC_CLIENT_SECRET` (raw secret) into `litellm-secrets` k8s Secret

### 6. SOPS example — `infra/inventory/group_vars/all.sops.yml.example`

Add:
```yaml
litellm_client_secret: "changeme  # openssl rand -hex 32"
```

---

## What is NOT changing

- Master-key login remains enabled (fallback for CLI, API, and recovery)
- `store_model_in_db` stays `false` — models remain IaC-managed via ConfigMap
- No new playbook — `53_litellm.yml` handles ConfigMap + Deployment, `59_app_services.yml` handles secrets
- No auth-service code changes — only `application.yaml` config + k8s deployment env var
- API key (virtual key) management stays entirely within LiteLLM dashboard

---

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| User cancels SSO at auth-service | Redirected back with error param — LiteLLM shows login page again |
| Wrong/expired client secret | `invalid_client` from token exchange — SSO button fails, master-key login still works |
| auth-service unreachable | SSO flow fails — master-key login remains available |
| User not in auth-service DB | auth-service rejects before redirect — never reaches LiteLLM |

---

## Validation

1. `kubectl rollout status -n apps deployment/litellm` — clean restart after ConfigMap change
2. Browse to `https://ai.furchert.ch/ui` — SSO button visible on login page
3. Click SSO → redirected to `auth.furchert.ch` → login → redirected back → logged in as admin
4. Confirm user appears under **Internal Users** in LiteLLM dashboard
5. Confirm master-key login still works independently

---

## Execution Order

auth-service is managed by Flux CD (syncs from `auth-service/k8s/` in the auth-service git repo every 10m). Changes to auth-service require commits to that repo; Flux reconciles automatically.

```bash
# 1. Add litellm_client_secret to all.sops.yml (infrastructure repo)
sops infra/inventory/group_vars/all.sops.yml

# 2. Bootstrap secrets — updates homelab-auth-secrets + litellm-secrets k8s Secrets
ansible-playbook infra/playbooks/59_app_services.yml

# 3. Commit auth-service changes to auth-service repo
#    - src/main/resources/application.yaml (new litellm OIDC client)
#    - k8s/deployment.yaml (new LITELLM_CLIENT_SECRET env var)
#    Flux reconciles within 10 min, or force:
flux reconcile kustomization auth-service --with-source -n flux-system

# 4. Verify auth-service is running with new config
kubectl rollout status -n apps deployment/auth-service

# 5. Deploy updated LiteLLM ConfigMap + Deployment (hash annotation triggers restart)
ansible-playbook infra/playbooks/53_litellm.yml
```
