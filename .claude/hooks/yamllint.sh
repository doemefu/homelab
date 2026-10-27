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
# Same scope as the `ignore:` list in .yamllint; skipped relative to the checkout root (worktrees live under .claude/worktrees/).
case "$rel" in
  *.sops.yml|*.sops.yaml|.sops.yaml|infra/*|cluster/flux-system/*|.claude/*) exit 0 ;;
esac
cd "$root" || exit 0
[ -f .yamllint ] || exit 0
if command -v yamllint >/dev/null 2>&1; then lint=(yamllint)
elif python3 -m yamllint --version >/dev/null 2>&1; then lint=(python3 -m yamllint)
else exit 0; fi
out=$("${lint[@]}" -c .yamllint "$rel" 2>&1)
[ -n "$out" ] && jq -n --arg t "yamllint warnings for $rel:
$out" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$t}}'
exit 0
