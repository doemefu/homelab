# Branch rulesets

`main-branch.json` is the importable form of the branch-protection ruleset for `main`.
Committing it keeps protection reproducible and reviewable in git.

## Required status checks — name contract

Renaming any of these check names breaks the ruleset silently. GitHub matches the
**job display name** (the `name:` field on the job), not the job id.

| Check (display name) | Workflow file                | Job id   |
|---|---|---|
| CI Summary           | `.github/workflows/ci.yml`   | `ci-summary` |
| CodeQL               | `.github/workflows/codeql.yml` | `analyze` |

## Apply / update via the GitHub API

```bash
# First-time install
gh api -X POST repos/doemefu/homelab/rulesets \
  --input .github/rulesets/main-branch.json

# List rulesets (note the id for updates)
gh api repos/doemefu/homelab/rulesets

# Update an existing one (replace 12345 with its id)
gh api -X PUT repos/doemefu/homelab/rulesets/12345 \
  --input .github/rulesets/main-branch.json

# Delete
gh api -X DELETE repos/doemefu/homelab/rulesets/12345
```

After applying via API, **remove any legacy UI-administered branch-protection
rule on `main`** — the ruleset supersedes it, and leaving both around makes
required-check requirements ambiguous.
