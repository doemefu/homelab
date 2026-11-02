# 054 — Access-Token Contract: Resource Audiences, Typed Tokens, `role` for First-Party Clients Only

**Status:** Draft for the owner (2026-11-03). Owner decisions D1–D5 in §10 are open. Nothing is implemented from this document yet.
**Tracking:** `doemefu/homelab-auth-service#101` (umbrella), children `doemefu/homelab-device-service#81`, `doemefu/homelab-data-service#25`; related `doemefu/homelab-auth-service#102` (dedicated netmon client), `doemefu/homelab#159` (Grafana OIDC), `doemefu/homelab#122` (Mosquitto auth), Epic `doemefu/homelab#152`
**Producer:** `homelab-auth-service`. **Consumers:** `homelab-auth-service` (`/api/v1/**`, `/userinfo`), `homelab-device-service`, `homelab-data-service`, `furchert-ch` (caller only), `homelab-mcp-hub` and the club MCP server (unchanged).
**Builds on:** spec 080 §4.2 (audience-bound hub tokens) and §4.5 (go-live gate and the **binding ordering constraint** on `#101`/`#81`), ADR 0003. Supersedes the token sketch in `052-architecture-target.md` § "Authentication Flow", which predates Spring Authorization Server.

---

## 1. Problem

auth-service signs every access token with the same key. Most resource servers check only the signature and the timestamps:

| Resource server | Checks today (origin/main, 2026-11-03) | Gap |
|---|---|---|
| auth-service `/api/v1/**` | signature, `exp`/`nbf`, `typ` ∈ {absent, `JWT`} (default validators), no `azp` (ID tokens rejected, PR #117) | no `aud`, no `iss` check: an ADMIN's access token issued to **any** client (n8n, LiteLLM, Grafana, Home Assistant) is accepted as ADMIN |
| device-service `/devices/**`, STOMP `CONNECT` | signature, `exp`/`nbf`, `typ` ∈ {absent, `JWT`} | no `iss`, no `aud`, no role check: any valid token, including a USER's, can call `POST /devices/{id}/control` |
| data-service `/api/netmon/**` | signature, `exp`/`nbf`, `iss`, `sub` allowlist, `SCOPE_netmon:read` | no `aud` |
| mcp-hub, club MCP server | `typ` ∈ {`at+jwt`, `application/at+jwt`}, exact `aud`, `client_id`, scopes, subject allowlist | none (reference shape) |

Two more problems:
- `role` is in the access token of every user-driven grant, including those of third-party apps. Those apps never need it in the access token.
- Today the only thing keeping the hub and club tokens out of `/api/v1/**` and device-service is that both reject `typ: at+jwt` (spec 080 §4.5).

## 2. Terms

- **Resource audience:** an identifier of one resource server, carried in `aud`. Section 3 is the registry.
- **First-party client:** a client whose code lives in a homelab repo and which calls homelab resource servers: `furchert-ch`, `device-service`, `data-service`. The machine clients `furchert-ch-netmon` (after `auth#102`) and the IoT device clients are first-party too.
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

| Client (grant) | `aud` | `client_id` claim | `role` | `scope` | header `typ` (step 2 → step 4) |
|---|---|---|---|---|---|
| `furchert-ch` (authorization_code / refresh) | `[auth-api, device-api]` | `furchert-ch` | yes | as granted | absent/`JWT` → `at+jwt` |
| `furchert-ch` (client_credentials, `netmon:read`) — until `#102` removes the grant | `[data-api]` (from the scope map, §5.2) | `furchert-ch` | no | `netmon:read` | same |
| `furchert-ch-netmon` (client_credentials; after `#102`) | `[data-api]` | `furchert-ch-netmon` | no | `netmon:read` | same |
| `device-service` (authorization_code / refresh, its own admin SSO) | `[device-api]` | `device-service` | yes | as granted | same |
| `device-service` (client_credentials, `clients:admin`) | `[auth-api]` | `device-service` | no | `clients:admin` | same |
| `data-service` (client_credentials, `login-events:read`) | `[auth-api]` | `data-service` | no | `login-events:read` | same |
| `grafana`, `homeassistant`, `n8n`, `litellm` (authorization_code / refresh) | unchanged: the client id (no resource audience) | client id | **no** | as granted | same |
| `claude-mcp-hub`, `claude-club-mcp` | unchanged (spec 080 §4.2) | unchanged | no | unchanged | `at+jwt` (unchanged) |
| IoT device clients (client_credentials, `mqtt:*`) | unchanged: device client id | — | no | `mqtt:pub mqtt:sub` | unchanged; `#122` decides |

Notes:
- `aud` is always serialised as an array when it has more than one value. Consumers MUST accept both the string and the array form (RFC 7519).
- The `client_id` claim (RFC 9068 §2.2) is new for first-party and third-party ATs. It is additive. Consumers may use it, but this contract requires no consumer to.
- Third-party ATs keep `aud` = client id, so **no homelab resource server accepts them** after step 3, because none of them lists a client id as an audience.
- The netmon AT of client `furchert-ch` stops carrying `aud=furchert-ch`. Spec 060 §7.5's sentence about that `aud` changes with step 2.

### 4.2 ID tokens and `/userinfo`

- ID tokens keep `aud` = client id and `azp` (OIDC Core). Resource servers keep rejecting tokens that carry `azp`.
- `role` in ID tokens and in the `/userinfo` response: owner decision **D2** (§10). Recommended: a per-client opt-in, `release-role-claim: true`, set only for `furchert-ch`, `device-service` and `grafana` (if D3 picks the claim mapping). n8n, LiteLLM and Home Assistant would then no longer see `role` anywhere.

## 5. Producer contract (auth-service)

### 5.1 Configuration keys (`application.yaml`, no new environment variables, no secrets)

| Key | Type / default | Meaning |
|---|---|---|
| `app.oidc.resource-audiences` | map name → URI; default empty | The registry of §3: `auth-api`, `device-api`, `data-api` |
| `app.oidc.scope-audiences` | map scope → name; default empty | Audience derived from a granted scope for `client_credentials` (§5.2) |
| `app.oidc.clients[].resource-audiences` | list of names; default `[]` | Audiences for this client's user-driven ATs (§4.1). Empty = keep `aud` = client id |
| `app.oidc.clients[].first-party` | boolean; default `false` | `true` keeps `role` in this client's user-driven ATs; `false` drops it |
| `app.oidc.clients[].release-role-claim` | boolean; default `false` (D2) | `true` keeps `role` in this client's ID tokens and `/userinfo` |
| `app.oidc.access-token-type` | `JWT` \| `at+jwt`; default `JWT` | Header `typ` of every non-audience-bound AT; flipped to `at+jwt` in step 4 |
| `app.oidc.api-audience` | name; default `auth-api` | The audience `/api/v1/**` requires (§6.1) |

The existing keys `access-token-audience`, `allowed-resources` and the other audience-bound options (INTERFACES.md §2) are unchanged. A client MUST NOT have both `access-token-audience` and `resource-audiences`; startup fails if one does.

### 5.2 Behaviour

1. **User-driven grants** (authorization_code, refresh_token) of a client with a non-empty `resource-audiences` list:
   - `aud` = the resolved URIs, in configuration order;
   - a `client_id` claim is added;
   - `role` is kept only when `first-party: true`.
2. **`client_credentials`:**
   - `aud` = the set of audiences mapped from the **granted** scopes. Proposed map: `clients:admin` → `auth-api`, `login-events:read` → `auth-api`, `netmon:read` → `data-api`; `mqtt:pub` and `mqtt:sub` stay unmapped until `#122`.
   - If no granted scope is mapped, `aud` stays the client id (today's behaviour).
   - `client_id` is added for every client except IoT device clients, which keep today's shape including `device_id`.
3. **Third-party clients** (`first-party: false`, empty `resource-audiences`): `role` is removed from the AT and `client_id` is added. The ID token and `/userinfo` follow `release-role-claim`.
4. **Unknown names:** a `resource-audiences` entry or a `scope-audiences` value that is not in the registry fails startup (fail closed). An auth-service that fails to start is visible at once, whereas a silently missing audience would only show up as consumer 401s.
5. **Refresh:** a refreshed AT is shaped by the same rules, so tokens minted after the deploy get the new shape on their next refresh. Nothing is migrated in the database.
6. **Step 4:** `app.oidc.access-token-type: at+jwt` sets header `typ: at+jwt` on every AT except IoT device ATs (left to `#122`).

## 6. Consumer contract (validation)

Every homelab resource server MUST validate, in this order: signature (JWKS), `exp`/`nbf` (60 s skew), `iss` = `https://auth.furchert.ch`, no `azp`, `typ` within the accepted set, `aud` contains its own audience. Then it applies its authorization rules (§7).

Accepted `typ` (case-insensitive):

| Phase | Accepted |
|---|---|
| from step 3 until step 5 | absent, `JWT`, `at+jwt`, `application/at+jwt` |
| after step 5 (optional cleanup) | `at+jwt`, `application/at+jwt` |

**Binding (spec 080 §4.5):** a service that starts accepting `at+jwt` MUST, in the same release, require its own audience, so that `aud = https://mcp.furchert.ch/mcp` and `aud = https://club-mcp.furchert.ch/mcp` are refused. Its gate test (G2 for auth-service, G5 for device-service) MUST then assert rejection **by audience**, keeping the positive control. Requiring the service's own audience covers every other audience as well, so no deny-list is needed.

Failures give `401` with `WWW-Authenticate: Bearer error="invalid_token"` (Spring default). A missing role or scope gives `403`.

### 6.1 auth-service `/api/v1/**`

- Requires `aud` ∋ `app.oidc.api-audience` (`auth-api`) and `iss`; accepts the `typ` set above.
- The audience requirement applies to the `/api/v1/**` filter chain **only**. `/userinfo` (authorization-server chain) MUST keep accepting the ATs of every OIDC client: third-party clients included, `at+jwt` included from step 4, and without an `auth-api` audience. `/userinfo` validates against the stored authorization and the `openid` scope. If both chains share one `JwtDecoder` bean today, the API chain gets its own decoder or validator.
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
- Accepted callers after step 3: furchert-ch user ATs (device admin GUI, `furchert-ch#45`) and device-service's own SSO ATs. Before enforcing, confirm from the device-service logs that no other caller exists today.

### 6.3 data-service (`data#25`)

- `spring.security.oauth2.resourceserver.jwt.audiences` = `${JWT_AUDIENCE:<data-api>}`, composed with the existing issuer validator.
- `AllowedClientAuthorizationManager` (subject allowlist) and `SCOPE_netmon:read` stay as they are.
- After `#102`, `netmon.api.allowed-clients` changes to `[furchert-ch-netmon]` in the same data-service release that the furchert-ch switch depends on (order in §8).

### 6.4 Shipping a validator disabled-by-config

A consumer MAY merge its validator before the producer step is live, provided enforcement is off while its audience property is empty. If it does, it MUST log one WARN at startup while enforcement is off, and the enforcing change (setting the value in `application.yaml` or `k8s/deployment.yaml`) is the step-3 change for that consumer.

## 7. Authorization per operation (after step 3)

| Service / operation | Requires |
|---|---|
| auth-service `GET /api/v1/users/{id}` | `aud` ∋ auth-api; own record or `role=ADMIN` (unchanged) |
| auth-service other `/api/v1/users/**` | `aud` ∋ auth-api; `role=ADMIN` |
| auth-service `/api/v1/clients/**` | `aud` ∋ auth-api; `role=ADMIN` or `SCOPE_clients:admin` |
| auth-service `GET /api/v1/login-events` | `aud` ∋ auth-api; `SCOPE_login-events:read` only |
| device-service `GET /devices/**`, STOMP `CONNECT`/`SUBSCRIBE` | `aud` ∋ device-api; any authenticated user AT (decision in `device#81`) |
| device-service `POST /devices/{id}/control` | `aud` ∋ device-api; role per **D4** (recommended `ADMIN`) |
| device-service `POST /devices`, `DELETE /devices/**` | `aud` ∋ device-api; `role=ADMIN` (`device#62`) |
| data-service `/api/netmon/**` | `aud` ∋ data-api; `SCOPE_netmon:read`; `sub` ∈ allowlist |

## 8. Compatibility and rollout order

The change is **backwards-compatible for every consumer until step 3**, and **breaking** for any caller that lacks the new audience after step 3. Each step is its own PR and release, verified live before the next one starts.

| Step | Repo / PR | Change | Gate before the next step |
|---|---|---|---|
| 0 | `homelab` (this document) | Contract accepted; owner decisions D1–D5 recorded | owner merge |
| 1 (recommended, not required) | `auth#102` + furchert-ch + data-service + `homelab` playbook 59 (owner: SOPS secret) | Dedicated `furchert-ch-netmon` client; furchert-ch switches its netmon token; data-service allowlist `[furchert-ch, furchert-ch-netmon]`, then `[furchert-ch-netmon]`; finally a Flyway migration removes `client_credentials` and `netmon:read` from `furchert-ch` | `/dashboard/network` works with the new client |
| 2 | auth-service (producer A) | §5 keys and behaviour; `access-token-type` stays `JWT`. Additive: no consumer checks `aud` yet. Update auth-service `INTERFACES.md` (§1 token claims, §3 "aud = your client ID" guidance, §4) to summarise and link this document | live: decode a fresh furchert-ch, data-service and device-service token (shape as in §4.1); `/dashboard/auth`, `/dashboard/network`, LiteLLM SSO login, login-event pull, and both MCP connectors still work. **Wait ≥ 20 min** (15 min AT lifetime + skew) so no old-shape token is in flight |
| 3a | auth-service | `/api/v1/**` requires `auth-api`; accepts the transition `typ` set; G2 rewritten to "rejected by audience" with the positive control re-signed **with** `aud` ∋ auth-api | `/dashboard/auth` lists users; the data-service login-event collector succeeds; a third-party AT gets 401 on `/api/v1/users/{id}` (integration test, plus one live check with a LiteLLM SSO session's token if the owner wants it) |
| 3b | device-service (`device#81`) | §6.2; G5 rewritten likewise | device-service starts; a furchert-ch AT is accepted and a third-party or hub-shaped token is refused (tests) |
| 3c | data-service (`data#25`) | §6.3 | `/dashboard/network` loads |
| 4 | auth-service (producer B) | `app.oidc.access-token-type: at+jwt`. `/userinfo` must accept `at+jwt` (test required in this PR) | all checks of step 2 again, with `typ: at+jwt` |
| 5 | consumers (optional, ≥ 30 days after step 4) | Drop absent/`JWT` from the accepted `typ` set | — |

3a, 3b and 3c may run in parallel once step 2 is live.

**Rollback:**
- Steps 2 and 4: revert the auth-service change. Consumers accept both shapes, so a revert breaks nothing.
- Step 3x: revert that consumer.
- After step 3, reverting step 2 alone breaks every enforcing consumer. Revert the consumers first.

**Docs to update with the steps:**
- auth-service `INTERFACES.md` (step 2, step 3a)
- device-service `INTERFACES.md` (3b)
- data-service `INTERFACES.md` and spec 060 §7.5 (step 2, 3c)
- spec 080 §4.5 "Other components…" and the G2/G5 rows (3a, 3b)
- this document's status line after each step

## 9. Required tests

- **auth-service:**
  - token-shape tests per client class of §4.1, through the real authorization-code and `client_credentials` flows;
  - startup failure on an unknown audience name;
  - `ExistingClientsUnchangedGateTest` rewritten **deliberately**: furchert-ch `aud` becomes `[auth-api, device-api]`, a `client_id` claim appears, `role` stays;
  - G2 per §8 step 3a;
  - `/userinfo` with a third-party AT (200) and, in step 4, with an `at+jwt` AT (200);
  - an ADMIN third-party AT gets 401 on `/api/v1/users/{id}`.
- **device-service:** G5 per §8 step 3b; wrong `iss` → 401; missing `device-api` → 401; ID token → 401; USER on control → 403 (if D4 = ADMIN).
- **data-service:** missing or wrong `aud` → 401 with a real RS256 token against `support/TestJwks` (`data#25` acceptance).
- **mcp-hub:** unchanged; its contract tests keep passing.

## 10. Owner decisions

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Form of the audience identifiers | (a) URL-style as in §3, consistent with the RFC 8707 values already used for the MCP servers; (b) logical names (`homelab:auth-api`, …) | (a). `data-api` gets a reserved `https://data.furchert.ch` identifier with no DNS record |
| D2 | `role` in ID tokens and `/userinfo` for third-party apps | (a) keep it for every client (today); (b) per-client opt-in `release-role-claim`; (c) drop it for all third-party clients | (b): least privilege, and Grafana can still opt in |
| D3 | Grafana role mapping (`#159`) | (a) `role_attribute_path` on the `/userinfo` `role` claim (needs D2 = a or b with `grafana` opted in); (b) Grafana-local roles: no IdP role, `auto_assign_org_role: Viewer`, the admin promoted inside Grafana | (a) with the opt-in. One place (auth-service) decides who is Grafana Admin |
| D4 | Role for `POST /devices/{id}/control` (`device#81`) | `ADMIN` only, or `USER` and `ADMIN` | `ADMIN` only |
| D5 | Do `#102` (dedicated netmon client) before `data#25` | Required by the scope map? No. Recommended? Yes: it separates the netmon secret from the SSO client | do it before step 3c |

## 11. Open questions (not decided here)

- O1: Does anything besides the planned furchert-ch device GUI call device-service with a bearer token today (STOMP clients, scripts)? Check device-service logs before 3b.
- O2: LiteLLM SSO reads `/userinfo` only. Confirm that its generic OIDC integration does not decode the access token for `role` before step 2 removes `role` from the LiteLLM AT. The owner checks the LiteLLM UI config (O20 in spec 080).
- O3: Should third-party ATs get an explicit `aud` (e.g. a `userinfo` audience) instead of the client id? Not needed for safety (§4.1 notes); left as is to keep the diff small.
- O4: The IoT device token shape and the `mqtt` audience value belong to `#122` / spec 053.

## 12. Out of scope

- Mosquitto JWT authentication (`#122`) and device tokens.
- Rate limiting (`auth#104`), second factor (`auth#108`).
- External API clients and their scopes (Epic `#34`, `auth#54`–`#56`). They should be re-derived from this registry when a consumer exists.
