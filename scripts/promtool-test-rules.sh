#!/usr/bin/env bash
# Check and unit-test the custom Prometheus rules in cluster/values/kube-prometheus-stack.yaml.
#
# Extracts every group under additionalPrometheusRulesMap.*.groups into one temporary rules
# file, runs `promtool check rules` on it, then `promtool test rules` for every
# cluster/values/tests/*.test.yml (each test file names `rules.yaml` in rule_files).
#
# Usage:  scripts/promtool-test-rules.sh
#         PROMTOOL=/path/to/promtool scripts/promtool-test-rules.sh
# Needs:  promtool (from a pinned Prometheus release) and python3 with PyYAML
#         (pyyaml==6.0.3, the same pin as .github/workflows/helm-chart-freshness.yml).

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
values="${repo_root}/cluster/values/kube-prometheus-stack.yaml"
tests_dir="${repo_root}/cluster/values/tests"
promtool="${PROMTOOL:-promtool}"

if ! command -v "${promtool}" >/dev/null 2>&1; then
  echo "promtool not found (set PROMTOOL=/path/to/promtool)" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

python3 - "${values}" "${work}/rules.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as f:
    values = yaml.safe_load(f)
groups = []
for key, entry in (values.get("additionalPrometheusRulesMap") or {}).items():
    groups.extend(entry.get("groups", []))
if not groups:
    sys.exit("no additionalPrometheusRulesMap groups found")
with open(sys.argv[2], "w") as f:
    yaml.safe_dump({"groups": groups}, f, sort_keys=False)
PY

"${promtool}" check rules "${work}/rules.yaml"

status=0
for t in "${tests_dir}"/*.test.yml; do
  cp "${t}" "${work}/"
  echo "== ${t#"${repo_root}/"}"
  "${promtool}" test rules "${work}/$(basename "${t}")" || status=1
done
exit "${status}"
