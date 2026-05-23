package main

# Require every container in the `apps` namespace to declare both
# resources.requests and resources.limits.
#
# Why: CLAUDE.md §5 — "Resource limits required for all workloads in `apps`
# namespace." Flux controllers (flux-system) and platform/monitoring workloads
# are intentionally not enforced here.

apps_workload_kinds := {"Deployment", "StatefulSet", "DaemonSet"}

is_apps_workload {
    apps_workload_kinds[input.kind]
    input.metadata.namespace == "apps"
}

apps_containers[c] {
    is_apps_workload
    c := input.spec.template.spec.containers[_]
}

apps_containers[c] {
    is_apps_workload
    c := input.spec.template.spec.initContainers[_]
}

deny[msg] {
    c := apps_containers[_]
    not c.resources.requests
    msg := sprintf(
        "%s/%s in apps: container %q is missing resources.requests",
        [input.kind, input.metadata.name, c.name],
    )
}

deny[msg] {
    c := apps_containers[_]
    not c.resources.limits
    msg := sprintf(
        "%s/%s in apps: container %q is missing resources.limits",
        [input.kind, input.metadata.name, c.name],
    )
}
