package kubernetes.rbac

# Forbid granting cluster-admin to any subject in the `apps` namespace.
#
# Why: CLAUDE.md §5 — "No cluster-admin for app ServiceAccounts." Generalized
# here to cover any subject kind (ServiceAccount/User/Group) whose namespace
# is `apps`. Flux controllers in flux-system are unaffected.

binding_kinds := {"ClusterRoleBinding", "RoleBinding"}

deny[msg] {
    binding_kinds[input.kind]
    input.roleRef.name == "cluster-admin"
    s := input.subjects[_]
    s.namespace == "apps"
    msg := sprintf(
        "%s/%s grants cluster-admin to %s %q in namespace 'apps' — forbidden",
        [input.kind, input.metadata.name, s.kind, s.name],
    )
}

# A RoleBinding's ServiceAccount subject without an explicit `namespace` field
# implicitly belongs to the binding's own namespace. The rule above keys off
# `s.namespace`, so it would miss such a subject in an `apps` RoleBinding —
# catch it here.
deny[msg] {
    input.kind == "RoleBinding"
    input.metadata.namespace == "apps"
    input.roleRef.name == "cluster-admin"
    s := input.subjects[_]
    s.kind == "ServiceAccount"
    not s.namespace
    msg := sprintf(
        "%s/%s grants cluster-admin to ServiceAccount %q (implicit namespace 'apps') — forbidden",
        [input.kind, input.metadata.name, s.name],
    )
}
