# LiteLLM AI Gateway — Homelab

> Working doc covering brainstorm, PRD, ADR, system design, and GitHub issue drafts.
> Target repo: `doemefu/homelab`

---

## Part 1 — Brainstorm

### Frame

**What are we exploring?**
Running LiteLLM on the homelab k3s cluster as a shared, self-hosted AI gateway — one endpoint that all consumers (Claude Code, Java microservices, personal tools) call regardless of the underlying model. The README describes a working deployment pattern; this work formalises it into tracked, testable infrastructure.

**Why now?**
- Mistral API offers similar capability to Claude Haiku at significantly lower cost — ideal for subagent and background tasks in Claude Code/Cowork.
- The homelab microservices (auth, device, data) will eventually need AI capabilities. Without a central gateway, each service would manage its own API keys, model versions, and cost tracking independently.
- You already have the deployment pattern documented; the risk of doing nothing is drift — the README becomes stale and there is no single source of truth.

**What would a great outcome look like?**
One `ANTHROPIC_BASE_URL` override in Claude Code's settings points to LiteLLM. All subagent calls are routed through Mistral without any other config changes. The usage dashboard shows cost-per-model in real time. Auth-service validates tokens before any model call.

### Key Insights (diverge + provoke)

**Insight 1 — The real value is model-routing transparency, not just cost.**
Cost savings are the immediate win, but the deeper value is that your homelab services can call `/v1/chat/completions` without ever knowing if the model underneath is Mistral, Claude, or a local Ollama model. This is vendor lock-in insurance at the infrastructure level.

**Insight 2 — The auth problem is more interesting than the deployment problem.**
Deploying LiteLLM is mostly YAML. The hard question is: how should auth-service protect it? You have two distinct consumer types — human users (Claude Code / Cowork UI) and machine callers (Java services). These want different auth flows. A human wants OIDC-based login. A service wants a client_credentials JWT. LiteLLM supports virtual keys; the interesting question is whether those keys are issued by LiteLLM itself or by your auth-service.

**Insight 3 — Ollama placement matters architecturally even if deferred.**
Skipping Ollama now is right. But the decision of "which node" is not just a capacity question — it shapes how LiteLLM discovers and routes to it. If Ollama runs on the MacBook Air node with a `nodeSelector`, LiteLLM needs a stable internal DNS address for it. It is worth designing the routing config to have a placeholder now so adding Ollama later is a one-line change.

**Insight 4 — The usage dashboard is an underrated unlock.**
The LiteLLM UI at `/ui` shows cost per model and token usage over time. For a homelab with no budget tracking today, this becomes your first AI cost ledger. This alone justifies the deployment even before any cost savings materialise.

### Strongest Direction

**Deploy LiteLLM as the homelab's AI gateway in two phases:**
- **Phase 1** — Core infrastructure + Claude Code integration (immediate value, no auth-service dependency).
- **Phase 2** — Auth-service integration for OIDC-protected access (secures the gateway for service-to-service use).

Phase 1 can ship in a single sprint. Phase 2 follows as a story in auth-service.

### Riskiest Assumption

That LiteLLM's OpenAI-compatible proxy layer faithfully passes through Anthropic's Claude-specific headers and beta features. `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` in the README hints at this — some Claude features may not proxy cleanly. This should be validated immediately after Phase 1 deployment with a smoke test.

### Parked Ideas

- **Per-service LiteLLM virtual keys with rate limits**: Good idea for when multiple services are calling the gateway actively. Not needed for v1.
- **Prompt caching via LiteLLM**: LiteLLM supports semantic caching with Redis. Worth revisiting once baseline usage is established.
- **Alerting on cost spikes**: LiteLLM has webhook support. Combining with a homelab alerting channel (e.g. Slack / Telegram) would be a nice follow-on.

---

## Part 2 — PRD / Feature Spec

### Problem Statement

Running AI workloads (Claude Code subagents, future microservice features) currently requires each consumer to manage its own API keys, model versions, and cost tracking independently. There is no unified view of AI spending, no way to swap models without changing consumer config, and no access control layer in front of external AI APIs. Without a shared gateway, the homelab has no foundation for AI features and no visibility into what those features cost.

### Goals

1. **Reduce AI costs** — Route Claude Code subagent calls through Mistral Small/Large, targeting ≥50% cost reduction on background tasks within 30 days of deployment.
2. **Unify model access** — All homelab consumers reach AI via one endpoint (`litellm.furchert.ch`) with no direct external API keys in service configs.
3. **Centralise cost visibility** — A single usage dashboard shows cost-per-model and token consumption; accessible within 1 minute of any query.
4. **Secure the gateway** — All API calls require a valid credential; unauthenticated requests return 401. Auth-service issues and validates tokens for service consumers.
5. **Future-proof model routing** — Adding a new model (e.g. Ollama) requires a config change only, not code changes in any consumer.

### Non-Goals

- **Local model inference (Ollama)** — Out of scope for v1. The routing config will include a placeholder, but no Ollama pod will be deployed. Revisit once a suitable node is confirmed.
- **Multi-user RBAC in LiteLLM** — LiteLLM supports per-user virtual keys and spend limits. This is deferred; v1 uses a single master key for internal service use.
- **Prompt caching / semantic search** — LiteLLM's Redis-backed caching is a valuable follow-on but adds infra complexity. Excluded from v1.
- **External user-facing AI features** — The gateway is for internal homelab consumers only in v1. No public API product.
- **Modifying existing homelab services** — Auth, device, and data services will not be changed in this epic. Integration is a separate story in each service's repo.

### User Stories

**As a Claude Code/Cowork user**, I want my subagent tasks to route through a cheaper model automatically so that I can run longer, more complex sessions without cost anxiety.

**As a homelab developer (Dominic)**, I want a single dashboard showing AI cost-per-model and request logs so that I can see what AI is costing me in real time and catch unexpected usage spikes.

**As a homelab microservice** (auth, device, data), I want to call a stable internal AI endpoint with a JWT credential so that I can add AI features without managing external API keys or worrying about model changes.

**As a homelab operator**, I want to swap the underlying model (e.g. Mistral → Ollama) by changing a ConfigMap entry so that cost or capability changes don't require redeploying consumer services.

### Requirements

#### Must-Have (P0)

- LiteLLM deployed to `litellm` namespace in k3s with a dedicated Postgres database.
- Cloudflare Tunnel exposes LiteLLM at `litellm.furchert.ch` (HTTPS, authenticated).
- LiteLLM model routing configured for: `claude-3-5-sonnet` (Anthropic), `mistral-large` and `mistral-small` (Mistral API).
- Claude Code configured to use `ANTHROPIC_BASE_URL=https://litellm.furchert.ch` with `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`.
- Smoke test confirms `/health` and `/models` return expected responses; a sample chat completion succeeds for each configured model.
- All secrets (API keys, DB password, tunnel token) stored in a k8s Secret, never in ConfigMap or committed plaintext.

#### Nice-to-Have (P1)

- Auth-service issues OIDC/JWT tokens that LiteLLM accepts for service-to-service calls (replaces master key for microservices).
- LiteLLM virtual key per consumer (Claude Code, future microservices) with spend tracking per key.
- Automated update playbook for LiteLLM image versions (avoid malware-compromised releases like 1.82.7/1.82.8).

#### Future Considerations (P2)

- Ollama deployment on MacBook Air node; added as a third provider in LiteLLM routing config.
- Redis-backed prompt caching for repeated queries.
- Cost spike alerting via webhook to a notification channel.
- LiteLLM as the AI gateway for external-facing furchert.ch features.

### Success Metrics

| Metric | Target | Measure At |
|---|---|---|
| Subagent cost per Claude Code session | ≥50% reduction vs direct Anthropic | 30 days |
| P50 proxy latency overhead | <100ms additional vs direct API | Day 1 smoke test |
| Dashboard load time (first request) | <3 seconds | Day 1 |
| Unauthenticated request rejection rate | 100% (0 unauthed requests succeed) | Day 1 |
| Time to add a new model provider | <15 min (ConfigMap edit + rollout) | Verified at Ollama add |

### Open Questions

| Question | Owner | Blocking? |
|---|---|---|
| Does LiteLLM transparently proxy Anthropic beta headers that Claude Code relies on? | Dominic — validate in smoke test | Yes (Phase 1 completion) |
| Should auth-service issue LiteLLM virtual keys, or should LiteLLM consume auth-service JWTs directly via a custom auth handler? | Dominic + auth-service design | Yes (Phase 2 design) |
| What Postgres version / resource limits are appropriate for LiteLLM's usage volume? | Dominic | No |
| Should `litellm.furchert.ch` be accessible from the public internet, or restricted via Cloudflare Access to known IPs/users? | Dominic | No (default: locked behind Cloudflare Access) |

### Timeline

- **Phase 1** (1 sprint): Core infra deploy + Claude Code integration + smoke tests.
- **Phase 2** (1 sprint, depends on auth-service OIDC work): Auth-service integration for service-to-service security.
- **Phase 3** (future): Ollama, caching, alerting.

---

## Part 3 — Architecture Decision Record

# ADR-001: LiteLLM as the Homelab AI Gateway

**Status:** Proposed
**Date:** 2026-04-20
**Deciders:** Dominic Furchert

## Context

The homelab k3s cluster hosts several Java microservices (auth, device, data) and is the runtime for Claude Code / Cowork agentic sessions. As AI features become part of these workloads, each consumer would otherwise manage its own external API keys, model version pinning, and cost tracking. The cluster needs a single AI abstraction layer that:
- Presents a standard OpenAI-compatible API
- Routes requests to the right model (cloud or local) based on config, not code
- Tracks cost and usage centrally
- Can be secured via the existing auth-service OIDC stack

## Decision

Deploy LiteLLM on k3s as the homelab's AI gateway. All AI API calls from homelab consumers route through `https://litellm.furchert.ch` (external) or `litellm.litellm.svc.cluster.local:4000` (internal). No consumer service holds an external AI API key directly.

## Options Considered

### Option A: LiteLLM (self-hosted OpenAI-compatible proxy)

| Dimension | Assessment |
|---|---|
| Complexity | Medium — k8s manifests + Postgres + Cloudflare Tunnel |
| Cost | Near-zero infra overhead; Mistral API is pay-per-token |
| Scalability | Single replica sufficient for homelab load; horizontal scaling supported |
| Maintenance | Image updates required; malicious release history (1.82.7/1.82.8) means pinned versions only |
| Claude Code compat | Requires `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`; some Anthropic features may not proxy cleanly |

**Pros:** OpenAI-compatible API (drop-in replacement), built-in usage dashboard, multi-provider routing, virtual keys, active project.
**Cons:** Additional Postgres dependency, proxied Anthropic calls may lose some native features, image security hygiene required.

### Option B: Direct API calls per service (no proxy)

| Dimension | Assessment |
|---|---|
| Complexity | Low per-service; high in aggregate |
| Cost | No savings — each service pays full API rate |
| Scalability | Not a concern |
| Maintenance | API keys scattered across secrets; no unified cost view |

**Pros:** Simpler per-service. No new infra.
**Cons:** No cost visibility, no model flexibility, keys scattered, no foundation for shared AI features.

### Option C: Nginx reverse proxy with API key injection

| Dimension | Assessment |
|---|---|
| Complexity | Low |
| Cost | No savings |
| Scalability | Trivial |
| Maintenance | Low |

**Pros:** Lightweight, no dependencies.
**Cons:** No model routing, no cost tracking, no virtual keys, not OpenAI-compatible. Solves only the "single endpoint" problem, not the model flexibility or visibility problems.

## Trade-off Analysis

Option B is the status quo and defers all problems to later. Option C solves the wrong problem. Option A is the only choice that addresses all three goals (cost, flexibility, visibility). The main risk with LiteLLM is the proxying fidelity for Anthropic-specific features — this is a known, testable risk that can be resolved in the smoke test phase before full adoption.

The Postgres dependency is real but low-cost — the homelab already runs a Postgres deployment. A dedicated `litellm` database on the existing instance (or a separate lightweight deployment) is acceptable overhead.

## Consequences

- Claude Code subagent costs drop when Mistral models are used for routine tasks.
- All homelab services can add AI features by calling a stable internal URL with a JWT — no external API key management.
- LiteLLM image versions must be pinned and updated with care (malicious release precedent).
- Auth-service gains a new responsibility: issuing credentials accepted by LiteLLM (Phase 2).
- If LiteLLM is unavailable, all AI-dependent features in the homelab fail simultaneously — single point of failure. Mitigate with readiness probes and a fallback strategy in consuming services.

## Action Items

1. [ ] Deploy LiteLLM core infra to k3s (Phase 1 stories below)
2. [ ] Run smoke test confirming Anthropic proxy fidelity
3. [ ] Design auth-service → LiteLLM auth flow (Phase 2)
4. [ ] Pin LiteLLM image version and add to Renovate/Dependabot policy
5. [ ] Document fallback behavior for consumers when LiteLLM is down

---

## Part 4 — System Design

### Functional Requirements

- Accept OpenAI-compatible `/v1/chat/completions` requests
- Route to Anthropic Claude, Mistral API, or (future) Ollama based on model name in request
- Authenticate callers: human (OIDC via Cloudflare Tunnel + LiteLLM master key) and machine (JWT from auth-service)
- Persist request logs and cost data in Postgres
- Expose usage dashboard at `/ui`
- Terminate TLS via Cloudflare Tunnel (no in-cluster TLS termination needed)

### Non-Functional Requirements

- Availability: best-effort (homelab); no SLA
- Latency: p50 proxy overhead <100ms
- Scale: 1 replica; <10 concurrent requests typical
- Cost: Mistral API pay-per-token; Anthropic API pay-per-token; no fixed infra cost beyond k3s node

### Component Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  External Consumers                                             │
│  ┌──────────────────┐    ┌────────────────────────────────┐    │
│  │  Claude Code /   │    │  Future: furchert.ch frontend  │    │
│  │  Cowork          │    │  (browser, authenticated user) │    │
│  └────────┬─────────┘    └──────────────┬─────────────────┘    │
│           │ HTTPS                        │ HTTPS                │
└───────────┼──────────────────────────────┼─────────────────────┘
            │                              │
            ▼                              ▼
┌───────────────────────────────────────────────────────────────┐
│  Cloudflare Edge                                              │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  litellm.furchert.ch  (Cloudflare Tunnel)               │  │
│  │  → optional: Cloudflare Access policy for authz         │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────┬───────────────────────────────┘
                                │ Tunnel (encrypted)
┌───────────────────────────────▼───────────────────────────────┐
│  k3s Cluster — namespace: litellm                             │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  Deployment: litellm                                    │  │
│  │  ghcr.io/berriai/litellm:main-vX.Y.Z                   │  │
│  │  Port 4000                                              │  │
│  │  ┌─────────────────────────────────────────────────┐   │  │
│  │  │  Model Router                                   │   │  │
│  │  │  mistral-large  → Mistral API (cloud)           │   │  │
│  │  │  mistral-small  → Mistral API (cloud)           │   │  │
│  │  │  claude-*       → Anthropic API (cloud)         │   │  │
│  │  │  ollama/*       → Ollama svc (future, cluster)  │   │  │
│  │  └─────────────────────────────────────────────────┘   │  │
│  └──────────────────────────┬──────────────────────────────┘  │
│                             │                                  │
│  ┌──────────────────────────▼──────────────────────────────┐  │
│  │  Service: litellm  (ClusterIP :4000)                    │  │
│  └─────────────────────────────────────────────────────────┘  │
│                             │                                  │
│  ┌──────────────────────────▼──────────────────────────────┐  │
│  │  Deployment: cloudflared-litellm                        │  │
│  │  (cloudflare/cloudflared)                               │  │
│  │  Tunnels litellm.furchert.ch → litellm:4000             │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  Deployment: postgres (existing, namespace: default)    │  │
│  │  Database: litellm                                      │  │
│  │  User: litellm                                          │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
└───────────────────────────────────────────────────────────────┘

Internal service consumers (Phase 2):
┌──────────────────────────────────────────────────────────────┐
│  auth-service / device-service / data-service                │
│  → JWT from auth-service OIDC                                │
│  → POST litellm.litellm.svc.cluster.local:4000/v1/chat/...  │
└──────────────────────────────────────────────────────────────┘
```

### Data Flow — Claude Code Request (Phase 1)

```
flowchart TD
    A([Claude Code: subagent task]) --> B[ANTHROPIC_BASE_URL = litellm.furchert.ch]
    B --> C[Cloudflare Tunnel: litellm.furchert.ch]
    C --> D[LiteLLM pod: POST /v1/chat/completions]
    D --> E{model in request?}
    E -- mistral-small --> F[Mistral API: api.mistral.ai]
    E -- claude-3-5-sonnet --> G[Anthropic API: api.anthropic.com]
    F --> H[Response streamed back]
    G --> H
    H --> I[LiteLLM logs token cost to Postgres]
    I --> J([Claude Code receives completion])
```

### Auth Flow — Phase 2 (Service-to-Service)

```
flowchart TD
    A([device-service: needs AI completion]) --> B[POST /oauth/token to auth-service]
    B --> C[auth-service: client_credentials grant]
    C --> D[JWT issued: sub=device-service, aud=litellm]
    D --> E[POST litellm:4000/v1/chat/completions with Bearer JWT]
    E --> F{LiteLLM custom auth handler}
    F -- valid JWT --> G[Route to model, log against virtual key]
    F -- invalid --> H[401 Unauthorized]
```

### k8s Resource Design

| Resource | Namespace | Notes |
|---|---|---|
| `00-namespace.yaml` | — | Creates `litellm` ns |
| `01-secret.yaml` | litellm | MISTRAL_API_KEY, ANTHROPIC_API_KEY, LITELLM_MASTER_KEY, DATABASE_URL, CF_TUNNEL_TOKEN |
| `02-configmap.yaml` | litellm | LiteLLM model routing config (YAML). Ollama entry commented out as placeholder. |
| `03-deployment.yaml` | litellm | 1 replica; resource limits: 256Mi/500m → adjust after profiling |
| `04-service.yaml` | litellm | ClusterIP :4000 |
| `05-cloudflared.yaml` | litellm | cloudflared tunnel deployment |

### LiteLLM Model Routing Config (ConfigMap excerpt)

```yaml
model_list:
  - model_name: mistral-large
    litellm_params:
      model: mistral/mistral-large-latest
      api_key: os.environ/MISTRAL_API_KEY

  - model_name: mistral-small
    litellm_params:
      model: mistral/mistral-small-latest
      api_key: os.environ/MISTRAL_API_KEY

  - model_name: claude-3-5-sonnet
    litellm_params:
      model: anthropic/claude-3-5-sonnet-20241022
      api_key: os.environ/ANTHROPIC_API_KEY

  # Placeholder — enable when Ollama is deployed on MacBook Air node
  # - model_name: ollama/llama3
  #   litellm_params:
  #     model: ollama/llama3
  #     api_base: http://ollama.default.svc.cluster.local:11434

general_settings:
  database_url: os.environ/DATABASE_URL
  master_key: os.environ/LITELLM_MASTER_KEY
  store_model_in_db: false
```

### Smoke Test Plan

```bash
# 1. Health
curl https://litellm.furchert.ch/health

# 2. List models
curl https://litellm.furchert.ch/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"

# 3. Mistral completion
curl https://litellm.furchert.ch/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "mistral-small", "messages": [{"role": "user", "content": "ping"}]}'

# 4. Anthropic proxy completion
curl https://litellm.furchert.ch/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3-5-sonnet", "messages": [{"role": "user", "content": "ping"}]}'

# 5. Unauthenticated rejection
curl https://litellm.furchert.ch/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "mistral-small", "messages": [{"role": "user", "content": "ping"}]}'
# Expected: 401
```

### Deployment Diagram

```mermaid
graph LR
    subgraph Internet
        CC[Claude Code / Cowork]
        MistralAPI[Mistral API\napi.mistral.ai]
        AnthropicAPI[Anthropic API\napi.anthropic.com]
        CF[Cloudflare Edge\nlitellm.furchert.ch]
    end

    subgraph k3s Cluster
        subgraph litellm namespace
            LLM[litellm pod\n:4000]
            CFD[cloudflared pod]
            SEC[Secret\nkeys + DB creds]
            CM[ConfigMap\nmodel routing]
        end
        subgraph default namespace
            PG[(Postgres\nDB: litellm)]
        end
        subgraph future
            AUTH[auth-service\nOIDC JWT issuer]
            OLLAMA[Ollama pod\nMacBook Air node]
        end
    end

    CC -- HTTPS --> CF
    CF -- Tunnel --> CFD
    CFD -- HTTP --> LLM
    LLM -- reads --> SEC
    LLM -- reads --> CM
    LLM -- SQL --> PG
    LLM -- HTTPS --> MistralAPI
    LLM -- HTTPS --> AnthropicAPI
    AUTH -. Phase 2: JWT .-> LLM
    LLM -. Future .-> OLLAMA

    %% Scope: near/medium-term — not ultimate end state
```

### What to Revisit as the System Grows

- **Replica count**: Scale to 2+ replicas once internal services start calling LiteLLM regularly. Add a PodDisruptionBudget.
- **Auth**: Phase 2 auth-service integration removes the master-key-per-consumer pattern, which is a security risk at scale.
- **Ollama node affinity**: When Ollama is added, use `nodeSelector: kubernetes.io/hostname: <macbook-air-node-name>` to guarantee it lands on the capable node.
- **Rate limiting**: LiteLLM supports per-key rate limits. Add these before any external-facing AI feature uses the gateway.

---

## Part 5 — GitHub Issues (Awaiting Approval)

> `gh` CLI is not installed in this session. After approval, you will need to run the `gh issue create` commands from your local machine or the homelab repo checkout. All body files are provided below.

---

### 📋 Ready to create — awaiting your approval

| # | Title | Labels | Effort | Repo |
|---|---|---|---|---|
| 1 | `[Epic] LiteLLM AI Gateway — self-hosted model proxy on k3s` | `epic` | 2 sprints | homelab |
| 2 | `[Story] Deploy LiteLLM core infrastructure to k3s` | `user-story` | 3 pts (~2 days) | homelab |
| 3 | `[Task] Bootstrap litellm Postgres database and secrets` | `task` | 1 pt | homelab |
| 4 | `[Task] Configure LiteLLM model routing (Mistral + Anthropic + Ollama placeholder)` | `task` | 1 pt | homelab |
| 5 | `[Task] Configure Claude Code / Cowork to use LiteLLM proxy` | `task` | 1 pt | homelab |
| 6 | `[Task] LiteLLM smoke test and Anthropic proxy fidelity validation` | `task` | 1 pt | homelab |
| 7 | `[Story] Secure LiteLLM API endpoints via auth-service OIDC` | `user-story` | 5 pts (~3 days) | homelab |

⚠️ Nothing created yet. Type **"approve"** or **"go"** to proceed with issue body files and creation instructions.

---

### Issue Bodies

---

#### Issue 1 — Epic

**Title:** `[Epic] LiteLLM AI Gateway — self-hosted model proxy on k3s`
**Labels:** `epic`

```markdown
## Epic

> **Goal:** Deploy LiteLLM on the homelab k3s cluster as a unified AI gateway so that all consumers (Claude Code, future microservices, personal tools) call a single endpoint regardless of which model handles the request.
> **Scope:** Covers k3s deployment, Cloudflare Tunnel, Postgres persistence, model routing config (Mistral + Anthropic), Claude Code integration, and auth-service OIDC protection. Does NOT cover Ollama local inference, per-consumer rate limiting, or Redis prompt caching (all deferred to v2).

---

## Planned stories

- [ ] *(to be linked after story creation)*

---

## Notes

- Phase 1: core infra + Claude Code integration (no auth-service dependency)
- Phase 2: auth-service OIDC integration for service-to-service security
- LiteLLM image must be pinned — avoid 1.82.7 and 1.82.8 (malware-compromised releases)
- ADR and system design doc: see litellm-gateway.md in this repo (to be committed)

---

## Rough effort

**2 sprints** *(decompose into stories before scheduling)*
```

---

#### Issue 2 — Story: Deploy core infra

**Title:** `[Story] Deploy LiteLLM core infrastructure to k3s`
**Labels:** `user-story`

```markdown
## User story

> As a **homelab operator**, I want to deploy LiteLLM to the k3s cluster so that all AI consumers have a stable, version-pinned proxy endpoint at `litellm.furchert.ch`.

---

## Notes / limitations

- Postgres: use the existing `default/postgres` deployment; create a dedicated `litellm` database and user.
- Cloudflare Tunnel: new tunnel named `litellm`; DNS record `litellm.furchert.ch`.
- Secrets via k8s Secret only — never committed plaintext.
- LiteLLM image: pin to a specific known-good version. Never `:latest`.
- Out of scope: Ollama, auth-service OIDC, rate limiting.

---

## Definition of done

- [ ] `kubectl -n litellm get pods` shows all pods Running
- [ ] `curl https://litellm.furchert.ch/health` returns HTTP 200
- [ ] `curl https://litellm.furchert.ch/models` returns the configured model list
- [ ] Mistral and Anthropic completions succeed via the proxy (smoke test script passes)
- [ ] Unauthenticated requests return 401
- [ ] Usage dashboard is accessible at `https://litellm.furchert.ch/ui`
- [ ] All manifests committed to `homelab` repo under `kubernetes/litellm/`

---

## INVEST check

| Criterion | Status | Rationale |
|---|---|---|
| **I**ndependent | ✅ | No dependency on auth-service OIDC work |
| **N**egotiable | ✅ | Postgres placement, resource limits, Cloudflare tunnel config all open |
| **V**aluable | ✅ | Delivers cost savings via Mistral routing and usage visibility immediately |
| **E**stimable | ✅ | Existing README provides detailed deployment steps |
| **S**mall | ✅ | ~2 days; fits one sprint comfortably |
| **T**estable | ✅ | Smoke test script provides clear pass/fail criteria |

---

## Effort estimate

**3 story points** *(~2 days)*

---

## Tracks

*Sub-tasks linked here after creation.*
```

---

#### Issue 3 — Task: Postgres + secrets

**Title:** `[Task] Bootstrap litellm Postgres database and secrets`
**Labels:** `task`

```markdown
## Task

**Labels:** `task`
**Parent:** #[epic number]

### What needs to be done

Run the `postgres-setup.sql` script against the existing `default/postgres` deployment to create the `litellm` user and database. Populate `01-secret.yaml` with MISTRAL_API_KEY, ANTHROPIC_API_KEY, LITELLM_MASTER_KEY (generated via `openssl rand -hex 16`, prefixed `sk-`), DATABASE_URL, and CF_TUNNEL_TOKEN. Apply secret to cluster.

### Done when

- [ ] `litellm` database and user exist in the Postgres instance
- [ ] k8s Secret `litellm-secrets` exists in `litellm` namespace with all four keys
- [ ] Secret is not committed to git (`.gitignore` or sealed-secrets pattern applied)
```

---

#### Issue 4 — Task: Model routing config

**Title:** `[Task] Configure LiteLLM model routing (Mistral + Anthropic + Ollama placeholder)`
**Labels:** `task`

```markdown
## Task

**Labels:** `task`
**Parent:** #[epic number]

### What needs to be done

Write the LiteLLM `config.yaml` as a k8s ConfigMap. Include:
- `mistral-large` → `mistral/mistral-large-latest`
- `mistral-small` → `mistral/mistral-small-latest`
- `claude-3-5-sonnet` → `anthropic/claude-3-5-sonnet-20241022`
- Commented-out Ollama entry as a placeholder (ollama/llama3 pointing to `http://ollama.default.svc.cluster.local:11434`)

Set `general_settings.store_model_in_db: false` so routing is config-driven, not DB-driven.

### Done when

- [ ] ConfigMap applied to `litellm` namespace
- [ ] All three active model routes appear in `/models` response
- [ ] Ollama placeholder is commented but syntactically valid (can be enabled with one-line uncomment)
```

---

#### Issue 5 — Task: Claude Code integration

**Title:** `[Task] Configure Claude Code / Cowork to use LiteLLM proxy`
**Labels:** `task`

```markdown
## Task

**Labels:** `task`
**Parent:** #[epic number]

### What needs to be done

Update `~/.claude/settings.json` on the development Mac to set:
```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://litellm.furchert.ch",
    "ANTHROPIC_API_KEY": "sk-<LITELLM_MASTER_KEY>",
    "ANTHROPIC_MODEL": "mistral-large",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```
Also configure subagent model override: `CLAUDE_CODE_SUBAGENT_MODEL=mistral-small`.
Document the config in `OPERATIONS.md` under an "AI Gateway" section.

### Done when

- [ ] `claude` CLI routes completions through `litellm.furchert.ch` (confirmed via LiteLLM request logs)
- [ ] Subagent tasks visibly use `mistral-small` in the usage dashboard
- [ ] Fallback documented: how to switch back to direct Anthropic API if LiteLLM is unavailable
- [ ] Config documented in `OPERATIONS.md`
```

---

#### Issue 6 — Task: Smoke test

**Title:** `[Task] LiteLLM smoke test and Anthropic proxy fidelity validation`
**Labels:** `task`

```markdown
## Task

**Labels:** `task`
**Parent:** #[epic number]

### What needs to be done

Write a shell script `scripts/smoke-test-litellm.sh` that validates:
1. `/health` returns 200
2. `/models` returns expected model list with master key
3. Mistral Small chat completion succeeds (non-streaming)
4. Anthropic Claude chat completion succeeds via proxy (non-streaming)
5. Unauthenticated request returns 401
6. (Optional) Streaming completion for both models

This also validates the riskiest assumption: that Anthropic API features proxy cleanly through LiteLLM. Note any response fields that differ from native Anthropic API responses.

### Done when

- [ ] Script exists at `scripts/smoke-test-litellm.sh` and is executable
- [ ] All 5 checks pass against deployed LiteLLM instance
- [ ] Any Anthropic proxy fidelity gaps are documented in a comment in the script or in `OPERATIONS.md`
- [ ] Script is runnable by `make smoke-litellm` or equivalent
```

---

#### Issue 7 — Story: Auth-service OIDC integration

**Title:** `[Story] Secure LiteLLM API endpoints via auth-service OIDC`
**Labels:** `user-story`

```markdown
## User story

> As a **homelab microservice** (auth, device, data), I want to authenticate API calls to LiteLLM using a JWT issued by auth-service so that no service holds a long-lived LiteLLM master key.

---

## Notes / limitations

- Depends on: auth-service OIDC implementation (#37 in homelab-auth-service)
- LiteLLM supports custom auth handlers via `custom_auth` config. The handler would validate JWTs against auth-service's JWKS endpoint.
- The master key remains valid as a superuser credential for operator use.
- Machine-issued JWTs use `client_credentials` grant with `aud=litellm`.
- Out of scope: per-service spend limits, rate limiting (Phase 3).

---

## Definition of done

- [ ] auth-service issues JWTs with `aud=litellm` via client_credentials grant
- [ ] LiteLLM custom_auth handler validates JWT against auth-service JWKS
- [ ] A sample request from a homelab service using a JWT succeeds (HTTP 200)
- [ ] A request with an expired or invalid JWT returns 401
- [ ] Master key still works for operator use
- [ ] Auth flow documented in `OPERATIONS.md`

---

## INVEST check

| Criterion | Status | Rationale |
|---|---|---|
| **I**ndependent | ⚠️ | Depends on auth-service OIDC (#37 in homelab-auth-service) — flag dependency, don't block |
| **N**egotiable | ✅ | Custom auth handler implementation details are open |
| **V**aluable | ✅ | Removes long-lived key sprawl; required for safe service-to-service AI calls |
| **E**stimable | ✅ | ~3 days; LiteLLM custom_auth is documented |
| **S**mall | ✅ | Fits one sprint |
| **T**estable | ✅ | DoD covers both happy path and rejection |

---

## Effort estimate

**5 story points** *(~3 days)*

---

## Tracks

*Sub-tasks linked here after creation.*
```
