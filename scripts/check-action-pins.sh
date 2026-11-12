#!/usr/bin/env bash
# Allowlist gate for GitHub Actions `uses:` refs (homelab-device-service#126).
#
# Every `uses:` line under the given directory (default: .github/workflows)
# must have one of these shapes:
#   - ./local/path                          (an action in this repo)
#   - owner/repo[/path]@<40-hex commit SHA>  (optionally followed by a `# vX.Y.Z` comment)
#   - docker://image@sha256:<64-hex digest>
#
# This is an allowlist on purpose: a denylist that looks for `@v1`-style refs
# misses bare tags (`@2.0.0`), branches (`@main`, `@stable`), short SHAs and
# docker tags. Commented-out lines are not matched.
#
# GitHub's per-repo setting `sha_pinning_required` is the control enforced at
# run time; this script gives fast feedback on pull requests.
#
# Usage: scripts/check-action-pins.sh [directory]
set -euo pipefail

dir="${1:-.github/workflows}"

if [ ! -d "$dir" ]; then
  echo "No such directory: $dir" >&2
  exit 2
fi

bad=$(grep -rnE '^[[:space:]]*-?[[:space:]]*\{?[[:space:]]*uses:' "$dir" \
  | grep -vE "uses:[[:space:]]+[\"']?(\./[^ \"']*|[^ @\"']+@[0-9a-f]{40}|docker://[^ \"']+@sha256:[0-9a-f]{64})[\"']?\}?([[:space:]]+#.*)?$" \
  || true)

if [ -n "$bad" ]; then
  echo "$bad"
  echo "Unpinned uses: ref(s) found. Allowed: ./local/path, owner/repo@<40-hex commit SHA>, docker://image@sha256:<64-hex digest>." >&2
  exit 1
fi

echo "All uses: refs in $dir are pinned."
