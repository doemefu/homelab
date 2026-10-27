#!/usr/bin/env bash
# PostToolUse (Edit|Write): lint only the edited YAML file. Warns, never blocks (always exit 0).
# Warnings go to Claude as additionalContext JSON on stdout.
f=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
case "$f" in *.yml|*.yaml) ;; *) exit 0 ;; esac
# Same scope as the `ignore:` list in .yamllint; skipped before opening the file so secrets are never read.
# Match on the project-relative path: worktrees live under .claude/worktrees/, so absolute paths would all look ignored.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
rel="${f#"$root"/}"
case "$rel" in
  *.sops.yml|*.sops.yaml|.sops.yaml|infra/*|cluster/flux-system/*|.claude/*) exit 0 ;;
esac
[ -f "$f" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
if command -v yamllint >/dev/null 2>&1; then lint=(yamllint)
elif python3 -m yamllint --version >/dev/null 2>&1; then lint=(python3 -m yamllint)
else exit 0; fi
out=$("${lint[@]}" -c .yamllint "$rel" 2>&1)
[ -n "$out" ] && jq -n --arg t "yamllint warnings for $f:
$out" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$t}}'
exit 0
