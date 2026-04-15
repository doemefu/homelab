# n8n Deployment Plan

## Overview
This plan outlines the deployment of n8n workflow automation tool in the Kubernetes cluster, making it available at `n8n.furchert.ch` using the existing Cloudflare Tunnel infrastructure **with authentication provided by the homelab-auth-service OIDC provider**.

## Architecture
- **Deployment**: Kubernetes Deployment in `apps` namespace
- **Service**: ClusterIP service on port 80, targeting n8n's port 5678
- **Exposure**: Cloudflare Tunnel (no Kubernetes Ingress needed)
- **Authentication**: OIDC via homelab-auth-service (Spring Authorization Server)
- **Persistence**: 5Gi Longhorn PVC for workflows and SQLite data
- **GitOps**: FluxCD for automatic deployment

## Components Created

### 1. Kubernetes Manifests (`cluster/apps/n8n/`)
- `pvc.yaml`: 5Gi PersistentVolumeClaim for n8n data (Longhorn storage)
- `deployment.yaml`: n8n Deployment with:
  - Pinned version 2.17.1
  - OIDC SSO authentication via homelab-auth-service
  - Liveness, readiness, and startup probes
  - Persistence volume mount at `/home/node/.n8n`
  - Encryption key environment variable
  - Webhook URL configuration
  - Resource limits
- `service.yaml`: ClusterIP service exposing port 80
- `kustomization.yaml`: FluxCD kustomization

### 2. Configuration Updates
- `cluster/apps/kustomization.yaml`: Added n8n to FluxCD resources
- `infra/playbooks/40_platform.yml`: Added n8n to Cloudflare Tunnel ingress
- `infra/playbooks/52_app_services.yml`: Added n8n client secrets + n8n-secrets creation
- `infra/inventory/group_vars/all.sops.yml.example`: Documented n8n client secret + encryption key

## Critical Configuration Details

### Authentication: OIDC with homelab-auth-service

n8n will authenticate users via the existing **homelab-auth-service** (Spring Authorization Server).

**OIDC Configuration (supported n8n env vars):**
```yaml
N8N_SSO_MANAGED_BY_ENV: "true"
N8N_SSO_OIDC_LOGIN_ENABLED: "true"
N8N_SSO_OIDC_CLIENT_ID: "n8n"
N8N_SSO_OIDC_CLIENT_SECRET: from homelab-auth-secrets (key: n8n-client-secret)
N8N_SSO_OIDC_DISCOVERY_ENDPOINT: "https://auth.furchert.ch/.well-known/openid-configuration"
```

### Environment Variables
```yaml
# Encryption (required for workflow credential stability)
N8N_ENCRYPTION_KEY: from n8n-secrets

# Webhook configuration (critical for Cloudflare Tunnel)
N8N_HOST: "n8n.furchert.ch"
N8N_PROTOCOL: "https"
N8N_WEBHOOK_URL: "https://n8n.furchert.ch/"

# Disable basic auth (using OIDC instead)
N8N_BASIC_AUTH_ACTIVE: "false"
```

### Probes
```yaml
livenessProbe:
  httpGet: /healthz:5678
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet: /healthz:5678
  initialDelaySeconds: 5
  periodSeconds: 10

startupProbe:
  httpGet: /healthz:5678
  initialDelaySeconds: 10
  failureThreshold: 15
```

### Persistence
```yaml
volumeMounts:
  - name: n8n-data
    mountPath: /home/node/.n8n
volumes:
  - name: n8n-data
    persistentVolumeClaim:
      claimName: n8n-data
```

## Required Setup in auth-service

### 1. Register n8n as an OIDC Client

The auth-service needs to be configured to allow n8n as an OIDC client.

**Required callback URL:** `https://n8n.furchert.ch/rest/sso/oidc/callback`

### 2. Add Client Secret

Add the client secret and encryption key to `infra/inventory/group_vars/all.sops.yml`:
```yaml
auth_service_n8n_client_secret: "<choose_a_random_secret>"
n8n_encryption_key: "<openssl rand -hex 32>"
```

The playbook `52_app_services.yml` will automatically:
1. Write `n8n-client-secret-authservice` as `{noop}<secret>` for auth-service
2. Write `n8n-client-secret` as raw `<secret>` for n8n
3. Create/update `n8n-secrets` with `n8n_encryption_key`

## Deployment Steps

### 1. Add SOPS variables

Add the n8n client secret to SOPS:
```bash
# Edit encrypted SOPS file
sops infra/inventory/group_vars/all.sops.yml

# Add variables
auth_service_n8n_client_secret: "<your_random_secret>"
n8n_encryption_key: "<openssl_rand_hex_32>"
```

### 2. Run app services playbook

This creates the necessary secrets:
```bash
ansible-playbook infra/playbooks/52_app_services.yml
```

### 3. Update Cloudflare Tunnel
```bash
ansible-playbook infra/playbooks/40_platform.yml
```

### 4. Add DNS Record
- Cloudflare Dashboard → DNS → Add CNAME
  - Name: `n8n`
  - Target: `<tunnel-id>.cfargotunnel.com`
  - Proxy: enabled

### 5. Configure OIDC client in auth-service

The auth-service configuration needs to include n8n as a registered OIDC client.

Check the auth-service configuration file for the OIDC clients section and add:
```yaml
n8n:
  client-id: n8n
  client-secret: "{noop}<your_secret>"  # Will be replaced from homelab-auth-secrets
  redirect-uris: https://n8n.furchert.ch/rest/sso/oidc/callback
  scopes: openid,profile,email
  grant-types: authorization_code
```

### 6. Verify Deployment
```bash
# Check resources
kubectl get pods -n apps | grep n8n
kubectl get svc -n apps | grep n8n
kubectl get pvc -n apps | grep n8n

# Check probes
kubectl describe pod -n apps $(kubectl get pod -n apps -l app=n8n -o jsonpath='{.items[0].metadata.name}') | grep -A5 "Probes"

# Test health endpoint
kubectl exec -n apps $(kubectl get pod -n apps -l app=n8n -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:5678/healthz

# Test OIDC configuration endpoint
curl http://auth-service.apps.svc.cluster.local:8080/.well-known/openid-configuration

# Test access via Cloudflare Tunnel (should redirect to auth-service login)
curl -v https://n8n.furchert.ch/

# Test persistence by deleting pod and checking recreation
kubectl delete pod -n apps $(kubectl get pod -n apps -l app=n8n -o jsonpath='{.items[0].metadata.name}')
kubectl get pods -n apps | grep n8n  # Should show new pod
kubectl get pvc -n apps n8n-data  # Should still be Bound
```

## Security Notes

- ✅ No hardcoded credentials in manifests (placeholders only)
- ✅ OIDC authentication via existing auth-service
- ✅ Encryption key for workflow credential stability
- ✅ Pinned container image version (2.17.1)
- ✅ Resource limits configured
- ✅ Comprehensive health probes
- ✅ Persistent storage for workflows and data
- ✅ Explicit webhook URL configuration
- ✅ Cookie security settings (secure, http-only, same-site=lax)

## Post-Deployment Recommendations

1. **Test OIDC login**: Verify users can login via auth-service
2. **Test webhooks**: Verify webhook functionality works correctly
3. **Monitor resources**: Adjust CPU/memory limits as needed
4. **Backup PVC**: Consider regular backups of the n8n-data PVC
5. **Monitor logs**: Check for any startup warnings or errors
6. **Register users**: Ensure required users exist in auth-service

## Troubleshooting

### Common Issues

**Authentication redirect loop:**
- Verify OIDC client is registered in auth-service
- Check callback URL matches exactly: `https://n8n.furchert.ch/rest/sso/oidc/callback`
- Verify client secret matches between auth-service and n8n

**Webhooks not working:**
- Verify `N8N_WEBHOOK_URL` is set correctly
- Check Cloudflare Tunnel configuration
- Test with `curl -v https://n8n.furchert.ch/`

**Encryption errors:**
- Verify encryption key is set and doesn't change on redeploy
- Check n8n can read/write encrypted credentials

**Probe failures:**
- Check n8n logs: `kubectl logs -n apps <pod>`
- Test health endpoint manually: `kubectl exec -n apps <pod> -- curl http://localhost:5678/healthz`

**PVC not bound:**
- Verify Longhorn is running: `kubectl get pods -n longhorn-system`
- Check storage class: `kubectl get storageclass`

## Ingress Route Answer

**Yes, the ingress route was added** to the Cloudflare Tunnel configuration in `infra/playbooks/40_platform.yml`:
```yaml
- hostname: "n8n.furchert.ch"
  service: "http://n8n.apps.svc.cluster.local:80"
```

This routes public traffic from `https://n8n.furchert.ch` through Cloudflare Tunnel to the n8n service in the apps namespace, with TLS terminated at the Cloudflare edge.

## Dependencies
- Existing Cloudflare Tunnel infrastructure
- FluxCD GitOps setup
- Longhorn storage class for PVC (default)
- homelab-auth-service running in apps namespace
- `apps` namespace must exist
- Kubernetes 1.20+ for startup probes
