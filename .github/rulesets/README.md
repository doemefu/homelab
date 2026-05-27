# Branch rulesets

`main-branch.json` is the importable form of the branch-protection ruleset for `main`
(GitHub-side id `15078308`, name `main`). Committing it keeps protection reproducible
and reviewable in git.

## What it enforces

| Rule | Effect |
|---|---|
| `deletion` | `main` cannot be deleted. |
| `non_fast_forward` | No force-push to `main`. |
| `copilot_code_review` | GitHub Copilot auto-reviews PRs (`review_on_push: true`, drafts excluded). |
| `code_scanning` | CodeQL alerts must be below `medium_or_higher` (security) / `errors` (all). |
| `code_quality` | Code-quality findings of severity `errors` block merge. |
| `pull_request` | PR required with ≥1 approving review; stale reviews dismissed on push. |
| `required_status_checks` | `CI Summary` and `CodeQL` must be green on a branch up-to-date with `main`. |

## Required status checks — name contract

Renaming any of these check names breaks the ruleset silently. GitHub matches the
**job display name** (the `name:` field on the job), not the job id.

| Check (display name) | Workflow file                | Job id   |
|---|---|---|
| CI Summary           | `.github/workflows/ci.yml`     | `ci-summary` |
| CodeQL               | `.github/workflows/codeql.yml` | `analyze`    |

## Apply / update via the GitHub API

```bash
# Update the active ruleset in place (id 15078308) — this is the usual case
gh api -X PUT repos/doemefu/homelab/rulesets/15078308 \
  --input .github/rulesets/main-branch.json

# List rulesets (note the id for updates)
gh api repos/doemefu/homelab/rulesets

# Inspect one
gh api repos/doemefu/homelab/rulesets/15078308

# First-time install (only if no ruleset exists yet)
gh api -X POST repos/doemefu/homelab/rulesets \
  --input .github/rulesets/main-branch.json
```

**Before you PUT-update**, compare the live ruleset (`gh api repos/.../rulesets/<id>`)
against this JSON — `copilot_code_review`, `code_scanning`, and `code_quality` rules
must be present in the JSON, or PUT will silently delete them. There is no classic
UI-administered branch protection on `main`; the ruleset is the only enforcement layer.
