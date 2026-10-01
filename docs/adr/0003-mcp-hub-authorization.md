# ADR 0003 — MCP Hub Authorization: auth-service as Authorization Server, Hub as Resource Server

> Canonical copy (infrastructure repo). The parent workspace file forwards here (since homelab#177).

**Status:** Accepted (owner approval 2026-09-28, independent review passed), revision 4.3
**Approval:** approved by the owner 2026-09-28 together with spec 080 and its dependency table; effective since the independent final review of revision 4 passed (PASS WITH MINOR CHANGES, applied in revision 4.1). Revision 4.2 aligns this ADR with the implementation plans; the independent plan review covers these amendments
**Scope:** cross-repo — `homelab-mcp-hub` (new), `homelab-auth-service`, `homelab-device-service` (test only), `homelab` (infrastructure)
**Contract:** [`../080-mcp-hub.md`](../080-mcp-hub.md) §4
**Canonical location:** the infrastructure repository (`doemefu/homelab`), at `docs/adr/0003-mcp-hub-authorization.md`, next to `docs/080-mcp-hub.md` (spec 080 D39). The directory `docs/adr/` is new there; ADRs 0001 and 0002 stay in the parent workspace for now. Copying this file is a required task of the first (platform) pull request of `homelab#177`; from then on the parent workspace file is a forwarder
**Tracking:** `doemefu/homelab#168` (Epic "Unified mail & calendar MCP hub")
**Research:** report 01 (options), report 04 (independent verification, verdict "confirmed with changes"), review 05 (spec review, including the final pass), the local dry run and the live run against claude.ai (live spike, 2026-09-28; result recorded in `doemefu/homelab#175`). The research notes and spike records are kept in the owner's workspace and are not published.

---

## Context

Epic `#168` adds a self-hosted MCP server, `mcp-hub` at `https://mcp.furchert.ch/mcp`, that gives Claude read-only access to the owner's mail and calendars. Claude connects to it as a claude.ai **custom connector**. Whoever holds a valid token for this endpoint can read several mailboxes, so the endpoint must require OAuth. An authless connector is ruled out.

What claude.ai requires (Claude connector docs, checked 2026-09-28):

- A Streamable HTTP server that answers unauthenticated requests with `401` and `WWW-Authenticate: Bearer resource_metadata=…`, plus RFC 9728 protected resource metadata whose `resource` equals the connector URL.
- An authorization server with RFC 8414 or OIDC discovery that advertises PKCE `S256`.
- One of three client registration paths: Client ID Metadata Documents (CIMD), Dynamic Client Registration (DCR), or **"Use your own OAuth client"** (a pre-registered client id and optional secret entered in the connector dialog).
- Callback `https://claude.ai/api/mcp/auth_callback`. Discovery, token and MCP calls come from Anthropic's egress range `160.79.104.0/21`. Claude sends the RFC 8707 `resource` parameter and refreshes tokens proactively.

What the homelab has:

- **auth-service** is already the public OIDC identity provider (`auth.furchert.ch`, Spring Authorization Server 7.1.1). It has RFC 8414 and OIDC discovery, requires PKCE, keeps clients in the database, has no DCR and no CIMD, and has consent turned off for every client.
- Its access tokens today carry `aud` = client id and a `role` claim on user-driven grants, no `client_id` claim, and no `typ` header.
- Audience and issuer validation on the other homelab resource servers is planned work (`auth-service#101`, `device-service#81`, `#83`). Until it lands, a token issued for the hub must be shaped so that those services refuse it.

Constraints set by the owner (2026-09-28): a single user; the hub is a pass-through that stores no content; two separate credential layers (Claude → hub token; hub → provider credentials that stay in the cluster); lightweight Python stack with the official `mcp` SDK; per-domain scope names.

## Decision

1. **auth-service is the authorization server.** A pre-registered **confidential** client, `claude-mcp-hub`, is entered in claude.ai under "Use your own OAuth client". It has grant types `authorization_code` + `refresh_token`, PKCE, the claude.ai callback, scopes `mail:read` and `calendar:read` (no `openid`, no `offline_access`), client authentication `client_secret_post` (proven necessary: claude.ai used it) **and** `client_secret_basic`, a bcrypt-hashed secret (cost 10), a per-client access-token lifetime of 10 minutes, refresh-token rotation, a consent page whose decision is stored in the database (spec 080 D37), and a fail-closed owner-only check on authorization requests.
2. **The hub is a pure resource server.** It holds no signing keys and issues no tokens. It validates tokens offline against auth-service's JWKS: signature (RS256), `typ` = `at+jwt`, `iss`, `aud` = `https://mcp.furchert.ch/mcp`, `client_id` = `claude-mcp-hub`, time, and `sub` in a configuration-driven allowlist that doubles as the kill switch. In version 1 every token must carry **both** scopes, enforced by the SDK's `required_scopes`; per-tool scope enforcement is a later change. The hub serves RFC 9728 metadata and the `401`/`403` challenges of spec 080 §4.4 (both with the `scope` parameter), and accepts MCP protocol versions 2026-07-28 and 2025-11-25. It never forwards the token.
3. **Tokens for this client are audience-bound and refused elsewhere.** auth-service issues them with header `typ: at+jwt`, `aud` hard-mapped to the hub URL (a mismatching `resource` is rejected with `invalid_target`), a `client_id` claim, and **no** `role` claim. Customizer claim values must survive the authorization store's serialisation, so that refresh keeps working.
4. **Go-live gate.** Automated tests against the production validator chains prove that such a token gets `401` from auth-service `/api/v1/**` and from device-service, with positive controls (spec 080 §4.5, G1–G6). The refusing layer differs per service: at auth-service the JWT library's JOSE type verifier (Nimbus), at device-service Spring Security's `JwtTypeValidator` (the JWT library's own type check is off by default in device-service's decoder). Audience enforcement on those services stays with `#101` / `#81` / `#83`, under a binding ordering constraint: no service may start accepting `at+jwt` — whichever type-checking layer is relaxed — without also rejecting the hub audience.
5. **Revocation is a homelab-side action.** Removing the connector in claude.ai revokes nothing; access is cut with the hub kill switch, by revoking the client's authorizations and stored consent in auth-service, or by rotating the client secret (spec 080 §4.6).
6. **Documented fallback (not needed):** had the pre-registered-client path failed, the hub would mint its own tokens and use auth-service only as the upstream login (an OAuth proxy embedded in the hub), with its own dependency approval and an amendment of this ADR. The live spike passed, so the fallback has no work package; it stays recorded here. Cloudflare Access Managed OAuth is not the fallback; the runbook paragraph that still names it is superseded.

## Evidence

**Local dry run** (2026-09-28; throwaway auth-service instance, `origin/main` @ `8be2351` with a throwaway patch; Python stub hub; localhost only).

Showed:

- With a per-client setting for authentication methods, both HTTP Basic and form parameters work; unpatched, only Basic works although the metadata advertises both.
- Per-client refresh-token rotation works; the superseded refresh token is refused with `invalid_grant`.
- The shaped token (`at+jwt`, hub-only audience, `client_id`, no `role`) is accepted by the Python stub, and refresh works after shaping once the audience value is stored in a serialisable form (an immutable list broke the next refresh with HTTP 500, hence the persistence rule in decision 3).
- auth-service's API refused the shaped token with 401 and the error "JOSE header typ (type) at+jwt not allowed", which the dry-run notes attribute to the JWT library's (Nimbus) default JOSE type verifier. Whether Spring's `JwtTypeValidator` would also refuse it there was not shown.
- `resource` is tolerated and ignored on authorize, code exchange and refresh.

Did not cover: the per-client 10-minute lifetime (a global 120 s lifetime was used); rejection of a mismatching `resource` (`invalid_target`, not yet built); the consent page and its persistence; the owner-only allowlist; the environment wiring; a gate test against the production decoder bean (requests went to a running jar); anything involving claude.ai; device-service.

**Live run** (2026-09-28, run 2 passed; claude.ai web; throwaway local auth-service with patch part 1 — per-client authentication methods and refresh rotation, token shaping off, 120 s access tokens; stub hub on `mcp` 2.2.0; each behind a Cloudflare quick tunnel; the owner ran the claude.ai steps).

Showed:

- Discovery: after the 401, Claude fetched the resource metadata at the path in `resource_metadata` and then only the RFC 8414 document of the named authorization server; all requests came from Anthropic's published range `160.79.104.0/21`.
- Authorization request with PKCE and `resource`; callback on `claude.ai` (not `claude.com`), with `code` and `state` only.
- Claude called the token endpoint one second after the redirect and authenticated with **`client_secret_post`** (no Basic header), on code exchange and on refresh; `resource` was sent on authorize, code exchange and refresh.
- Tool call succeeded. Authenticated requests carried MCP protocol version **2026-07-28**; the unauthenticated probe carried 2025-11-25. Only `POST` requests were seen, no `GET` stream.
- Silent refresh was proactive (the hub never saw an expired token), and the **rotated** refresh token was stored and used on the next refresh. With 73 s left on a token, Claude did not refresh; once it had expired, one refresh preceded the next call.
- Removing the connector sent **no** revocation call and no other request within about one minute.

Did not cover: token shaping (Claude treats the token as opaque); the per-client 10-minute lifetime; rejection of a mismatching `resource`; the exact `resource` value (only its presence was logged); the consent page; owner-only authorization; rate limiting; Claude's reaction to a 403 `insufficient_scope`; Claude Desktop, mobile and Claude Code; the real Cloudflare tunnel and `furchert.ch` zone settings; device-service.

**Implementation plans** (2026-09-28, source reading by the per-repository planning agents, not executed against a running system): device-service's decoder refuses a typed token through `JwtTypeValidator`, not through the JWT library; auth-service's username lookup is exact and case-sensitive; the SDK checks the token expiry without leeway and authenticates before it checks `Host` and `Origin`. Spec 080 records the consequences (§4.3, §4.4, §4.5).

**Acceptance.** The evidence meets the acceptance condition set in revision 2 (discovery → login → token → tool call → silent refresh with a pre-registered auth-service client). The owner approved this ADR on 2026-09-28, and the independent final review of revision 4 passed; the status is therefore **Accepted**.

## Options considered

The six options come from report 01. Where report 04 corrected report 01, the correction is used.

| # | Option | Verdict | Reason |
|---|---|---|---|
| 1 | **auth-service with a pre-registered confidential client** ("Use your own OAuth client"); hub = resource server | **Chosen; proven live** | It is the smallest change to a system that already runs. Identity stays single, no new public **authorization** endpoint is added (the hub's own hostname `mcp.furchert.ch` is new), and no beta product is involved. The hub code is standard JWT validation. It follows the path Claude documents for custom connectors, and it advances `#101`, which the homelab needs anyway. Report 04 confirmed it **with changes**: accept `client_secret_post`; stamp `typ: at+jwt`, hub-only `aud`, a `client_id` claim and no `role`; test the rejection at auth-service and device-service instead of waiting for audience enforcement everywhere; drop data-service from the gate (not internet-reachable, already scope- and subject-gated). The live run against claude.ai confirmed the flow end to end, including `client_secret_post` and refresh with rotation; what neither run covered is listed under "Evidence" |
| 2 | Cloudflare Access Managed OAuth in front of the hub (identity from auth-service, GitHub or one-time PIN) | Rejected | It keeps unauthenticated traffic off the cluster and needs no IdP change. But it is an open-beta product, and an open Anthropic report (claude-ai-mcp#980, since 2026-09-09) says hosted Claude fails against it. It adds a second identity perimeter with opaque tokens. Report 01 ranked it as the fallback; report 04 demoted it. Revisit only if #980 is resolved and the owner wants zero IdP changes |
| 3 | OAuth proxy embedded in the hub (hub mints its own tokens; auth-service as upstream login) | **Documented fallback, not needed** | Tokens would be useless outside the hub, and Claude Code would work via CIMD. But the hub would become an authorization server: signing key, token and refresh store, consent state and the upstream tokens, all in the component that already holds mailbox credentials. It is framework code with a history of claude.ai incompatibilities, and in Python it most likely means FastMCP, which the owner did not choose (new dependency). It would rank first only if Claude Code became a requirement or the auth-service slice could not ship |
| 4 | Third-party hosted IdP (Auth0, Clerk, WorkOS, …) | Rejected | Mature DCR/CIMD and MFA, and least code. But it adds a second identity silo outside the homelab, puts mailbox authorization in a vendor account with free-tier limits, and widens the blast radius to that vendor |
| 5 | Open Dynamic Client Registration on auth-service | Rejected | It would let clients be registered on the homelab IdP without the owner's involvement. Safe operation would need public-client refresh-token rotation, a redirect allowlist, mandatory consent and a cleanup job for Claude's per-connection registrations. DCR is also deprecated in MCP 2026-07-28. No benefit over option 1 for one user |
| 6 | Client ID Metadata Documents on auth-service (allowlisted to Anthropic's documents) | Rejected for now | SAS 7.1.1 has no CIMD support, so it needs a custom client repository with SSRF guards, public-client refresh handling and consent: custom security code on the IdP. The only gain is Claude Code support without a manual client, which v1 does not need. Possible later |

## Consequences

**Positive**

- One identity provider and one login for the owner. No new public authorization endpoint, and no signing keys outside auth-service.
- The chosen path works with claude.ai today (live run), including the authentication method Claude actually uses and refresh with rotation.
- The hub's security-critical code is small: offline JWT validation plus an allowlist, covered by contract tests.
- Hub tokens are refused by the other homelab APIs from day one (proven by tests), before `#101` is finished.
- Revocation has fast levers that do not depend on Anthropic: the Cloudflare block (with a rule slot kept free for it), the two-step hub allowlist switch, revoking the client's authorizations and consent, and rotating the client secret (spec 080 §4.6).
- auth-service gains per-client settings (authentication methods, consent, token lifetimes, rotation, audience, allowed users) that later clients can reuse, and a stored, timestamped consent record for every client that requires consent (spec 080 D37).

**Negative**

- Go-live depends on changes in three repositories: auth-service (client and token shape), device-service (gate test) and the new hub, plus infrastructure wiring.
- auth-service gains custom security code: RFC 8707 `invalid_target` handling, per-client `typ`/`aud`/`role` shaping, and a fail-closed owner-only authorization check with a consent page for this client (both ship in the first auth-service change, owner decision 2026-09-28). It needs its own tests (spec 080 G4b) and review.
- Consent is stored in the database for the whole identity provider (spec 080 D37): an additive migration adds timestamps to the existing consent table, and every revocation path must remove consent rows as well as authorizations. The incident SQL therefore deletes both (spec 080 §4.6), and deleting or deactivating a user now revokes that user's authorizations and consents for all clients (spec 080 D38). A consent row left behind would skip the consent page on a new authorization; the gate test G4b covers the deletion paths.
- The consent page and the owner-only check were not exercised against claude.ai in either spike run; the first production login checks them (spec 080 §10.4).
- The interim barrier (a `typ: at+jwt` header refused by default type checks) relies on library defaults that differ per service: the JWT library's JOSE type verifier (Nimbus) at auth-service, observed refusing the token in the dry run, and Spring's `JwtTypeValidator` at device-service, from source reading. It holds only as long as the ordering constraint on `#101` / `#81` / `#83` is respected for both layers, and the gate tests must exercise the production validator chain; they, not this reasoning, decide whether the barrier holds.
- Removing the connector in claude.ai does not revoke the tokens Anthropic holds; the owner must use a homelab-side lever when access should end, including when the hub is retired.
- The access-token lifetime is 10 minutes rather than the roughly 5 minutes report 04 suggested. The live run showed that Claude refreshes on demand rather than before every call, so a shorter lifetime would also work; 10 minutes keeps a briefing burst inside one token and so keeps refresh-rotation races rare (spec 080 §4.1 note 1).
- Anthropic stores the client secret and a refresh token for the hub. That is inherent to every option; the exposure is hub read access until revoked.
- The IdP login now guards mailbox access. This raises the priority of `auth-service#104` (rate limiting keyed by client/principal, not only by the shared Anthropic range) and of a second factor for IdP logins (`auth-service#108`).
- Claude Code and other MCP clients are not supported in v1: no loopback redirect, and the WAF allow rule (spec 080 D31) would block them. Claude Desktop and mobile were not tested live.

**Follow-ups**

- First production login (spec 080 WP7): confirm the owner-only check, the consent page and the stored consent row, the exact `resource` value (O3), the production tunnel and zone settings (O8, O9).
- `auth-service#101`: audience allowlists and issuer validation on auth-service `/api/v1/**`; `role` only for first-party clients; `at+jwt` for all tokens — in the order spec 080 §4.5 requires.
- `device-service#81` / `#83`: issuer, audience and type validation and authorization on `/devices/**`.
- `auth-service#104`: rate limiting and lockout, not keyed on source IP alone; the edge rate limit of spec 080 §4.7 bridges the time until then.
- `auth-service#108`: a second factor for IdP logins.
- Consent decisions and revocations as audit events in the login-event outbox (issue to be created, spec 080 §11.4).
- Per-tool scope enforcement when a second tool group arrives, including Claude's reaction to a 403 `insufficient_scope` (spec 080 §4.8, O24, O25).
- `homelab#127`: NetworkPolicy for the hub (ingress to the MCP port only from cloudflared, to the internal port only from monitoring).

## References

- [`../080-mcp-hub.md`](../080-mcp-hub.md) — the cross-repo contract implementing this ADR
- ADR 0002 (network telemetry ownership; parent workspace `docs/adr/0002-network-telemetry-ownership.md`, which stays there for now) — precedent for bootstrapping a new service and for data-service's scope/subject gating that keeps it out of this gate
- auth-service `INTERFACES.md` — client seeding (§6) and existing token shapes (§1, §2, §8)
- Claude connector docs: `https://claude.com/docs/connectors/building/authentication`, `https://claude.com/docs/connectors/custom/add-unlisted`; MCP authorization 2025-11-25
- Anthropic issue reports cited in report 04: `anthropics/claude-ai-mcp` #667 (client authentication method), #980 (Cloudflare Access), #984/#846/#962 (authorization-server discovery), #1028/#653/#540/#956/#671/#1029 (token call not made)

## Revision history

| Revision | Date | Changes |
|---|---|---|
| 1 | 2026-09-28 | First draft |
| 2 | 2026-09-28 | Review 05 (m4, m15) and session-lead resolutions: both scopes required in v1, 10-min lifetime, bcrypt cost 10, no `offline_access`, spike before approval, task-oriented wording; local dry-run evidence added; runbook fallback marked superseded |
| 2.1 | 2026-09-28 | Review second pass N-1, N-3, N-4: evidence split into "showed" and "did not exercise" (Decision and option 1); the interim barrier attributed to the JWT library's JOSE type verifier (observed) and Spring's `JwtTypeValidator` (source), ordering constraint covers both; 403 carries `scope`, Claude's reaction added to the spike follow-up |
| 3 | 2026-09-28 | Live spike S1 passed: status "Accepted by evidence, pending owner approval"; separate "Evidence" section for the local dry run and the live run, each with what it did not cover; `client_secret_post` proven necessary; protocol versions 2026-07-28 and 2025-11-25; new decision 5 (revocation is homelab-side, no revocation on connector removal); fallback kept as documented, not needed; TTL rationale updated with the live refresh observation |
| 4 | 2026-09-28 | Approval line added: approved by the owner 2026-09-28, effective once the independent review of revision 4 has passed. Consequences updated for the owner's decision that consent and the (fail-closed) owner-only check ship in the first auth-service change and are checked at the first production login; follow-ups and the rate-limit follow-up aligned. No other decision changed |
| 4.1 | 2026-09-28 | Independent final review passed (PASS WITH MINOR CHANGES): status "Accepted (owner approval 2026-09-28, independent review passed)"; approval line and acceptance paragraph updated; F-6: the WAF allow rule is referred to as decided (spec 080 D31), not optional; the reported duplicate evidence bullet was checked and is not present in revision 4 (the token-endpoint bullet appears once), so nothing was removed; the completed review follow-up was dropped and the first-production-login follow-up now names the owner-only check |
| 4.2 | 2026-09-28 | Aligned with the implementation plans (no decision reversed): canonical location in the infrastructure repository with exact paths, the copy a required task of the first (platform) pull request of `homelab#177`, ADRs 0001/0002 staying in the parent workspace, so the ADR 0002 reference is no longer a relative link (spec 080 D39); decision 1 names refresh rotation, stored consent and the owner-only check; decision 4 names the refusing layer per service (Nimbus at auth-service, `JwtTypeValidator` at device-service); decision 5 and the consequences cover consent persistence, the amended incident SQL and user-deletion revocation (spec 080 D37, D38); context corrected (today's tokens carry no `typ` header); evidence paragraph for the implementation plans; the proposed second-factor issue is now `auth-service#108`; audit-event follow-up added |
| 4.3 | 2026-09-30 | Public-copy cleanup (no decision changed): the research line names the public spike issue `doemefu/homelab#175` instead of local file paths; Consequences: deactivating a user also revokes (spec 080 D38) |
