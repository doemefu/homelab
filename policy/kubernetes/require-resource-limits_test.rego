package kubernetes.resources

test_deny_missing_limits_in_apps {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "nginx:1", "resources": {"requests": {"cpu": "100m"}}},
        ]}}},
    }
    count(result) == 1
}

test_deny_missing_both_in_apps {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "nginx:1"},
        ]}}},
    }
    count(result) == 2
}

test_allow_both_set_in_apps {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [{
            "name": "c",
            "image": "nginx:1",
            "resources": {
                "requests": {"cpu": "100m", "memory": "128Mi"},
                "limits": {"cpu": "500m", "memory": "512Mi"},
            },
        }]}}},
    }
    count(result) == 0
}

test_other_namespace_is_not_enforced {
    # Flux Deployments in flux-system are out of scope for this policy.
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "kustomize-controller", "namespace": "flux-system"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "ghcr.io/fluxcd/kustomize-controller:v1"},
        ]}}},
    }
    count(result) == 0
}

test_init_container_limits_required {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {
            "containers": [{
                "name": "c", "image": "nginx:1",
                "resources": {"requests": {"cpu": "100m"}, "limits": {"cpu": "500m"}},
            }],
            "initContainers": [{"name": "init", "image": "busybox:1"}],
        }}},
    }
    count(result) == 2
}
