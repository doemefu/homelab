---
paths:
  - "**/*.md"
---

# Documentation Files — Purpose & Owner

When making changes, update the relevant file(s) — the `doc-auditor` subagent (Phase 6) identifies what needs updating. Docs are written in parallel with the code change, not after.

| File              | Audience      | Covers |
|-------------------|---------------|--------|
| `README.md`       | Everyone      | Overview, architecture, quick start, repository layout |
| `CONTRIBUTING.md` | Contributors  | Local development setup, Ansible testing, PR process, code style |
| `APP-DEPLOYMENT.md` | App developers | App-deployment guide: namespace conventions, ingress patterns, secrets, Flux wiring |
| `DEPLOYMENT.md`   | App developers | Cluster deployment guide: runbooks, upgrade process, monitoring, backup/restore, troubleshooting |
| `INTERFACES.md`   | Integrators   | How callers interact with cluster-exposed services |
| `docs/`           | Everyone      | Architecture specs, design notes, ADRs |

**Rule:** every milestone must end with all relevant docs updated; runbooks are deliverables, not afterthoughts.
