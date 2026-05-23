package main

test_deny_explicit_latest {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "nginx:latest"},
        ]}}},
    }
    count(result) == 1
}

test_deny_implicit_latest_no_tag {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "nginx"},
        ]}}},
    }
    count(result) == 1
}

test_allow_pinned_tag {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "nginx:1.27.0"},
        ]}}},
    }
    count(result) == 0
}

test_allow_digest_pin {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "nginx@sha256:abcdef"},
        ]}}},
    }
    count(result) == 0
}

test_init_container_latest_denied {
    result := deny with input as {
        "kind": "StatefulSet",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {
            "containers": [{"name": "c", "image": "nginx:1.27.0"}],
            "initContainers": [{"name": "init", "image": "busybox:latest"}],
        }}},
    }
    count(result) == 1
}

test_imagerepository_is_ignored {
    # Flux ImageRepository.spec.image has no tag by design — must not match.
    result := deny with input as {
        "kind": "ImageRepository",
        "metadata": {"name": "auth-service", "namespace": "flux-system"},
        "spec": {"image": "ghcr.io/doemefu/homelab-auth-service"},
    }
    count(result) == 0
}

test_cronjob_latest_denied {
    result := deny with input as {
        "kind": "CronJob",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"jobTemplate": {"spec": {"template": {"spec": {
            "containers": [{"name": "c", "image": "alpine:latest"}],
        }}}}},
    }
    count(result) == 1
}
