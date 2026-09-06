package kubernetes.images

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

# Regression fixture for the real repo:tag@sha256:<64-hex> shape used in production
# (#57 digest-pinned platform images) — not just the shortened "abcdef" placeholder above.
test_allow_real_tag_and_digest_shape {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "litellm", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {
                "name": "litellm",
                "image": "docker.litellm.ai/berriai/litellm-non_root:v1.98.0@sha256:157aaf0a519713663ec6abefe73fa48bf12f638b0e63fb2b209ba0eae68e6bd7",
            },
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

# Regression: a registry with a port number contains `:`, but the tag
# (if any) lives in the *last* path segment. Naive `contains(image, ":")`
# treated this image as explicitly tagged and let it through.
test_deny_registry_port_implicit_latest {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "registry.example.com:5000/repo/image"},
        ]}}},
    }
    count(result) == 1
}

test_allow_registry_port_with_pinned_tag {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "registry.example.com:5000/repo/image:1.0"},
        ]}}},
    }
    count(result) == 0
}

test_allow_registry_port_with_digest {
    result := deny with input as {
        "kind": "Deployment",
        "metadata": {"name": "x", "namespace": "apps"},
        "spec": {"template": {"spec": {"containers": [
            {"name": "c", "image": "registry.example.com:5000/repo/image@sha256:abcdef"},
        ]}}},
    }
    count(result) == 0
}
