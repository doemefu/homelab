# 054 — Access-Token Contract: Resource Audiences, Typed Tokens, `role` for First-Party Clients Only

**Status:** Draft for the owner (2026-11-03). Owner decisions D1–D6 in §10 are open. Nothing is implemented from this document yet.
**Tracking:** `doemefu/homelab-auth-service#101` (umbrella), children `doemefu/homelab-device-service#81`, `doemefu/homelab-data-service#25`; related `doemefu/homelab-auth-service#102` (dedicated netmon client), `doemefu/homelab#159` (Grafana OIDC), `doemefu/homelab#122` (Mosquitto auth), Epic `doemefu/homelab#152`
**Producer:** `homelab-auth-service`. **Consumers:** `homelab-auth-service` (`/api/v1/**`, `/userinfo`), `homelab-device-service`, `homelab-data-service`, `furchert-ch` (caller only), `homelab-mcp-hub` and the club MCP server (unchanged).
**Builds on:** spec 080 §4.2 (audience-bound hub tokens) and §4.5 (go-live gate and the **binding ordering constraint** on `#101`/`#81`), ADR 0003. Supersedes the token sketch in `052-architecture-target.md` § "Authentication Flow", which predates Spring Authorization Server.

---

## 1. Problem

auth-service signs every access token with the same key. Most resource servers check only the signature and the timestamps:

| Resource server | Checks today (origin/main, 2026-11-03) | Gap |
|---|---|---|
| auth-service `/api/v1/**` and `/userinfo` (one shared `JwtDecoder` bean: Spring's authorization-server configurer enables the resource server on the AS chain with that bean) | signature, `exp`/`nbf`, `typ` ∈ {absent, `JWT`} (Nimbus's default JOSE type verifier and Spring's `JwtTypeValidator`), no `azp` (ID tokens rejected, PR #117) | no `aud`, no `iss` check: an ADMIN's access token issued to **any** client (n8n, LiteLLM, Grafana, Home Assistant; issue #101 also names Open WebUI, but it has no auth-service client) is accepted as ADMIN |
| device-service `/devices/**`, STOMP `CONNECT` | signature, `exp`/`nbf`, `typ` ∈ {absent, `JWT`} | no `iss`, no `aud`, no `azp` check, no role check: any valid token, including a USER's, an ID token or an IoT device token, can call `POST /devices/{id}/control` |
| data-service `/api/netmon/**` | signature, `exp`/`nbf`, `iss`, `typ` ∈ {absent, `JWT`} (Boot's default `JwtTypeValidator`), `sub` allowlist, `SCOPE_netmon:read` | no `aud` |
| mcp-hub, club MCP server | `typ` ∈ {`at+jwt`, `application/at+jwt`}, exact `aud`, `client_id`, scopes, subject allowlist | none (reference shape) |

Two more problems:
- `role` is in the access token of every user-driven grant, including those of third-party apps. Those apps never need it in the access token.
- Today the only thing keeping the hub and club tokens out of `/api/v1/**` and device-service is that both reject `typ: at+jwt` (spec 080 §4.5).

## 2. Terms

- **Resource audience:** an identifier of one resource server, carried in `aud`. Section 3 is the registry.
- **First-party client:** a client whose code lives in a homelab repo and which sends auth-service access tokens to homelab resource servers: `furchert-ch` (user grants and netmon), `data-service` and `device-service` (`client_credentials` only), `furchert-ch-netmon` (after `auth#102`), and the IoT device clients. device-service's own SSO login is an RP use: its AT goes only to `/userinfo`.
- **Third-party client:** an OIDC relying party that only signs users in to its own UI: `grafana`, `homeassistant`, `n8n`, `litellm`. These clients never send auth-service access tokens to a homelab resource server; at most they call `/userinfo`.
- **Audience-bound client:** a client with `access-token-audience` (spec 080 §4.2): `claude-mcp-hub`, `claude-club-mcp`. This contract does not change them.

## 3. Audience registry

One audience per resource server. The values are identifiers, not routing targets; no consumer fetches them.

| Name (config key) | Resource server | Proposed value (D1, recommended) | Alternative (D1 option b) |
|---|---|---|---|
| `auth-api` | auth-service `/api/v1/**` | `https://auth.furchert.ch/api/v1` | `homelab:auth-api` |
| `device-api` | device-service REST + STOMP | `https://device.furchert.ch` | `homelab:device-api` |
| `data-api` | data-service `/api/**` | `https://data.furchert.ch` (identifier only; no DNS record or tunnel route is created) | `homelab:data-api` |
| `mqtt` | Mosquitto (future, `#122`) | reserved; value fixed by `#122` | reserved |
| — | mcp-hub | `https://mcp.furchert.ch/mcp` (unchanged, spec 080) | — |
| — | club MCP server | `https://club-mcp.furchert.ch/mcp` (unchanged) | — |

Rules:
- `auth-api` is deliberately not the issuer string `https://auth.furchert.ch`, so an audience check can never be confused with the issuer check.
- The identifiers are case-sensitive and compared exactly (no trailing-slash normalisation), as in spec 080.

## 4. Token shapes after the rollout

Notation: **AT** = access token, **IDT** = ID token. `iss` is always `https://auth.furchert.ch`; `sub` is the username for user-driven grants and the client id for `client_credentials`.

### 4.1 Access tokens

| Client (grant) | `aud` | `client_id` claim | `role` | `scope` | header `typ` (today → step 4) |
|---|---|---|---|---|---|
| `furchert-ch` (authorization_code / refresh) | `[auth-api]` (`device-api` only after **D6**, when `furchert-ch#45` calls device-service) | `furchert-ch` | yes | as granted | absent → `at+jwt` |
| `furchert-ch` (client_credentials, `netmon:read`) — until `#102` removes the grant | `[data-api]` (from the scope map, §5.2) | `furchert-ch` | no | `netmon:read` | same |
| `furchert-ch-netmon` (client_credentials; after `#102`) | `[data-api]` | `furchert-ch-netmon` | no | `netmon:read` | same |
| `device-service` (authorization_code / refresh, its own SSO, which protects only Swagger; the AT goes only to `/userinfo`) | unchanged: `device-service` (no resource audience) | `device-service` | no | as granted | same |
| `device-service` (client_credentials, `clients:admin`; used by the `device-handling` branch, `device#62`, not by main today) | `[auth-api]` | `device-service` | no | `clients:admin` | same |
| `data-service` (client_credentials, `login-events:read`) | `[auth-api]` | `data-service` | no | `login-events:read` | same |
| `grafana`, `homeassistant`, `n8n`, `litellm` (authorization_code / refresh) | unchanged: the client id (no resource audience) | client id | **no** | as granted | same |
| `claude-mcp-hub`, `claude-club-mcp` | unchanged (spec 080 §4.2) | unchanged | no | unchanged | `at+jwt` (unchanged) |
| IoT device clients (client_credentials, `mqtt:*`) | unchanged: device client id | — | no | `mqtt:pub mqtt:sub` | unchanged; `#122` decides |

Notes:
- `aud` is always serialised as an array when it has more than one value. Consumers MUST accept both the string and the array form (RFC 7519).
- The `client_id` claim (RFC 9068 §2.2) is new for first-party and third-party ATs. It is additive. Consumers may use it, but this contract requires no consumer to.
- Third-party ATs keep `aud` = client id, so **no homelab resource server accepts them** after step 3, because none of them lists a client id as an audience. auth-service refuses at startup any registry value that equals a client id or the issuer (§5.2).
- **Breaking for third-party apps:** removing `role` from their ATs (step 2b) is the one change in this contract that is not additive before step 3. An app that decodes its AT for `role` loses it (O2).
- The netmon AT of client `furchert-ch` stops carrying `aud=furchert-ch`. Spec 060 §7.5's sentence about that `aud` changes with step 2a.
- Multi-audience tokens (D6): one AT valid at two resource servers can be replayed from one to the other. That is why `furchert-ch` gets `device-api` only by an explicit decision.

### 4.2 ID tokens and `/userinfo`

- ID tokens keep `aud` = client id and `azp` (OIDC Core). Resource servers keep rejecting tokens that carry `azp`.
- `role` in ID tokens and in the `/userinfo` response: owner decision **D2** (§10). Recommended: a per-client opt-in, `release-role-claim: true`, set only for `furchert-ch`, `device-service` and `grafana` (if D3 picks the claim mapping). n8n, LiteLLM and Home Assistant would then no longer see `role` anywhere. This is a separate config step (2c) because it is breaking for those apps.
- `/userinfo` keeps accepting the AT of every OIDC client that holds the `openid` scope, with no audience check (§6.1).

## 5. Producer contract (auth-service)

### 5.1 Configuration keys (`application.yaml`, no new environment variables, no secrets)

| Key | Type / default | Meaning |
|---|---|---|
| `app.oidc.resource-audiences` | map name → URI; default empty | The registry of §3: `auth-api`, `device-api`, `data-api` |
| `app.oidc.scope-audiences` | map scope → name; default empty | Audience derived from a granted scope for `client_credentials` (§5.2). Keys contain `:`, so they MUST be written in bracket notation (`"[netmon:read]": data-api`). Spring Boot drops the colon from a plain map key (`netmon:read` would bind as `netmonread`), and the mapping would then silently never match |
| `app.oidc.clients[].resource-audiences` | list of names; default `[]` | Audiences for this client's user-driven ATs (§4.1). Empty = keep `aud` = client id |
| `app.oidc.clients[].first-party` | boolean; default `true` until step 2b, then per client | `true` keeps `role` in this client's user-driven ATs; `false` drops it. Step 2b sets `false` for the third-party clients |
| `app.oidc.clients[].release-role-claim` | boolean; default `true` until step 2c, then per client (D2) | `true` keeps `role` in this client's ID tokens and `/userinfo` |
| `app.oidc.access-token-type` | `default` \| `at+jwt`; default `default` | `default` = today's header (no `typ` on first-party and third-party ATs). `at+jwt` = step 4. Audience-bound clients always get `at+jwt` |
| `app.oidc.api-audience` | name; default `auth-api` | The audience `/api/v1/**` requires (§6.1) |

The existing keys `access-token-audience`, `allowed-resources` and the other audience-bound options (INTERFACES.md §2) are unchanged. A client MUST NOT have both `access-token-audience` and `resource-audiences`; startup fails if one does.

**Startup validation (fail closed):** auth-service refuses to start when any of these holds:
- a `resource-audiences` entry, a `scope-audiences` value or `api-audience` names no registry entry;
- a `scope-audiences` key is a scope that no configured client has, which catches a key mangled by binding;
- a registry URI equals a client id or the issuer.

A failed start is visible at once. A silently missing audience would surface only as consumer 401s.

### 5.2 Behaviour

1. **User-driven grants** (authorization_code, refresh_token) of a client with a non-empty `resource-audiences` list:
   - `aud` = the resolved URIs, in configuration order;
   - a `client_id` claim is added;
   - `role` is kept only when `first-party: true`.
2. **`client_credentials`:**
   - `aud` = the set of audiences mapped from the **granted** scopes. Proposed map (bracket keys, §5.1): `"[clients:admin]"` → `auth-api`, `"[login-events:read]"` → `auth-api`, `"[netmon:read]"` → `data-api`; `mqtt:pub` and `mqtt:sub` stay unmapped until `#122`.
   - If no granted scope is mapped, `aud` stays the client id (today's behaviour).
   - `client_id` is added for every client except IoT device clients, which keep today's shape including `device_id`.
3. **Third-party clients** (`first-party: false`, empty `resource-audiences`): `role` is removed from the AT and `client_id` is added. The ID token and `/userinfo` follow `release-role-claim`.
4. **`aud` source:** for clients without `allowed-resources`, `aud` comes only from configuration (registry, scope map, or the client id) and **never** from the RFC 8707 `resource` request parameter. Today that parameter is ignored for these clients, and this stays so.
5. **Storage shape:** the `aud` list MUST be put into the claims as a mutable list. This is the same rule as spec 080 §4.2. Spring Authorization Server stores the claims with the authorization, and an immutable list made refresh fail with HTTP 500 in the hub dry run.
6. **Refresh:** a refreshed AT is shaped by the same rules, so tokens minted after the deploy get the new shape on their next refresh. Nothing is migrated in the database.
7. **Step 4:** `app.oidc.access-token-type: at+jwt` sets header `typ: at+jwt` on every AT except IoT device ATs (left to `#122`).

## 6. Consumer contract (validation)

Every homelab resource server MUST validate, in this order: signature (JWKS), `exp`/`nbf` (60 s skew), `iss` = `https://auth.furchert.ch`, no `azp`, `typ` within the accepted set, `aud` contains its own audience. Then it applies its authorization rules (§7).

Accepted `typ` (case-insensitive):

| Phase | Accepted |
|---|---|
| from step 3 until step 5 | absent, `JWT`, `at+jwt`, `application/at+jwt` |
| after step 5 (optional cleanup) | `at+jwt`, `application/at+jwt` |

**Binding (spec 080 §4.5):** a service that starts accepting `at+jwt` MUST, in the same release, require its own audience, so that `aud = https://mcp.furchert.ch/mcp` and `aud = https://club-mcp.furchert.ch/mcp` are refused. Its gate test (G2 for auth-service, G5 for device-service, and a new equivalent for data-service) MUST then assert rejection **by audience**, keeping the positive control. Requiring the service's own audience covers every other audience as well, so no deny-list is needed. Spring has **two** layers that refuse `at+jwt` today: Nimbus's default JOSE type verifier, used in auth-service's decoder, and Spring's `JwtTypeValidator`, in the Boot default validators of all three Java services. Every consumer PR relaxes whichever layers its decoder has, and only together with the audience requirement.

**The single exception is `/userinfo`.** It accepts `at+jwt` from step 4 on without an audience check. This is safe only because the endpoint requires the `openid` scope and a stored, active authorization, and neither the hub client nor the club client can obtain `openid` (spec 080 §4.1). A test MUST show that hub-shaped and club-shaped tokens do not get 200 there (403 `insufficient_scope` or 401). Spec 080 §4.5 records this exception when step 4 ships.

Failures give `401` with `WWW-Authenticate: Bearer error="invalid_token"` (Spring default). A missing role or scope gives `403`.

### 6.1 auth-service `/api/v1/**`

- Requires `aud` ∋ `app.oidc.api-audience` (`auth-api`) and `iss`; accepts the `typ` set above.
- The audience requirement applies to the `/api/v1/**` filter chain **only**. Today `/userinfo` (authorization-server chain) and `/api/v1/**` share the `jwtDecoder(jwkSource)` bean. In step 3a the API chain therefore gets its **own** decoder through `oauth2ResourceServer(rs -> rs.jwt(jwt -> jwt.decoder(...)))`, and it must not become a second `JwtDecoder` bean, which would make the bean lookup ambiguous (see the Javadoc in `AuthorizationServerConfig`). The shared bean that serves `/userinfo` stays unchanged until step 4. In step 4 it accepts `at+jwt` at both layers, with no audience check (the exception above).
- `/userinfo` MUST keep accepting the ATs of every OIDC client that holds `openid`, third-party clients included.
- Accepted callers after step 3:
  - furchert-ch user ATs (`/dashboard/auth`)
  - data-service `login-events:read`
  - device-service `clients:admin`

### 6.2 device-service (`device#81`)

- Spring Boot properties:
  - `spring.security.oauth2.resourceserver.jwt.issuer-uri` = `${JWT_ISSUER:https://auth.furchert.ch}`
  - `spring.security.oauth2.resourceserver.jwt.audiences` = `${JWT_AUDIENCE:<device-api>}`
  - `jwk-set-uri` stays as it is
- The custom `typ` validator replaces the default `JwtTypeValidator`.
- The same decoder serves STOMP `CONNECT`.
- `role` → `ROLE_<role>` authority mapping (taken over from the `device-handling` branch, `device#62`).
- Also rejects tokens with `azp` (ID tokens). IoT device tokens are rejected because they lack `device-api`.
- Accepted callers after step 3: furchert-ch user ATs, once D6 adds `device-api` for the device admin GUI (`furchert-ch#45`). Until then device-service accepts no bearer token at all. That matches today's usage: furchert-ch does not call device-service yet, and device-service's own SSO uses session login, not bearer tokens. Before enforcing, confirm from the device-service logs that no other caller exists (O1).

### 6.3 data-service (`data#25`)

- `spring.security.oauth2.resourceserver.jwt.audiences` = `${JWT_AUDIENCE:<data-api>}`, composed with the existing issuer validator.
- The transition `typ` set replaces Boot's default `JwtTypeValidator`. data-service rejects `at+jwt` today, so without this change step 4 would break `/dashboard/network`. Tests: `at+jwt` with `data-api` → 200; `at+jwt` with a hub audience → 401.
- Also rejects tokens with `azp`.
- `AllowedClientAuthorizationManager` (subject allowlist) and `SCOPE_netmon:read` stay as they are. Recommended with `#102`: match the allowlist against the `client_id` claim instead of `sub`. `sub` is a username for user grants and could collide with a client id (`auth#103`).
- After `#102`, `netmon.api.allowed-clients` changes to `[furchert-ch-netmon]` in the same data-service release that the furchert-ch switch depends on (order in §8).

### 6.4 Shipping a validator disabled-by-config

A consumer MAY merge its validator before the producer step is live, provided **one** switch, a non-empty audience property, controls both behaviours:
- **Audience property empty:** no audience check, and the `typ` check stays exactly as today (`at+jwt` refused). The service logs one WARN at startup.
- **Audience property set:** the audience is required and the transition `typ` set is accepted.

A validator that accepted `at+jwt` while the audience was empty would let hub and club tokens in, because device-service and data-service deploy on merge (Flux), and it would break the spec 080 binding. If a consumer uses this option, its first merge ships an empty default (not the non-empty defaults shown in §6.2/§6.3), and the change that sets the value in `application.yaml` or `k8s/deployment.yaml` is that consumer's step-3 change.

## 7. Authorization per operation (after step 3)

This contract adds only the audience requirement. The role and scope rules of auth-service are unchanged from its `INTERFACES.md` §4 "Authorization Rules".

| Service / operation | Requires |
|---|---|
| auth-service `GET /api/v1/users/{id}`, `POST /api/v1/users/{id}/reset-password` | `aud` ∋ auth-api; own record or `role=ADMIN` (unchanged; the own-record check is in `UserService`) |
| auth-service other `/api/v1/users/**` | `aud` ∋ auth-api; `role=ADMIN` (unchanged) |
| auth-service `/api/v1/clients/**` | `aud` ∋ auth-api; `role=ADMIN` or `SCOPE_clients:admin` (unchanged) |
| auth-service `GET /api/v1/login-events` | `aud` ∋ auth-api; `SCOPE_login-events:read` only (unchanged) |
| auth-service `GET /userinfo` | any OIDC client's AT with scope `openid` and an active stored authorization; **no** audience check (§6) |
| device-service `GET /devices/**`, STOMP `CONNECT`/`SUBSCRIBE` | `aud` ∋ device-api; any authenticated user AT (decision in `device#81`) |
| device-service `POST /devices/{id}/control` | `aud` ∋ device-api; role per **D4** (recommended `ADMIN`) |
| device-service `POST /devices`, `DELETE /devices/**` | `aud` ∋ device-api; `role=ADMIN` (`device#62`) |
| data-service `/api/netmon/**` | `aud` ∋ data-api; `SCOPE_netmon:read`; `sub` ∈ allowlist |

## 8. Compatibility and rollout order

The change is **backwards-compatible for every homelab resource server until step 3**, and **breaking** for any caller that lacks the new audience after step 3. Steps 2b and 2c are breaking for third-party apps that read `role` (O2). Each step is its own PR or config change and release, verified live before the next one starts.

| Step | Repo / PR | Change | Gate before the next step |
|---|---|---|---|
| 0 | `homelab` (this document) | Contract accepted; owner decisions D1–D6 recorded | owner merge |
| 1 (recommended, not required) | `auth#102` + furchert-ch + data-service + `homelab` playbook 59 (owner: SOPS secret) | Dedicated `furchert-ch-netmon` client; furchert-ch switches its netmon token; data-service allowlist `[furchert-ch, furchert-ch-netmon]`, then `[furchert-ch-netmon]`; finally a Flyway migration removes `client_credentials` and `netmon:read` from `furchert-ch` | `/dashboard/network` works with the new client |
| 2a | auth-service (producer A) | §5 keys and audience behaviour: `aud` and `client_id` for first-party clients (§4.1). `first-party` and `release-role-claim` stay at their defaults (`true`), and `access-token-type` stays `default`. Additive: no consumer checks `aud` yet. Update auth-service `INTERFACES.md` (§1 token claims, §3 "aud = your client ID" guidance, §4) to summarise and link this document | live: decode a fresh furchert-ch user token, its netmon token and the data-service token (shape as in §4.1); `/dashboard/auth`, `/dashboard/network`, LiteLLM SSO login, login-event pull, and both MCP connectors still work. **Wait ≥ 20 min** (15 min AT lifetime + skew; furchert-ch and data-service cache tokens only until `exp − 60 s`) so no old-shape token is in flight |
| 2b | auth-service (config) | `first-party: false` for `grafana`, `homeassistant`, `n8n`, `litellm`, and for `device-service`'s SSO grant. **Breaking for any app that reads `role` from its AT** (O2) | LiteLLM SSO login still works and still maps the admin; other apps per O2 |
| 2c | auth-service (config, D2) | `release-role-claim` per D2. **Breaking for apps that map roles from the ID token or `/userinfo`** (O2, D3) | as 2b; Grafana per D3 when `#159` is live |
| 3a | auth-service | `/api/v1/**` gets its own decoder (§6.1): `auth-api` required, transition `typ` set accepted. G2 rewritten to "rejected by audience", with the positive control re-signed **with** `aud` ∋ auth-api | `/dashboard/auth` lists users; the data-service login-event collector succeeds; a third-party AT gets 401 on `/api/v1/users/{id}` (integration test, plus one live check with a LiteLLM SSO session's token if the owner wants it) |
| 3b | device-service (`device#81`) | §6.2; G5 rewritten likewise | device-service starts; a third-party, ID or hub-shaped token is refused (tests); Swagger SSO login still works |
| 3c | data-service (`data#25`) | §6.3 | `/dashboard/network` loads |
| 4 | auth-service (producer B) | `app.oidc.access-token-type: at+jwt`. The shared decoder accepts `at+jwt` for `/userinfo` (the exception in §6). Tests: `/userinfo` with an `at+jwt` OIDC AT → 200; hub- and club-shaped tokens → not 200. `ExistingClientsUnchangedGateTest` and spec 080 G4 ("never `at+jwt`") inverted deliberately | all checks of step 2a again with `typ: at+jwt`, plus the device-service Swagger SSO login and the LiteLLM SSO login, both of which call `/userinfo` |
| 5 | consumers (optional, ≥ 30 days after step 4) | Drop absent/`JWT` from the accepted `typ` set | — |

3a, 3b and 3c may run in parallel once step 2a is live. 2b and 2c are independent of step 3 and can wait for O2.

**Rollback (always newest step first):**
- Step 4: revert it first. Consumers accept both `typ` values, so this breaks nothing.
- Step 3x: revert that consumer, but only after step 4 has been reverted. With step 4 live, a reverted consumer would refuse `at+jwt` again.
- Steps 2b and 2c: revert the config.
- Step 2a: revert only after every step-3 consumer has been reverted, because enforcing consumers need the new `aud`.

**Docs to update with the steps:**
- auth-service `INTERFACES.md` (2a, 2b, 2c, 3a, 4)
- device-service `INTERFACES.md` (3b)
- data-service `INTERFACES.md` (3c)
- spec 060 §7.5: the `aud=furchert-ch` sentence (2a), and the deferred furchert-ch#43 rule "`ROLE_ADMIN` and `aud` contains `furchert-ch`", which becomes `data-api` (3c)
- spec 080 §4.5: the "Other components…" bullets including `/userinfo` (3a, 4), the G2/G5 rows (3a, 3b), the G4 row (2a: `aud`/`client_id`; 4: `typ`), the follow-up bullets (as steps land)
- this document's status line after each step

## 9. Required tests

- **auth-service:**
  - token-shape tests per client class of §4.1, through the real authorization-code and `client_credentials` flows;
  - **a refresh test per client class**, which also guards the mutable-list rule of §5.2;
  - a test that `aud` ignores a `resource` parameter for clients without `allowed-resources`;
  - startup failure for each rule of §5.1 "Startup validation", including a colon scope key written without brackets;
  - `ExistingClientsUnchangedGateTest` rewritten **deliberately**: in 2a furchert-ch `aud` becomes `[auth-api]`, a `client_id` claim appears, and `role` stays; in step 4 the `typ` assertion is inverted;
  - G2 per §8 step 3a;
  - `/userinfo`: a third-party AT → 200; in step 4 an `at+jwt` OIDC AT → 200; hub- and club-shaped tokens → not 200;
  - an ADMIN third-party AT gets 401 on `/api/v1/users/{id}`.
- **device-service:**
  - G5 per §8 step 3b;
  - wrong `iss` → 401; missing `device-api` → 401;
  - ID token (`azp`) → 401; IoT device token → 401;
  - USER on control → 403 (if D4 = ADMIN);
  - with the §6.4 switch empty, `at+jwt` is still refused.
- **data-service:**
  - missing or wrong `aud` → 401, with a real RS256 token against `support/TestJwks` (`data#25` acceptance);
  - `at+jwt` with `data-api` → 200; `at+jwt` with a hub audience → 401.
- **mcp-hub:** unchanged; its contract tests keep passing.

## 10. Owner decisions

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Form of the audience identifiers | (a) URL-style as in §3, consistent with the RFC 8707 values already used for the MCP servers; (b) logical names (`homelab:auth-api`, …) | (a). `data-api` gets a reserved `https://data.furchert.ch` identifier with no DNS record |
| D2 | `role` in ID tokens and `/userinfo` for third-party apps | (a) keep it for every client (today); (b) per-client opt-in `release-role-claim`; (c) drop it for all third-party clients | (b): least privilege, and Grafana can still opt in |
| D3 | Grafana role mapping (`#159`) | (a) `role_attribute_path` on the `/userinfo` `role` claim (needs D2 = a or b with `grafana` opted in); (b) Grafana-local roles: no IdP role, `auto_assign_org_role: Viewer`, the admin promoted inside Grafana | (a) with the opt-in. One place (auth-service) decides who is Grafana Admin |
| D4 | Role for `POST /devices/{id}/control` (`device#81`) | `ADMIN` only, or `USER` and `ADMIN` | `ADMIN` only |
| D5 | Do `#102` (dedicated netmon client) before `data#25` | Required by the scope map? No. Recommended? Yes: it separates the netmon secret from the SSO client | do it before step 3c |
| D6 | How furchert-ch gets a device-service token for the device GUI (`furchert-ch#45`) | (a) add `device-api` to furchert-ch's user ATs (one multi-audience token, `role=ADMIN`, replayable from device-service against the auth admin API); (b) one token per resource: a refresh with an RFC 8707 `resource` per audience, which needs `allowed-resources` support for first-party clients | (b) if `#45` sends tokens from the browser (STOMP); (a) is acceptable if the tokens stay server-side in furchert-ch. Decide with `#45`; until then `[auth-api]` only |

## 11. Open questions (not decided here)

- O1: Does anything besides the planned furchert-ch device GUI call device-service with a bearer token today (STOMP clients, scripts)? Check device-service logs before 3b.
- O2: before steps 2b and 2c, confirm per third-party app where it reads roles from:
  - LiteLLM: generic SSO; `/userinfo` only?
  - Home Assistant: OIDC is not tunnelled today.
  - n8n: CE has no OIDC, so probably unused.
  - Grafana: `#159`, not live.

  The owner checks UI-only configuration (O20 in spec 080).
- O3: Should third-party ATs get an explicit `aud` (e.g. a `userinfo` audience) instead of the client id? Not needed for safety (§4.1 notes); left as is to keep the diff small.
- O4: The IoT device token shape and the `mqtt` audience value belong to `#122` / spec 053.

## 12. Out of scope

- Mosquitto JWT authentication (`#122`) and device tokens.
- Rate limiting (`auth#104`), second factor (`auth#108`).
- External API clients and their scopes (Epic `#34`, `auth#54`–`#56`). They should be re-derived from this registry when a consumer exists.
