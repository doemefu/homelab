package kubernetes.securitycontext

# Warn (do NOT deny, yet) when a container in the `apps` namespace is not
# hardened to the Pod Security Standards "restricted" baseline:
#   - runAsNonRoot: true                    (container, or inherited from the pod)
#   - allowPrivilegeEscalation: false       (container)
#   - readOnlyRootFilesystem: true          (container)
#   - capabilities.drop contains "ALL"      (container)
#   - seccompProfile.type RuntimeDefault    (container, or inherited from the pod;
#                                            Localhost is accepted as well)
#
# Why warn: not every app manifest is hardened yet (device-service#85,
# data-service#46, auth-service#126 pending). `conftest test` exits 0 on
# warnings unless --fail-on-warn is passed, and neither CI nor the service
# repos' local commands pass it. Switching these rules to deny is a
# follow-up of homelab#243 once those PRs are merged.
#
# Scope mirrors require-resource-limits.rego: Deployment / StatefulSet /
# DaemonSet in `apps`, containers and initContainers.

apps_workload_kinds := {"Deployment", "StatefulSet", "DaemonSet"}

allowed_seccomp_types := {"RuntimeDefault", "Localhost"}

is_apps_workload {
    apps_workload_kinds[input.kind]
    input.metadata.namespace == "apps"
}

pod_spec := input.spec.template.spec

apps_containers[c] {
    is_apps_workload
    c := pod_spec.containers[_]
}

apps_containers[c] {
    is_apps_workload
    c := pod_spec.initContainers[_]
}

# A container-level value overrides the pod-level one (Kubernetes semantics).
runs_as_non_root(c) {
    pod_default := object.get(pod_spec, ["securityContext", "runAsNonRoot"], false)
    object.get(c, ["securityContext", "runAsNonRoot"], pod_default) == true
}

privilege_escalation_disabled(c) {
    c.securityContext.allowPrivilegeEscalation == false
}

read_only_root(c) {
    c.securityContext.readOnlyRootFilesystem == true
}

drops_all_capabilities(c) {
    c.securityContext.capabilities.drop[_] == "ALL"
}

seccomp_confined(c) {
    pod_type := object.get(pod_spec, ["securityContext", "seccompProfile", "type"], "")
    allowed_seccomp_types[object.get(c, ["securityContext", "seccompProfile", "type"], pod_type)]
}

warn[msg] {
    c := apps_containers[_]
    not runs_as_non_root(c)
    msg := sprintf(
        "%s/%s in apps: container %q should set securityContext.runAsNonRoot: true (container or pod)",
        [input.kind, input.metadata.name, c.name],
    )
}

warn[msg] {
    c := apps_containers[_]
    not privilege_escalation_disabled(c)
    msg := sprintf(
        "%s/%s in apps: container %q should set securityContext.allowPrivilegeEscalation: false",
        [input.kind, input.metadata.name, c.name],
    )
}

warn[msg] {
    c := apps_containers[_]
    not read_only_root(c)
    msg := sprintf(
        "%s/%s in apps: container %q should set securityContext.readOnlyRootFilesystem: true",
        [input.kind, input.metadata.name, c.name],
    )
}

warn[msg] {
    c := apps_containers[_]
    not drops_all_capabilities(c)
    msg := sprintf(
        "%s/%s in apps: container %q should drop all capabilities (securityContext.capabilities.drop: [\"ALL\"])",
        [input.kind, input.metadata.name, c.name],
    )
}

warn[msg] {
    c := apps_containers[_]
    not seccomp_confined(c)
    msg := sprintf(
        "%s/%s in apps: container %q should use seccompProfile.type RuntimeDefault (container or pod)",
        [input.kind, input.metadata.name, c.name],
    )
}
