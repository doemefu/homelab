package main

# Allow namespaced objects only in known namespaces. Cluster-scoped kinds
# (which carry no namespace) are exempt by guard.
#
# Why: CLAUDE.md §6 — "Do not create new namespaces outside platform,
# monitoring, apps without discussion." This rule extends that to also accept
# the system namespaces this cluster legitimately uses.

allowed_namespaces := {
    "platform",
    "monitoring",
    "apps",
    "longhorn-system",
    "kube-system",
    "flux-system",
    "default",
}

# Kinds that are cluster-scoped (have no metadata.namespace) and must be
# skipped by this policy. List the well-known ones; anything else with an
# empty namespace falls into the same guard.
cluster_scoped_kinds := {
    "Namespace",
    "Node",
    "ClusterRole",
    "ClusterRoleBinding",
    "CustomResourceDefinition",
    "PersistentVolume",
    "StorageClass",
    "IngressClass",
    "PriorityClass",
    "APIService",
    "ValidatingWebhookConfiguration",
    "MutatingWebhookConfiguration",
    "RuntimeClass",
}

deny[msg] {
    not cluster_scoped_kinds[input.kind]
    ns := input.metadata.namespace
    ns != ""
    not allowed_namespaces[ns]
    msg := sprintf(
        "%s/%s lives in disallowed namespace %q (allowed: %v)",
        [input.kind, input.metadata.name, ns, allowed_namespaces],
    )
}
