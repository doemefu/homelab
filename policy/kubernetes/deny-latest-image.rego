package kubernetes.images

# Forbid container images that resolve to :latest at runtime.
#
# Why: CLAUDE.md §0 — "Do not use `latest` for any Helm chart, container image,
# or k3s version. Always pin versions." This rule covers the container side.
#
# Scope: only kinds that carry a PodSpec. Crucially this means Flux
# `ImageRepository.spec.image` (which intentionally has no tag) is NOT matched.

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"}

# Containers in plain Pods.
all_containers[c] {
    input.kind == "Pod"
    c := input.spec.containers[_]
}
all_containers[c] {
    input.kind == "Pod"
    c := input.spec.initContainers[_]
}

# Containers inside the standard workload kinds.
all_containers[c] {
    workload_kinds[input.kind]
    c := input.spec.template.spec.containers[_]
}
all_containers[c] {
    workload_kinds[input.kind]
    c := input.spec.template.spec.initContainers[_]
}

# CronJob has an extra jobTemplate layer.
all_containers[c] {
    input.kind == "CronJob"
    c := input.spec.jobTemplate.spec.template.spec.containers[_]
}
all_containers[c] {
    input.kind == "CronJob"
    c := input.spec.jobTemplate.spec.template.spec.initContainers[_]
}

# The image-reference grammar (`[registry[:port]/]repo[/...]/name[:tag][@digest]`)
# means the only authoritative place to look for a tag is the *last* path
# segment. Checking for `:` anywhere in the string would let
# `registry:5000/repo/image` slip past as "explicitly tagged" when it's
# actually implicit `:latest`.
last_segment(image) := s {
    parts := split(image, "/")
    s := parts[count(parts) - 1]
}

# Explicit :latest in the last segment.
is_latest(image) {
    not contains(image, "@")
    endswith(last_segment(image), ":latest")
}

# Implicit :latest — last segment has no `:` (no tag), no digest.
is_latest(image) {
    not contains(image, "@")
    not contains(last_segment(image), ":")
}

deny[msg] {
    c := all_containers[_]
    is_latest(c.image)
    msg := sprintf(
        "%s/%s: container %q uses image %q (implicit or explicit :latest is forbidden)",
        [input.kind, input.metadata.name, c.name, c.image],
    )
}
