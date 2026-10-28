package kubernetes.securitycontext

hardened_container := {
    "name": "c",
    "image": "nginx:1",
    "securityContext": {
        "runAsNonRoot": true,
        "allowPrivilegeEscalation": false,
        "readOnlyRootFilesystem": true,
        "capabilities": {"drop": ["ALL"]},
        "seccompProfile": {"type": "RuntimeDefault"},
    },
}

test_allow_fully_hardened_container {
    result := warn with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [hardened_container]}}},
    }
    count(result) == 0
}

test_warn_bare_container_on_every_check {
    result := warn with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [{"name": "c", "image": "nginx:1"}]}}},
    }
    count(result) == 5
}

test_pod_level_non_root_and_seccomp_are_inherited {
    # runAsNonRoot and seccompProfile set on the pod only: the three
    # container-only fields still warn, the two inherited ones do not.
    result := warn with input as {
        "kind": "StatefulSet",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {
            "securityContext": {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{"name": "c", "image": "nginx:1"}],
        }}},
    }
    count(result) == 3
}

test_container_overrides_pod_non_root {
    result := warn with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {
            "securityContext": {"runAsNonRoot": true},
            "containers": [object.union(hardened_container, {"securityContext": object.union(
                hardened_container.securityContext, {"runAsNonRoot": false},
            )})],
        }}},
    }
    count(result) == 1
}

test_container_unconfined_seccomp_overrides_pod {
    result := warn with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {
            "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [object.union(hardened_container, {"securityContext": object.union(
                hardened_container.securityContext, {"seccompProfile": {"type": "Unconfined"}},
            )})],
        }}},
    }
    count(result) == 1
}

test_localhost_seccomp_is_accepted {
    result := warn with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [object.union(hardened_container, {"securityContext": object.union(
            hardened_container.securityContext,
            {"seccompProfile": {"type": "Localhost", "localhostProfile": "p.json"}},
        )})]}}},
    }
    count(result) == 0
}

test_capabilities_must_drop_all {
    result := warn with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [object.union(hardened_container, {"securityContext": object.union(
            hardened_container.securityContext, {"capabilities": {"drop": ["NET_RAW"]}},
        )})]}}},
    }
    count(result) == 1
}

test_init_containers_are_checked {
    result := warn with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {
            "containers": [hardened_container],
            "initContainers": [{"name": "init", "image": "busybox:1"}],
        }}},
    }
    count(result) == 5
}

test_other_namespace_is_not_checked {
    # Privileged platform workloads (e.g. coroot-node-agent in monitoring) are out of scope.
    result := warn with input as {
        "kind": "DaemonSet",
        "metadata": {"name": "coroot-node-agent", "namespace": "monitoring"},
        "spec": {"template": {"spec": {"containers": [{"name": "c", "image": "x:1"}]}}},
    }
    count(result) == 0
}

test_policy_never_denies {
    # Warn-only until the app manifests are hardened: the package has no deny rules.
    result := [d | d := data.kubernetes.securitycontext.deny[_]] with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [{"name": "c", "image": "nginx:1"}]}}},
    }
    count(result) == 0
}
