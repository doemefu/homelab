# Fleet invariants

Rules that every homelab service must keep, whichever repository it lives in. Each entry names the
services it applies to, how each one enforces it, and the test that guards it. A change that adds or
alters a service in scope must keep the entry true and update it in the same change.

---

## INV-LOGOUT-1: an ID token is a bearer token nowhere in the fleet

**Rule.** No resource server accepts an ID token issued by auth-service as a bearer token. The only
sanctioned use of an ID token is `id_token_hint` at auth-service's `/connect/logout`.

**Why it matters.** furchert-ch puts the ID token into the logout redirect (`id_token_hint`), so it can
appear in browser history and logs for up to its 30-minute lifetime. An ID token is a JWT signed by
auth-service's key and carries the `role` claim. A resource server that checked only signature, issuer
and expiry would accept it like an access token. The logout design is safe only while this invariant
holds (furchert-ch `DEPLOYMENT.md` "Invariant & prerequisites (#199)", doemefu/furchert-ch#199).

**How an ID token is recognised.** Spring Authorization Server sets the `azp` claim only on ID tokens,
never on access tokens. Resource servers that require `typ: at+jwt` reject ID tokens through that gate
instead, because ID tokens carry no `typ`.

**Enforcement and guard per resource server** (every service that trusts auth-service's JWKS):

| Resource server | Repository | Enforcement | Guard test |
|---|---|---|---|
| auth-service `/api/v1/**` | doemefu/homelab-auth-service | `IdTokenRejectingValidator` on the bearer decoder: a token with `azp` → 401 (#117) | `IdTokenRejectingValidatorTest.rejectsIdTokens`, `JwtDecoderIdTokenTest.rejectsAnIdTokenWithTheSameSignatureAndRole`, `IdTokenBearerRejectionTest` |
| device-service REST and STOMP `CONNECT` | doemefu/homelab-device-service | `azp`-rejecting validator on the auto-configured decoder → 401 (#115); also `aud` = `furchert-ch` (#124) | `DeviceAuthorizationTest.idToken_isUnauthorized` |
| data-service `/api/netmon/**`, `/api/webanalytics/**` | doemefu/homelab-data-service | Today: scope plus client allowlist → 403 (an ID token has no `scope`). With doemefu/homelab-data-service#77: `azp`-rejecting decoder validator → 401 before authorization | With #77: `IdTokenRejectingValidatorTest`, `IdTokenRejectionIntegrationTest` |
| mcp-hub `/mcp` | doemefu/homelab-mcp-hub | `typ` must be `at+jwt`, own audience and own `client_id` (`_verify` in `src/mcp_hub/auth.py`) → 401 | `tests/unit/test_verifier.py` (the `typ` / audience / `client_id` rejection cases) |
| club-mcp | club-assistant repository (local only; deployed by this repo, `cluster/apps/club-mcp/`) | `typ` must be `at+jwt`, exact audience, `client_id` `claude-club-mcp` (`club_mcp/auth.py`) → 401 | **Not verified** in this repository. Owner check: the club-assistant tests must include an ID-token-shaped token that is rejected |

**Not in scope today.**
- furchert-ch validates no bearer tokens (it is an OIDC relying party and calls the services above).
- The Mosquitto broker accepts no tokens. The chosen device route is static per-device passwords
  (homelab#122, route 2b). If a token-based MQTT route is ever adopted, its verifier joins this table
  with an `azp` rejection and a guard test before it is exposed.
- Third-party relying parties (LiteLLM, Open WebUI, n8n, Grafana, Home Assistant) accept no inbound
  auth-service bearer tokens.

**Rule for changes.** A new or changed resource-server decoder ships the guard (an ID-token-shaped token,
signed by the issuer's test key, with `azp`, a `role` and a valid audience, must get 401) **before** its
API is exposed through the tunnel. Remove a row only together with the service.

**Related.** Audience binding of access tokens: doemefu/homelab-auth-service#101 (resource audiences) and
the interim checks above. Logout design: furchert-ch `src/app/api/federated-logout/route.ts`.
