package kubernetes.rbac

test_deny_crb_apps_sa_cluster_admin {
    result := deny with input as {
        "kind": "ClusterRoleBinding",
        "metadata": {"name": "evil"},
        "roleRef": {"kind": "ClusterRole", "name": "cluster-admin"},
        "subjects": [{"kind": "ServiceAccount", "name": "myapp", "namespace": "apps"}],
    }
    count(result) == 1
}

test_deny_rb_apps_user_cluster_admin {
    result := deny with input as {
        "kind": "RoleBinding",
        "metadata": {"name": "evil", "namespace": "apps"},
        "roleRef": {"kind": "ClusterRole", "name": "cluster-admin"},
        "subjects": [{"kind": "User", "name": "alice", "namespace": "apps"}],
    }
    count(result) == 1
}

test_deny_rb_apps_sa_implicit_namespace {
    # ServiceAccount subject with no explicit namespace implicitly belongs to
    # the RoleBinding's own namespace ('apps') and must still be denied.
    result := deny with input as {
        "kind": "RoleBinding",
        "metadata": {"name": "evil", "namespace": "apps"},
        "roleRef": {"kind": "ClusterRole", "name": "cluster-admin"},
        "subjects": [{"kind": "ServiceAccount", "name": "myapp"}],
    }
    count(result) == 1
}

test_allow_flux_controller_cluster_admin {
    # Flux controllers legitimately bind cluster-admin in flux-system.
    result := deny with input as {
        "kind": "ClusterRoleBinding",
        "metadata": {"name": "cluster-reconciler-flux-system"},
        "roleRef": {"kind": "ClusterRole", "name": "cluster-admin"},
        "subjects": [{"kind": "ServiceAccount", "name": "kustomize-controller", "namespace": "flux-system"}],
    }
    count(result) == 0
}

test_allow_non_cluster_admin_binding {
    result := deny with input as {
        "kind": "ClusterRoleBinding",
        "metadata": {"name": "view-only"},
        "roleRef": {"kind": "ClusterRole", "name": "view"},
        "subjects": [{"kind": "ServiceAccount", "name": "myapp", "namespace": "apps"}],
    }
    count(result) == 0
}
