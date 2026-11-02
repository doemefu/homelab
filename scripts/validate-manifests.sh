#!/usr/bin/env bash
# Validate the rendered Kubernetes manifests with kubeconform against the live Kubernetes
# version (blocking) and the next two minor versions (report-only).
#
# Live version:  k3s_version in infra/roles/k3s/defaults/main.yml ("vX.Y.Z+k3sN" -> X.Y.Z), so a
#                k3s bump moves the gate with it.
# Next versions: X.(Y+1).0 and X.(Y+2).0. Kubernetes removes APIs at minor boundaries, so the .0
#                schema set of each minor is enough. Override: KUBERNETES_NEXT_VERSIONS="1.33.13 1.34.12".
# Missing schemas: a kind from a CRD without a schema in the datreeio catalog is skipped, as before.
#                A built-in kind (core group or a *.k8s.io group) without a schema for a version
#                means its apiVersion does not exist in that version (a removed API), so it counts
#                as a failure. So does a directory in which no resource validated at all.
#
# Usage: scripts/validate-manifests.sh [DIR ...]   (default: the directory list below)
# Env:   KUBECONFORM, KUSTOMIZE (binaries, default from PATH; .github/workflows/ci.yml pins both),
#        KUBECONFORM_CACHE (schema cache directory), K3S_DEFAULTS (file holding k3s_version).
# Needs: kustomize, kubeconform, jq, curl.
# Exit:  0 = valid on the live version (next-version findings are warnings only),
#        1 = invalid on the live version or a kustomize build failed, 2 = setup error.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
kubeconform="${KUBECONFORM:-kubeconform}"
kustomize="${KUSTOMIZE:-kustomize}"
k3s_defaults="${K3S_DEFAULTS:-${repo_root}/infra/roles/k3s/defaults/main.yml}"
schema_base="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master"
crd_catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

die() {
  echo "::error::$*"
  exit 2
}

if [ "$#" -gt 0 ]; then
  dirs=("$@")
else
  # Keep in sync with the conftest loop in .github/workflows/ci.yml.
  dirs=()
  for d in cluster/apps/auth-service \
           cluster/apps/device-service \
           cluster/apps/data-service \
           cluster/apps/mcp-hub \
           cluster/apps/litellm \
           cluster/apps/n8n \
           cluster/apps/open-webui \
           cluster/monitoring/coroot-node-agent \
           cluster/apps; do
    dirs+=("${repo_root}/${d}")
  done
fi

for tool in "${kubeconform}" "${kustomize}" jq curl; do
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found"
done

matches="$(grep -cE '^k3s_version:' "${k3s_defaults}" || true)"
[ "${matches}" = 1 ] || die "expected exactly one k3s_version line in ${k3s_defaults}, found ${matches:-none}"
live="$(sed -nE 's/^k3s_version:[[:space:]]*"?v([0-9]+\.[0-9]+\.[0-9]+)\+k3s[0-9]+"?[[:space:]]*(#.*)?$/\1/p' "${k3s_defaults}")"
[ -n "${live}" ] || die "k3s_version in ${k3s_defaults} is not of the form vX.Y.Z+k3sN"

if [ -n "${KUBERNETES_NEXT_VERSIONS:-}" ]; then
  next_versions="${KUBERNETES_NEXT_VERSIONS}"
else
  major="${live%%.*}"
  minor="${live#*.}"
  minor="${minor%%.*}"
  next_versions="${major}.$((minor + 1)).0 ${major}.$((minor + 2)).0"
fi
read -r -a next <<< "${next_versions}"
[ "${#next[@]}" -gt 0 ] || die "KUBERNETES_NEXT_VERSIONS is empty"
for v in "${next[@]}"; do
  [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '${v}' in KUBERNETES_NEXT_VERSIONS (want X.Y.Z)"
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cache="${KUBECONFORM_CACHE:-${work}/cache}"
mkdir -p "${cache}"

# A published schema set always contains the core ConfigMap schema.
schema_published() {
  curl -fsSI -o /dev/null --retry 3 "${schema_base}/v$1-standalone-strict/configmap-v1.json"
}

# Prints one line per problem of rendered file $1 on Kubernetes version $2 (nothing when valid).
validate() {
  local rc=0 problems
  "${kubeconform}" -strict -ignore-missing-schemas -output json -verbose -summary \
    -kubernetes-version "$2" -cache "${cache}" \
    -schema-location default -schema-location "${crd_catalog}" \
    "$1" > "${work}/result.json" || rc=$?
  jq -r '"\(.summary.valid // 0) valid, \(.summary.skipped // 0) skipped: no schema"' \
    "${work}/result.json" > "${work}/counts" 2>/dev/null || echo "no counts" > "${work}/counts"
  if ! problems="$(jq -r '
      def builtin: (.version | contains("/") | not)
        or (.version | split("/")[0] | (contains(".") | not) or endswith(".k8s.io"));
      [ .resources[]
        | select(.status == "statusInvalid" or .status == "statusError"
                 or (.status == "statusSkipped" and builtin))
        | "  \(.kind)/\(.name) (\(.version)): "
          + (if .status == "statusSkipped" then "apiVersion not served (no schema)"
             else (.msg | gsub("\n"; " ")) end) ] as $problems
      | if ($problems | length) > 0 then $problems[]
        elif (.summary.valid // 0) == 0 then "  no resource validated (empty render or no schemas)"
        else empty end
    ' "${work}/result.json")"; then
    problems="  kubeconform produced no readable result (exit ${rc})"
  fi
  if [ -z "${problems}" ] && [ "${rc}" -ne 0 ]; then
    problems="  kubeconform exited ${rc} without listing a problem"
  fi
  if [ -n "${problems}" ]; then
    printf '%s\n' "${problems}"
  fi
}

count_lines() {
  printf '%s\n' "$1" | wc -l | tr -d ' '
}

echo "Kubernetes ${live}: live version (k3s_version), blocking"
echo "Kubernetes ${next[*]}: next minor versions, report-only"
{
  echo "### kubeconform"
  echo
  echo "| Kubernetes | Mode | Directory | Result |"
  echo "|---|---|---|---|"
} >> "${summary}"

schema_published "${live}" || die "no schemas published for Kubernetes ${live} (${schema_base}/v${live}-standalone-strict)"
checked_next=()
for v in "${next[@]}"; do
  if schema_published "${v}"; then
    checked_next+=("${v}")
  else
    echo "::warning::no kubeconform schemas published for Kubernetes ${v}; next-version check skipped"
    echo "| ${v} | report-only | (all) | no schemas published, skipped |" >> "${summary}"
  fi
done

status=0
i=0
for d in "${dirs[@]}"; do
  i=$((i + 1))
  name="${d#"${repo_root}/"}"
  rendered="${work}/${i}.yaml"
  echo "::group::kubeconform ${name}"
  if ! "${kustomize}" build "${d}" > "${rendered}"; then
    echo "::endgroup::"
    echo "::error::kustomize build failed for ${name}"
    echo "| ${live} | blocking | ${name} | kustomize build failed |" >> "${summary}"
    status=1
    continue
  fi

  problems="$(validate "${rendered}" "${live}")"
  if [ -n "${problems}" ]; then
    echo "Kubernetes ${live} (blocking):"
    printf '%s\n' "${problems}"
    live_result="invalid: $(count_lines "${problems}") problem(s)"
    status=1
  else
    echo "Kubernetes ${live} (blocking): valid ($(cat "${work}/counts"))"
    live_result="valid"
  fi
  echo "| ${live} | blocking | ${name} | ${live_result} |" >> "${summary}"

  next_annotations=()
  for v in ${checked_next[@]+"${checked_next[@]}"}; do
    problems="$(validate "${rendered}" "${v}")"
    if [ -n "${problems}" ]; then
      echo "Kubernetes ${v} (report-only):"
      printf '%s\n' "${problems}"
      next_annotations+=("${v}")
      echo "| ${v} | report-only | ${name} | invalid: $(count_lines "${problems}") problem(s) |" >> "${summary}"
    else
      echo "Kubernetes ${v} (report-only): valid ($(cat "${work}/counts"))"
      echo "| ${v} | report-only | ${name} | valid |" >> "${summary}"
    fi
  done
  echo "::endgroup::"

  if [ "${live_result}" != "valid" ]; then
    echo "::error::${name} is not valid on Kubernetes ${live} (see the kubeconform ${name} log group)"
  fi
  for v in ${next_annotations[@]+"${next_annotations[@]}"}; do
    echo "::warning::${name} would not be valid on Kubernetes ${v} (report-only; see the kubeconform ${name} log group)"
  done
done

exit "${status}"
