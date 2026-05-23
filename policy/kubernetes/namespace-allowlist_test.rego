package main

test_allow_apps_namespace {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
    }
    count(result) == 0
}

test_allow_flux_system {
    result := deny with input as {
        "kind": "Kustomization",
        "metadata": {"name": "auth-service", "namespace": "flux-system"},
    }
    count(result) == 0
}

test_deny_unknown_namespace {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "secret-stuff"},
    }
    count(result) == 1
}

test_cluster_scoped_crd_skipped {
    # CRDs have no namespace; must not be flagged.
    result := deny with input as {
        "kind": "CustomResourceDefinition",
        "metadata": {"name": "gitrepositories.source.toolkit.fluxcd.io"},
    }
    count(result) == 0
}

test_namespace_object_skipped {
    # The Namespace object itself has no metadata.namespace.
    result := deny with input as {
        "kind": "Namespace",
        "metadata": {"name": "apps"},
    }
    count(result) == 0
}

test_cluster_role_binding_skipped {
    result := deny with input as {
        "kind": "ClusterRoleBinding",
        "metadata": {"name": "flux-anything"},
    }
    count(result) == 0
}
