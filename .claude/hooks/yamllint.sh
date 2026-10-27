#!/usr/bin/env bash
# PostToolUse (Edit|Write): lint only the edited YAML file. Warns, never blocks (always exit 0).
# Warnings go to Claude as additionalContext JSON on stdout.
f=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
case "$f" in *.yml|*.yaml) ;; *) exit 0 ;; esac
[ -f "$f" ] || exit 0
# Resolve the root from the edited file's own checkout: in a worktree CLAUDE_PROJECT_DIR may point at the main checkout.
root=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null) || exit 0
rel="${f#"$root"/}"
[ "$rel" = "$f" ] && exit 0
# Only lint files of this project (main checkout or one of its worktrees), never a foreign repo.
proj_common=$(git -C "${CLAUDE_PROJECT_DIR:-/nonexistent}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
file_common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[ "$proj_common" = "$file_common" ] || exit 0
# Same scope as the `ignore:` list in .yamllint; skipped relative to the checkout root (worktrees live under .claude/worktrees/).
case "$rel" in
  *.sops.yml|*.sops.yaml|.sops.yaml|infra/*|cluster/flux-system/*|.claude/*) exit 0 ;;
esac
cd "$root" || exit 0
[ -f .yamllint ] || exit 0
# Fallback runs yamllint's CLI with the CWD removed from sys.path, so a yamllint.py in the checkout is never imported.
# (python3 -I would also drop the user site-packages, where yamllint usually lives.)
pyprobe='import sys; sys.path[:] = [p for p in sys.path if p not in ("", ".")]; from yamllint.cli import run'
pylint="$pyprobe; run()"
if command -v yamllint >/dev/null 2>&1; then lint=(yamllint)
elif python3 -c "$pyprobe" >/dev/null 2>&1; then lint=(python3 -c "$pylint")
else exit 0; fi
out=$("${lint[@]}" -c .yamllint "$rel" 2>&1)
[ -n "$out" ] && jq -n --arg t "yamllint warnings for $rel:
$out" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$t}}'
exit 0
