# Cluster policies (Conftest / OPA)

These Rego policies encode the non-negotiables from `CLAUDE.md` and are
enforced in CI by the **Enforce Cluster Policies** job in
`.github/workflows/ci.yml`.

## Policies

| File | Package | What it enforces |
|---|---|---|
| `deny-latest-image.rego` | `kubernetes.images` | No container image may resolve to `:latest` (explicit or implicit). Digest pins (`@sha256:…`) are allowed. Flux `ImageRepository.spec.image` is intentionally not inspected. |
| `require-resource-limits.rego` | `kubernetes.resources` | Every container (incl. `initContainers`) in `Deployment` / `StatefulSet` / `DaemonSet` workloads **in namespace `apps`** must declare both `resources.requests` and `resources.limits`. |
| `namespace-allowlist.rego` | `kubernetes.namespaces` | Namespaced objects must live in one of: `platform`, `monitoring`, `apps`, `longhorn-system`, `kube-system`, `flux-system`, `default`. Cluster-scoped kinds (CRDs, ClusterRoles, …) are skipped. |
| `deny-app-cluster-admin.rego` | `kubernetes.rbac` | `ClusterRoleBinding` / `RoleBinding` to `cluster-admin` is forbidden when any subject is in namespace `apps`. Flux controllers in `flux-system` are unaffected. |

Each policy has a sibling `*_test.rego` with unit tests (`conftest verify`).

## Package isolation

Each policy file declares its own Rego package (`kubernetes.<area>`). They
deliberately do **not** share `package main`: if every `deny` rule lived in
one namespace, conftest would merge them all into a single set and unit
tests would couple across files (e.g. a `deny-latest-image_test.rego`
fixture in `apps` would also trip `require-resource-limits`). Per-file
packages keep tests independent and make it obvious from `conftest verify`
output which policy a finding came from.

CI runs `conftest test --all-namespaces`, which evaluates every package
under `policy/kubernetes/`. (`conftest verify` walks every `*_test.rego`
on its own, so it does not take that flag.) Adding a new policy file in
its own package just works — no workflow edit needed.

## Running locally

Install conftest (`brew install conftest` / `go install github.com/open-policy-agent/conftest@latest`).

```bash
# Unit-test the policies themselves.
conftest verify --policy policy/kubernetes/

# Lint each per-app overlay against the policies.
for d in cluster/apps/auth-service cluster/apps/device-service \
         cluster/apps/litellm cluster/apps/n8n cluster/apps; do
  echo ">>> $d"
  kustomize build "$d" | conftest test --policy policy/kubernetes/ --all-namespaces -
done
```

## Adding a policy

1. Create `policy/kubernetes/<name>.rego` with `package kubernetes.<area>` (pick a fresh `<area>`; do not reuse an existing one) and one or more `deny[msg]` rules.
2. Create `policy/kubernetes/<name>_test.rego` in the **same package** with `test_*` cases for at least one denied and one allowed input.
3. Run `conftest verify --policy policy/kubernetes/` locally.
4. Update this README's policy table and the CI scope if your policy needs to look at additional manifests.
