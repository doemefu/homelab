# 100 — First-Party Web Analytics for furchert.ch: Cross-Repo Contract

> Canonical copy (infrastructure repo). The parent workspace file `docs/100-web-analytics.md` forwards here (since homelab#349, WA-0). Relative `adr/` links resolve to `docs/adr/` in this repo. The specialist reports behind §15 are local-only and not part of this repo.

**Status:** Accepted (rev 3.4, owner approval of rev 3.1 2026-11-08; rev 3.2 to 3.4 = review clarifications); committed in WA-0 (homelab#349). Specialist reports folded in (§15); plan review, re-review and the CodeRabbit design review of homelab PR #353 applied; all owner answers of 2026-11-08 applied, including the delivery rule "value first, compliance and hardening late, go-live last" (§18). No open owner question.
**Epic:** `doemefu/homelab#348` · **Parent worklog:** `20261108-163648-web-analytics-epic-caea` (local-only)
**Canonical location:** this file (`infrastructure/docs/100-web-analytics.md`). The parent workspace file `docs/100-web-analytics.md` is a forwarder (since `homelab#349`), following the `060` precedent.
**ADR:** none new. [ADR 0002](adr/0002-network-telemetry-ownership.md) decisions 1 and 2 cover this (analytical data plane; one store, one owner); the push write path is a recorded exception to its decision 3 (§1.4); ADR 0002 carries the dated amendment of 2026-11-08 (WA-0).
**Conventions:** "(assumption)" = a design choice the implementer may revisit in its plan. "Verify in phase 1" = a fact the named WA issue confirms first and records in its child worklog. **"[WA-5]"** marks a part of the contract that is built in the late "Compliance & hardening" sub-project; everything else is built in the value sub-projects WA-0 to WA-4. The spec describes the go-live end state. JSON is camelCase; every listed field is always present (`null` when absent) unless marked optional. Flyway versions are always "the next free number at PR time" in data-service and auth-service; numbers below are today's expectation.

---

## 1. Purpose, decisions, principles

### 1.1 Purpose

Show the owner, in the ADMIN-only dashboard, how many people look at the offer, whether they read it, where they leave, what they click, where they come from, and how many send the contact form. Volume is tens to a few hundred consented visits per month, so every definition favours simplicity, robustness at small n and additivity over daily aggregates.

### 1.2 Binding decisions

| ID | Decision | Where |
|---|---|---|
| D1 | Own build, no new dependencies; Umami v3.4.1 reference only | §14 |
| D2 | All public pages except `/dashboard`, `/imprint`, `/privacy` | §3.3 |
| D3 | Clicks: CTAs, outbound, mailto/tel, navigation incl. language switch; no heatmaps | §3.6 |
| D4 | Goal: successful contact submission, fact only | §5.9 |
| D5 | Random visitor id, 12 months or until withdrawal | §4.2 |
| D6 | Raw 13 months, then only id-free daily aggregates (internal rule, not a public promise) | §7.7 |
| D7 | Referrer domain, UTM, country, device class, browser family, OS, rounded screen size, page locale | §3.8 |
| D8 | No tracking when signed in; "never track this browser" switch | §5.3, §9.3 |
| D9 | Opt-in bottom bar, equal buttons, privacy link, footer link | §10 |
| D10 | Nightly daily aggregates are enough | §7.5 |
| D11 | Everything in one pass before go-live | §17 |
| D12 | Native in `/dashboard`, ADMIN-only | §9 |
| K1 | JSON only; `fetch` with `keepalive` for every flush; no `text/plain`, no `sendBeacon` | §3.9, §5.3 |
| K2/K3 | Visitor id = server-set cookie `fa_vid` (HttpOnly, Secure, SameSite=Lax, Path=/, fixed expiry = consent date + 12 months); choice and opt-out in `localStorage`; contact goal recorded server-side | §4, §5.9 |
| K4 | 8 KiB body and 20 events per request (early); per-IP/global limits and 10 000/day, 2 500/hour cap [WA-5] | §5.8, §6.4 |
| K5 | No client session id; visits built in the rollup; ordering by `(pageviewId, seq)` | §3.2, §7.5 |
| K6 | Rollup slot checked against every scheduled job | §7.6 |
| Q1 | Owner: "Keine Fristen". Privacy text names no server retention period and no location; only the 12-month browser storage of cookie and choice | §10.2 |
| Q2 | Owner: "So lassen". Mac app-data dumps stay unchanged; erasure covers live data only and the privacy text never claims it reaches backups | §13 |
| Q3 | Owner: drafts of the local-only privacy report as adapted in §10 (final sign-off in WA-5) | §10 |
| Q4 | Owner: yes, consent-free per-day count of successful enquiries, no identifier, no content | §5.9, §13 |
| Q5 | Owner: no lawyer opinion now; revisit if EU traffic becomes material | §13.2 |
| Q6 | Owner: yes, UTM on the `/ki` and `/bau` redirects | §17 (WA-2b) |
| Q7 | Owner: full scope accepted ("mit AI sind wir schneller"); WA-3 and WA-4 split kept | §17 |
| O1 | Owner: "value first", then one late sub-project for all mandatory topics without direct value ("Pflichtthemen ohne echten Mehrwert"), then go-live as the very last step. The tracker stays dark until go-live, so the late order is safe | §17 |

### 1.3 Out of scope ("do not build")

Real-time or "active now"; heatmaps, session replay, rage/dead clicks, form-field analytics; A/B tests; bounce rate or average time on site as headline numbers; pages per visit, session duration, or unique visitors summed from daily rows; Sankey or journey graphs, cohort grids; multi-touch attribution, goal values; city/region, browser versions, exact screen sizes, browser language, hour or weekday heatmaps; Web Vitals; anomaly e-mails, CSV export of raw data; a visitor profile, user explorer, per-visitor timeline or list of converting visits; an id-free per-visit fact table (§7.8); anything that acts on the data in the page. The read API and the dashboard never expose a visitor id.

### 1.4 Principles

- **One store, one owner.** data-service owns DB `data_service`, new schema `webanalytics`. furchert-ch keeps only a bounded in-memory forward queue.
- **Nothing before consent**, with one explicit exception. Before a choice: zero requests to the collect route, zero storage writes (`setItem`; removing an expired or wrong-version `fa_consent` record is allowed, §4.2), no device-property reads, no "banner shown" ping. **Exception:** every Decline, including the automatic decline for GPC/DNT [WA-5], sends one data-free request to `POST /api/v/forget` (body `{}`); it carries no analytics data, only the `fa_vid` cookie if one exists, and its sole purpose is clearing the cookie and (from WA-5) erasing data (§4.4).
- **Minimise at the source.** Path without query or fragment; referrer host only; `utm_source`, `utm_medium`, `utm_campaign` only; viewport as 5 width buckets; browser and OS families without versions; country from `CF-IPCountry`; never the IP (not even hashed), never the raw User-Agent, never a mailto/tel target.
- **Aggregate-only analysis.** No per-visitor view anywhere; no join between netmon (IP data) and analytics beyond id-free per-path counts; raw analytics rows are never pasted or exported into AI tools.
- **Exception to ADR 0002 decision 3 (pull).** Browser events are pushed browser → furchert-ch → data-service. ADR 0002 carries a dated amendment (2026-11-08, WA-0).
- **At-most-once delivery.** Events queued in the browser or in furchert-ch are lost on tab close without flush or on pod restart (accepted).
- **Dark until go-live.** `ANALYTICS_UI_ENABLED = false` keeps bar, tracker, collect route and goal off until WA-6; that is what makes deferring compliance and hardening to WA-5 safe.
- **Enquiry counter live early, on purpose.** The id-free daily enquiry count (§5.9) depends only on `ANALYTICS_COLLECT_ENABLED`, not on `ANALYTICS_UI_ENABLED`, so it counts from the WA-2b rollout on. It involves no consent, cookie or personal data, and the extra months of history make the enquiry-coverage figure meaningful from go-live.

---

## 2. Topology

```
 Browser (consented)                      furchert-ch (ns apps, :3000, replicas 1)                   data-service (ns apps, :8082, replicas 1)
 ───────────────────                      ────────────────────────────────────────                   ─────────────────────────────────────────
 tracker chunk ──fetch keepalive, JSON───► POST /api/v          validate, drop, enrich, mint fa_vid
   (loaded only after Allow)               POST /api/v/forget   clear fa_vid; [WA-5] purge queue + synchronous erase
 contact form ──Server Action────────────► submitContact        on success: goal (consent) + enquiry count (always)
                                           ordered in-memory forward queue ──POST, Bearer analytics:write───► POST   /api/webanalytics/events
                                           forget handler ──DELETE [WA-5], awaited───────────────────────────► DELETE /api/webanalytics/visitors/{id}
                                                                                                                │ dedupe; [WA-5] caps, tombstones
                                                                                                                ▼
                                                                                                     PostgreSQL data_service, schema webanalytics
                                                                                                     netmon.inbound_request_groups ─► daily CF baseline
                                                                                                                ▲ rollup 01:12 (provisional) + 07:30 (final), Europe/Zurich
 Admin ──► /[locale]/dashboard/analytics (SSR, ADMIN) ──GET, Bearer analytics:read─────────────────────────► GET /api/webanalytics/*
 Alerts: NetmonCollectorStale daily class (WA-3a) + 5 WebAnalytics* rules [WA-5] + IngestSilent (WA-6) ─► Alertmanager ─► Discord
```

| Endpoint | Reachable from | Used by |
|---|---|---|
| `https://furchert.ch/api/v`, `/api/v/forget` | Internet via the existing `furchert.ch` tunnel route | furchert-ch's own client code only |
| `http://data-service.apps.svc.cluster.local:8082/api/webanalytics/*` | cluster-internal; existing NetworkPolicy admits only furchert-ch and Prometheus | furchert-ch server only |
| `http://auth-service.apps.svc.cluster.local:8080/oauth2/token` | cluster-internal | furchert-ch (tokens) |

No new tunnel route, hostname, NetworkPolicy, SOPS variable or Secret key.

---

## 3. Measurement model (furchert-ch client)

### 3.1 Terms

| Term | Definition |
|---|---|
| Visitor | One `fa_vid` cookie value. A lower bound of real people. The UI says "browsers" in tooltips. |
| Visit | Events of one visitor with no gap > 30 min; a landing pageview with an external referrer or any UTM value also starts a new visit. Built in the rollup, attributed to the Europe/Zurich day of its first pageview, capped at 6 h of span. |
| Pageview | One per distinct route render after consent (§3.4). |
| Offer visit | Visit with ≥ 1 pageview of `/automation` or `/it`. |
| Contact intent | Visit with a `cta` click, a `mailto` or `tel` click, or a `/contact` pageview. |
| Conversion | `contact_submit`, recorded by the server after a successful send (§5.9). |
| Enquiry count | Consent-free daily integer of successful contact submissions (§5.9). |

### 3.2 Event types sent by the browser

| Type | Created when | Ordering key |
|---|---|---|
| `pageview` | §3.4 | new random `pageviewId`, `seq = 0` |
| `engagement` | cumulative snapshot of the open pageview (§3.5) | same `pageviewId`, `seq` 1..99 |
| `click` | delegated click capture (§3.6) | same `pageviewId`, `seq` 1..99 |

`(pageviewId, seq)` is unique. Pageviews are ordered within a visit by server-derived `occurredAt`, then `eventId`. No client session or visit id. The browser never sends a goal.

### 3.3 Tracked paths and registries

| Registry (furchert-ch) | Content | Rule |
|---|---|---|
| `TRACKED_PATHS` (`src/lib/analytics/paths.ts`) | keys of `PAGE_LAST_MODIFIED` minus `/imprint`, `/privacy` | test: full sitemap coverage except the legal pages, no `/dashboard` path |
| `NAV_TARGETS` | `TRACKED_PATHS` ∪ {`/imprint`, `/privacy`, `/dashboard`} | anything else becomes `(other)` |
| `TRACK_IDS` (`src/data/track-ids.ts`) | `cta`: exactly `FROM_IDS` plus new `about-contact`, `rowing-contact`; `link`: `home-hero-automation`, `home-hero-projects`, `home-tile-automation`, `home-tile-it`, `home-tile-projects`, `home-tile-rowing`, `it-automation`, `it-projects`, `about-projects`, `rowing-projects`, `automation-tile-example`, `automation-about-page`, `contact-automation`, `project-card-<slug>`, `project-back`; `faq`: the FAQ ids; `section`: §3.7 | ids `^[a-z0-9][a-z0-9-]{0,63}$`, total ≤ 100; source test for every `data-track` value |
| FAQ ids (`src/data/automation-faqs.ts`) | `cost`, `fit`, `buy-self`, `adoption`, `swiss-german`, `monitoring`, `data-ch`, `copilot-payroll`, `access`, `student-time` | never index or question text |

The redirects `/ki` and `/bau` (Q6) carry `utm_source=print&utm_medium=shortlink&utm_campaign=ki` and `utm_campaign=bau` respectively.

`/about` and `/rowing` switch to `contactHref('about-contact')` / `contactHref('rowing-contact')`.

### 3.4 Pageview rules

- Trigger: `usePathname()` from `next/navigation`; no `useSearchParams()`, no `history` patching.
- The first pageview waits for `useSession().status !== 'loading'`; nothing is sent while `authenticated`.
- One pageview per **locale-free path change**; locale-only switches, query-only and hash changes are not pageviews. Reloads of the same path within 30 s in one visit are merged in the rollup.
- **Landing:** the first pageview after the tracker starts in each document load has `landing = true`; later pageviews of that document load `false`. `referrerHost` = host of `document.referrer`, `null` if equal to `location.host`; UTM from `location.search`. Both read when that first pageview is built, never before consent.
- `pageshow` with `persisted = true`: new pageview with `landing = false`.

### 3.5 Engagement

| Item | Rule |
|---|---|
| Engaged | visible AND focused AND last activity ≤ 60 000 ms ago (`scroll`, `pointerdown`, `keydown`, `touchstart` passive capture; `pointermove` 1/s). Pageview start counts. Segment accumulator, `performance.now()`, no polling timer |
| `engagedMs` | cumulative per pageview, cap 1 800 000 |
| `scrollMax` | highest of {0, 25, 50, 75, 90, 100}, measured against the bottom of `<main>`, monotonic, reset after Next's scroll-to-top |
| `fits` | `<main>` fits the viewport at pageview start; excluded from scroll statistics |
| `sectionMask` | `/automation` only: bit i once section i's top edge was at or above 50 % of the viewport height while visible (0 `hero`, 1 `so-arbeite-ich`, 2 `beispiel`, 3 `preise`, 4 `daten`, 5 `ueber-mich`, 6 `faq`, 7 `final`; `data-track-section`) |
| `formStarted` | `/contact` only: first focus on any form field |
| Snapshots | soft navigation away, `hidden`, `pagehide`, before outbound/mailto/tel clicks, heartbeat every 60 s while engaged if `engagedMs` grew ≥ 10 s; max 20 per pageview |

### 3.6 Clicks

`click` plus `auxclick` (button 1) on `document`, capture phase, passive; no `preventDefault()`, no navigation delay.

| # | Match | `kind` | `target` |
|---|---|---|---|
| 1 | `data-track="cta:<id>"`, `"link:<id>"`, `"faq:<id>"` | `cta` / `link` / `faq` | the id (`faq` once per item per pageview, on open) |
| 2 | `data-track="lang:<de\|en>"` | `lang` | target locale |
| 3 | `a[href^="mailto:"]` | `mailto` | `null` |
| 4 | `a[href^="tel:"]` | `tel` | `null` |
| 5 | `a[href]` to another origin | `outbound` | hostname, lowercase, `www.` stripped |
| 6 | same-origin `a[href]` in `header`/`footer`/`nav` | `nav` | locale-free path |

`area` = `header`, `footer`, `main`. Cap 50 clicks per pageview. `Btn`, `CTAStrip`, `StickyCta`, `ContactEmail`, `Header`, `Footer` accept an optional `track` prop.

### 3.7 Section reach (`/automation`)

Order: `hero`, `so-arbeite-ich`, `beispiel`, `preise`, `daten`, `ueber-mich`, `faq`, `final`. Deepest section = highest bit in `sectionMask`.

### 3.8 Context

| Field | Source | Stored as |
|---|---|---|
| Path, locale | `usePathname()` | locale-free path + `de`/`en` |
| Referrer | §3.4 | `referrerDomain` |
| UTM | source, medium, campaign | normalised strings (§5.5) |
| Viewport | `window.innerWidth`, mapped in the browser | `<480`, `480-767`, `768-1023`, `1024-1439`, `>=1440` |
| Country | `CF-IPCountry` | ISO alpha-2 or `null` |
| Device class, browser family, OS family | `User-Agent`, `Sec-CH-UA-Mobile`, `Sec-CH-UA-Platform` | enums without versions (§5.7) |

### 3.9 Transport and client queue (K1)

| Item | Rule |
|---|---|
| Transport | `fetch('/api/v', {method: 'POST', keepalive: true, headers: {'Content-Type': 'application/json'}, credentials: 'same-origin', body, signal})` for every flush incl. `hidden`/`pagehide`; every request carries an `AbortController` signal so withdrawal can abort it (§4.4); no `sendBeacon` (an `application/json` Blob is restricted in Chrome, crbug 490015; `text/plain` excluded by K1) |
| Flush | ≥ 20 events; 10 s after the first queued event; `hidden`/`pagehide`; before outbound/mailto/tel clicks |
| Body | ≤ 7 680 bytes serialised; larger batches split |
| In flight | one request at a time per tab |
| First flush across tabs | the first flush after the tracker starts in a tab runs inside `navigator.locks.request('fa-first-flush', …)`, so first flushes of parallel tabs are serialised and only the first one can mint `fa_vid`; the next tab's request then carries the cookie. Without the Web Locks API (pre-2022 browsers) the flush runs unserialised and two tabs may mint two ids; the second `Set-Cookie` wins and the first id stays a one-request orphan. This is a documented data-quality limit (at most one extra visitor per browser, only at the moment of consent) |
| Landing flush | on tracker start and right after Accept the landing pageview is flushed immediately (this mints `fa_vid` early), not on the usual batching delay; the contact form's submit relies on it (§5.9) |
| Retry | network error or 5xx: re-queue, retry after 5 s, then 30 s, then drop; no retry on 4xx; 429 pauses flushing 60 s |
| Queue | max 100 events in memory; never persisted |
| Lifecycle | no `unload`/`beforeunload` listeners; listeners stay on `pagehide` |

### 3.10 Mounting, singletons, bundle

- `<Analytics />` (client) inside `<Providers>` in `src/app/[locale]/layout.tsx`, after `<Footer />`, outside `<main className="page-enter">`.
- Client tracker: module singleton; `start()` idempotent; unmount never stops it; withdrawal, opt-out or sign-in call `stop()`.
- **Server singletons:** forward queue, per-scope token caches and [WA-5] rate limiters on `globalThis[Symbol.for('furchert.analytics.<name>')]`, shared by `/api/v`, forget and the Server Action. Verify in phase 1 (WA-2b) with a production build.
- Budget (gzip, enforced by a post-build CI step in furchert-ch): the consent layer is async-only (nothing of it in the initial or prerendered bundle) in one controller chunk: controller ≤ 2.75 KB, bar ≤ 1.0 KB, privacy link ≤ 0.75 KB. The tracker is async-only, one chunk, loaded via dynamic `import()` after Allow: measured size + 10 %, at most 6 KB. Post-build check with `node:zlib`.
- Pure `.ts` modules with injected `window`/`document`/clock (vitest `node`). `navigator.webdriver === true` → tracker off (cheap, early).

---

## 4. Consent, identifiers and storage

### 4.1 Consent gate

| State | Bar | Tracker |
|---|---|---|
| No valid `fa_consent`, no GPC/DNT, no `fa_optout` | shown | off |
| `granted`, current version, < 12 months | hidden | on (unless signed in) |
| `denied`, valid | hidden | off |
| GPC (`navigator.globalPrivacyControl === true`) or DNT (`navigator.doNotTrack === '1'`), no stored choice [WA-5] | hidden; auto-decline: store `denied` (`by: "signal"`), call forget once | off |
| `fa_optout = "1"` | hidden | off |
| `/dashboard/**` | never shown | off |
| signed in | shown | off; server drops anyway |
| Esc on the bar | hidden until the next document load; nothing stored | off |

Until WA-5, a GPC/DNT browser simply sees the bar (dark launch: nobody sees it before go-live). An explicit Allow via footer settings overrides GPC/DNT.

### 4.2 Storage

| Key | Where | Value | Written | Removed |
|---|---|---|---|---|
| `fa_consent` | `localStorage` | `{"v": <int>, "choice": "granted" \| "denied", "by": "user" \| "signal", "at": "YYYY-MM-DD"}` | on Allow, Decline, [WA-5] signal | `at` + 12 months (fixed), version mismatch (the expired or wrong-version record may be removed before a choice), new choice |
| `fa_vid` | cookie, set only by the server | `<uuid v4>.<consent version>` | by `POST /api/v` when absent/stale, `cv` current and `consentDate` valid | `POST /api/v/forget`, expiry |
| `fa_forget` [WA-5] | cookie, set only by the server | one or two `<uuid v4>` values separated by `.` (a valid cookie octet that does not occur in a UUID): the ids whose erasure is still pending | by `POST /api/v/forget` when the erasure of at least one id could not be completed (503) | by the next successful forget (all listed ids deleted); `Max-Age` 30 days |
| `fa_optout` | `localStorage` | `"1"` | owner switch | the same switch |
| `fa_forget_pending` | `localStorage` | `"1"` | before a forget call | after forget answered 204, or when a pending-forget run before a new Allow or at load ended (§4.4) |

`fa_vid`: `HttpOnly; Secure; SameSite=Lax; Path=/; Expires=<consentDate + 365 d, 00:00 UTC>`; never sliding (`Set-Cookie` only on mint and clear); `Secure` omitted outside production. `Path=/` is required by the contact Server Action; the cookie therefore accompanies page requests to furchert-ch (never logged) and is visible to Cloudflare, already a listed processor. Server cookie rationale: Safari ITP deletes script-writable storage after 7 days without interaction; server-set first-party cookies are not covered. `fa_forget`: `HttpOnly; Secure; SameSite=Strict; Path=/api/v/forget; Max-Age=2592000`; it only ever reaches the forget route and exists only while an erasure is pending.

### 4.3 Consent version

Integer `ANALYTICS_CONSENT_VERSION` (start `1`) used by bar, `/api/v` and Server Action; bumped on any change to purpose, data categories, recipients or the usage-statistics privacy section.

### 4.4 Decline, withdrawal, opt-out

| Trigger | Client (early, WA-2a/2b) | Server early (WA-2b) | Server [WA-5] |
|---|---|---|---|
| Decline on the bar | store `denied`, set `fa_forget_pending`, `POST /api/v/forget` | expire `fa_vid` | plus: purge that id's queued events, wait for an in-flight batch, then delete synchronously (§5.4) |
| Withdrawal (Allow → Decline) | store `denied`; `stop()`; drop the client queue; **abort every in-flight `/api/v` request via its `AbortController`**; only then set `fa_forget_pending` and `POST /api/v/forget` | as above | as above |
| GPC/DNT auto-decline | — | — | client [WA-5]: store `denied` (`by: "signal"`), forget once |
| Owner switch on | set `fa_optout`, abort in-flight requests, forget | as above | as above |
| Forget failed (network error, 429 or 503) | `fa_forget_pending` stays; the next document load (or, after a 429, `Retry-After`) retries forget once, only with a stored `denied` choice or opt-out (with no stored choice it waits for the next choice, below) | — | 503 sets `fa_forget` so the retry still knows the id; 429 keeps `fa_vid` (§5.4) |

**Race with an in-flight first collect.** Withdrawal writes `denied` before anything else, so no new flush starts; it aborts in-flight requests, so their responses are discarded by the browser; and forget runs strictly after the abort. A `Set-Cookie: fa_vid` from a collect response that the browser had already processed before the abort is cleared again by the forget response, which arrives later, on every forget response except 429 and a network failure (there the pending-forget retry covers it). `/api/v` itself never mints when the envelope does not carry a current `cv` and a valid `consentDate` (§5.3 step 10 runs before step 12); the tracker only sends while the stored choice is `granted`, so a withdrawn or absent consent state never produces a request that could mint.

**Pending forget and re-consent (`fa_forget_pending`).** At document load: choice `granted` with the marker set → send one forget, await it, drop the marker whatever the answer, then start the tracker; "abandoned" means any answer other than 204 (a 429, 503 or network error does not block the tracker). No stored choice with the marker set → no network request before a choice (§1.4); the marker is kept and sent with the next choice (Decline sends its forget anyway; Allow runs the pending forget first and awaits it before the tracker starts). The timed retry runs only with a stored choice `denied` or while opted out, never before a choice and never while tracking is allowed. The pending forget therefore never erases the new consented events. If an Allow-triggered forget is abandoned (for example 503), `fa_forget` stays and nothing retries it until the next withdrawal or Decline; the old id then stays until that point or until raw retention removes it. After an abandoned 429 the same applies with `fa_vid` kept: the tracker starts on the same id whose erasure was requested, so the new consented events are recorded under it and its earlier events stay linked to it until the next withdrawal (accepted residual, R14).

**Residual risk (accepted, R13).** Aborting a browser request does not stop the server from finishing it, and a valid `cv`/`consentDate` does not prove that consent is still granted. An event from a collect that completes after abort and forget, or from a second tab's id minted without Web Locks (§3.9), can therefore end up under a pseudonymous id that the browser no longer holds. Such an orphan id is unlinkable to any person (never exposed, no join, aggregate-only analysis), expires with raw retention, and from WA-5 the tombstone rejects late events for an id that was erased. The forget response clears `fa_vid` again after the abort (every response except 429; after a network failure or 429 the `fa_forget_pending` retry does it), so a late collect `Set-Cookie` does not survive in the browser.

Erasure reaches live data only (§13). Id-free aggregates for days outside the 2-day recompute window keep that visitor's counts.

---

## 5. furchert-ch server

### 5.1 Endpoints

| Method + path | Purpose |
|---|---|
| `POST /api/v` | event batches (`src/app/api/v/route.ts`, `runtime = 'nodejs'`, `dynamic = 'force-dynamic'`) |
| `POST /api/v/forget` | expire `fa_vid`; [WA-5] purge queue and erase synchronously |

Neutral naming avoids generic filter tokens; no rotation or disguise. `/api` is disallowed in `robots.txt` and outside the intl proxy.

### 5.2 Request body of `POST /api/v`

```json
{ "v": 1, "cv": 1, "consentDate": "2026-11-08", "sentAt": 1762617600123, "viewport": "1024-1439",
  "events": [
    { "eventId": "e1…", "type": "pageview", "ts": 1762617600000, "pageviewId": "p1…", "seq": 0,
      "path": "/de/automation", "landing": true, "referrerHost": "www.google.com",
      "utmSource": "linkedin", "utmMedium": "social", "utmCampaign": "2026-11-ki" },
    { "eventId": "e2…", "type": "engagement", "ts": 1762617645000, "pageviewId": "p1…", "seq": 2,
      "path": "/de/automation", "engagedMs": 31000, "scrollMax": 75, "fits": false, "sectionMask": 11, "formStarted": false },
    { "eventId": "e3…", "type": "click", "ts": 1762617640000, "pageviewId": "p1…", "seq": 1,
      "path": "/de/automation", "kind": "cta", "target": "automation-hero", "area": "main" } ] }
```

Strict schema (unknown keys → 400), depth ≤ 3, strings ≤ 128 chars before normalisation (`path` ≤ 512 raw), integers finite and in range.

| Field | Applies to | Type | Null | Rule |
|---|---|---|---|---|
| `v` | envelope | int | no | `1` |
| `cv` | envelope | int | no | equals `ANALYTICS_CONSENT_VERSION`, else dropped (204) |
| `consentDate` | envelope | string | no | `YYYY-MM-DD`; valid iff `consentExpired(consentDate, today)` is false, i.e. an age of 0 to 364 days, plus 1 day of clock skew for future dates only (a date up to 1 day ahead is accepted); else dropped. `consentExpired()` is the single rule behind every "12 months" check (§4.1, §4.2, §5.9); the client can send for 1 to 2 days that the server drops (204 `consent`) near the anniversary, which is harmless |
| `sentAt` | envelope | int | no | client epoch ms |
| `viewport` | envelope | string | yes | one of 5 buckets |
| `events` | envelope | array | no | 1..20 |
| `eventId`, `pageviewId` | all | string | no | UUID v4 lowercase |
| `type` | all | string | no | `pageview`, `engagement`, `click` (others incl. `goal` → dropped) |
| `ts` | all | int | no | client epoch ms |
| `seq` | all | int | no | 0 for pageview, 1..99 otherwise |
| `path` | all | string | no | raw `location.pathname` |
| `landing` | pageview | bool | no | |
| `referrerHost`, `utmSource`, `utmMedium`, `utmCampaign` | pageview | string | yes | only when `landing` |
| `engagedMs` | engagement | int | no | 0..1 800 000 |
| `scrollMax` | engagement | int | no | 0, 25, 50, 75, 90, 100 |
| `fits`, `formStarted` | engagement | bool | no | |
| `sectionMask` | engagement | int | no | 0..255 |
| `kind` | click | string | no | `cta`, `link`, `faq`, `lang`, `nav`, `outbound`, `mailto`, `tel` |
| `target` | click | string | yes | `null` for `mailto`/`tel` |
| `area` | click | string | no | `header`, `footer`, `main` |

### 5.3 Processing order of `POST /api/v`

| Step | Check | Outcome | Built in |
|---|---|---|---|
| 1 | Only `POST` | 405 | WA-2b |
| 2 | C4 `Content-Type: application/json` | 415 | WA-2b |
| 3 | C4 `Sec-Fetch-Site: same-origin` when present; else `Origin` = `https://furchert.ch` (dev via env); both absent → reject | 403 | WA-2b |
| 4 | C1 `Content-Length` > 8 192 → reject unread; stream-read, abort at 8 192; 5 s deadline | 413 / 408 | WA-2b |
| 5 | Kill switches `ANALYTICS_UI_ENABLED`, `ANALYTICS_COLLECT_ENABLED` | 204 | WA-2b |
| 6 | C6 D8: cookie name starting with `__Secure-authjs.session-token` or `authjs.session-token` (presence only) | 204, `signed_in` | WA-2b |
| 7 | C6 bot list: UA empty, < 20 chars or §5.7 regex; `Sec-Purpose`/`Purpose: prefetch` | 204, `bot` | [WA-5] |
| 8 | C3 collect rate limits (§5.8); never applied to `/api/v/forget` | 429 + `Retry-After` | [WA-5] |
| 9 | C2 envelope schema | 400 | WA-2b |
| 10 | `cv`, `consentDate`; a request failing this step never reaches step 12, so it can never mint | 204, `consent` | WA-2b |
| 11 | C7/C8 per-event validation and canonicalisation; invalid events dropped alone | `invalid` / `path` | WA-2b |
| 12 | `fa_vid` read; mint when absent/malformed/stale; [WA-5] mint limit 5/h per key, over → request dropped (`mint_limited`) | — | WA-2b / [WA-5] |
| 13 | C10 enrichment (§5.6, §5.7) | — | WA-2b |
| 14 | C12 enqueue | overflow counted, 204 | WA-2b |
| 15 | C9 respond 204 empty, `Cache-Control: no-store` | | WA-2b |

All non-error outcomes are 204; error bodies empty. The only `Set-Cookie` headers are `fa_vid` mint/clear and [WA-5] `fa_forget` (C9 adapted for K2).

### 5.4 `POST /api/v/forget`

Steps 1 to 4 (body `{}`). **Never subject to the collect rate limits** (§5.8) and not affected by the signed-in drop or the kill switches (works with `ANALYTICS_COLLECT_ENABLED=false` and while signed in). Never mints `fa_vid`. Every response except 429 first clears the cookie (a 429 keeps `fa_vid`, see the own-limit rule below): `Set-Cookie: fa_vid=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax`.

- **Early (WA-2b):** only expires the cookie; always 204.
- **[WA-5] own limit:** 30 forget requests per key per minute (generous; a user clicks Decline a few times at most). Above it the response is **429 with `Retry-After`** and **keeps `fa_vid`** (nothing is cleared, nothing is deleted): the limit is keyed by IP, so another visitor behind the same NAT may have used the budget, and this visitor's erasure is then neither done nor pending. Tracking is already stopped client-side by the stored `denied` state, and the tracker keeps `fa_forget_pending` and retries forget on the next document load or after `Retry-After`, like the 503 path. "Clears the cookie first" therefore applies to every response except 429.
- **[WA-5] durable erasure:** the ids are taken from the cookies, never from the body: `fa_vid` and `fa_forget`; when both are present **both ids are erased** (`fa_forget` has `Path=/api/v/forget`, so the collect route never sees it). The handler purges those ids' events from the forward queue, waits until a batch currently in flight has completed (so no event of those ids can be sent afterwards), then calls `DELETE /api/webanalytics/visitors/{uuid}` **synchronously** with a bounded retry (3 attempts, 1 s apart, 3 s timeout each, ≤ 12 s in total) before answering. Worst case for one forget is about 22 s (≤ 10 s waiting for an in-flight batch, §5.10, plus ≤ 12 s of DELETE retries); the client sends forget with a keepalive `fetch` and never blocks the UI on it:
  - data-service answered 204 → respond 204 and clear `fa_forget` (`Max-Age=0`);
  - data-service unreachable or 5xx after the retries → respond **503** and set `fa_forget=<uuid>[.<uuid>]` (§4.2) holding only the ids not yet deleted (an id that was deleted is not retried), so the ids survive the cleared `fa_vid`; the tracker keeps `fa_forget_pending` in `localStorage` and retries forget once on the next document load.

### 5.5 Canonicalisation and allowlists (C7, C8; WA-2b)

| Output | Rule |
|---|---|
| `path`, `locale` | `new URL(path, origin)`; fragment and query dropped; `^/(de\|en)(/.*)?$` → locale + rest, trailing slash removed; must be in `TRACKED_PATHS`, else drop |
| `referrerDomain` | lowercase punycode host, `www.` stripped, `^[a-z0-9.-]{1,253}$`; furchert.ch hosts or non-http(s) → `null`; landing only |
| UTM values | NFKC, lowercase, trim, spaces → `_`; `^[a-z0-9._+-]{1,64}$`, no run of ≥ 6 digits, else dropped |
| click `target` | `cta`/`link`/`faq` in `TRACK_IDS`, else drop; `lang` `de`/`en`; `outbound` host rule; `mailto`/`tel` forced `null`; `nav` normalised, in `NAV_TARGETS` else `(other)` |
| Never kept | full URLs, other query parameters, fragments, click ids, mailto/tel values |

### 5.6 Time (C10)

`occurredAt = receivedAt − (sentAt − ts)` if `0 ≤ sentAt − ts ≤ 15 min`, else `receivedAt`. `ts`, `sentAt` not stored.

### 5.7 Server-side derivation (`ua.ts` WA-2b; `bots.ts` [WA-5])

| Field | Rules (first match wins) |
|---|---|
| Bot [WA-5] | empty UA, < 20 chars, or `/bot\|crawl\|spider\|slurp\|scrap\|fetch\|preview\|monitor\|uptime\|headless\|lighthouse\|pagespeed\|gtmetrix\|phantom\|selenium\|playwright\|puppeteer\|curl\|wget\|python\|httpx\|axios\|go-http\|java\/\|okhttp\|node-fetch\|undici\|libwww\|feed\|facebookexternalhit\|embedly\|whatsapp\|telegram\|discord\|slack\|bingpreview/i` |
| `browserFamily` | `Edg/`, `EdgA/`, `EdgiOS/` → `edge`; `OPR/`, `Opera`, `SamsungBrowser` → `other`; `Firefox/`, `FxiOS` → `firefox`; `CriOS`, `Chrome/`, `Chromium` → `chrome`; `Version/…Safari/` → `safari`; else `other` |
| `osFamily` | `iPhone`, `iPod`, `iPad` → `ios`; `Android` → `android`; `Windows` → `windows`; `Macintosh` → `macos`; `CrOS`, `Linux` → `linux`; else `other`; `Sec-CH-UA-Platform` wins |
| `deviceClass` | `Sec-CH-UA-Mobile: ?1`, `Mobi`, `iPhone`, `iPod` → `mobile`; `iPad`, `Tablet`, `Android` without `Mobile` → `tablet`; desktop OS → `desktop`; else `other` |
| `country` | `CF-IPCountry` if `^[A-Z]{2}$` and not `XX`/`T1`, else `null` |

Raw UA and IP discarded after the request. Before WA-5, crawlers are filtered by consent itself (they do not click Allow) and by `navigator.webdriver`.

### 5.8 Rate limits, mint limit [WA-5]

In-process sliding windows (contact limiter pattern; valid with `replicas: 1`; with N replicas divide by N or use a shared store). Key = `CF-Connecting-IP`, IPv6 /64, memory only. The collect limits and the forget limit are separate limiter instances; forget never consumes or checks the collect budget.

| Window | Applies to | Limit |
|---|---|---|
| per key | `/api/v` | 20 requests / 60 s **and** 200 events / 10 min |
| per key, `fa_vid` mints | `/api/v` | 5 / hour |
| global | `/api/v` | 300 requests / 60 s **and** 2 000 events / 60 s |
| per key | `/api/v/forget` | 30 requests / 60 s; over it 429 with `Retry-After`, `fa_vid` kept, the tracker retries (§5.4) |
| tracked keys | each limiter | 10 000, oldest evicted |

Batching check: one active visitor sends ≤ 8 requests/min at peak and 1 to 3 typically, ~20 events per 10 min; the per-key limits admit 3 to 10 concurrent visitors behind one NAT. 20 events fit 8 KiB.

### 5.9 Contact goal and enquiry count (C11, Q4; WA-2b)

`submitContact` gains an optional boolean `analytics`. The form sets it to `true` only while all of these hold, mirroring §4.1: `fa_consent` is `granted`, current and < 12 months old; `fa_optout` is unset; and either the grant was given by the user (`by: "user"`, which overrides GPC/DNT) or the browser sends no GPC/DNT signal. After `sendMail()` succeeded:

| Event | Condition | Payload |
|---|---|---|
| `goal` | `input.analytics === true` AND an **existing** well-formed current `fa_vid` AND no Auth.js session cookie AND both kill switches on. The Server Action never mints `fa_vid`: a submission without an existing cookie records no goal (the enquiry counter still counts it) | `{eventId: <server-generated>, type: "goal", goal: "contact_submit", visitorId, path: "/contact", locale, pageviewId: null, seq: null, occurredAt = receivedAt = now}` |
| `enquiry` | every successful submission without session cookie; `ANALYTICS_COLLECT_ENABLED` on (independent of `ANALYTICS_UI_ENABLED`, §1.4) | `eventId` (server-generated), `type: "enquiry"`, `occurredAt`, `receivedAt`; every other field of the §6.2 event shape serialised as `null` |

`eventId` for goal and enquiry is generated by furchert-ch with `crypto.randomUUID()` (UUID v4) when the event is created; it is the idempotency key for forward-queue retries. Nothing from the form is attached. A failure to enqueue never affects the form result.

**Goal before the first flush (residual).** The landing pageview is flushed immediately on tracker start and Accept (§3.9), so `fa_vid` normally exists before the form is used. The form's submit waits for a still-pending first flush for at most 1 s before it calls the Server Action. If there is still no `fa_vid` after that, no goal is recorded and the enquiry counter still counts the submission. This rare loss is a documented residual and never delays or changes the form result beyond the 1 s bound. The note under the form stays unchanged.

### 5.10 Forward queue (C12; WA-2b unless marked)

| Item | Rule |
|---|---|
| Model | re-serialise from the validated model; add `edgeDrops` counts |
| Order | one ordered pipeline for batches; [WA-5] forget waits for the in-flight batch before its synchronous delete (§5.4) |
| Queue | 2 000 events; overflow dropped and counted |
| Batches | ≤ 200 events **and** ≤ 48 KiB serialised (data-service caps at 200 events and 64 KiB; the margin covers envelope and encoding); a batch reaching either bound is closed and a new one started |
| Flush | every 5 s or when a batch is full; one in flight; forward request timeout 10 s (async queue, no user waits; paired with data-service `statement_timeout` 2 s, §6.2) |
| Retry and `edgeDrops` | on a retry of a batch furchert-ch sends `edgeDrops` zeroed (only the first attempt carries them). A replay after a lost response can still double-count edge drops: accepted data-quality residual |
| Circuit | open 60 s after 3 consecutive failures |
| Age | events older than 60 min dropped (`expired`) |
| Capped 429 [WA-5] | read `capScope`, `retryAt`; pause analytics events until `retryAt`; goal and enquiry keep flowing |
| 413 | never drops valid events: the batch is split in halves and each half is retried; only a single event that alone exceeds the cap (impossible within the §6.2 field limits) is dropped and counted `invalid` |
| Other errors | 400 drop the batch and count; 401 drop token, retry once; 403 drop, log a configuration hint |
| Delivery | at-most-once; lost on pod restart (accepted) |
| Token | `analytics:write` only, own `globalThis` cache |
| Logging (C17) | `[analytics]`; ≤ 1 summary line per minute with counts; never body, IP, UA, visitor id, referrer, URL with query |

### 5.11 CSP: no change

Same-origin `fetch` is covered by `connect-src 'self'` (Report-Only); no inline script, third-party origin or form post. `next.config.mjs` `headers()` and `src/securityHeaders.test.ts` stay unchanged (Q6 changes only `redirects()`); WA-2b pins the client endpoints to `/api/v` and `/api/v/forget` in a test.

---

## 6. furchert-ch → data-service write API

### 6.1 Common (WA-1)

| Item | Contract |
|---|---|
| Auth | Bearer; `SCOPE_analytics:write` **and** `sub ∈ webanalytics.api.write-clients` (`[furchert-ch]`); `ROLE_ADMIN` not accepted, and any token carrying a `ROLE_*` authority is rejected with 403 (defence in depth; the `sub` allowlist remains the primary control); own `SecurityFilterChain`, method-specific matchers |
| Headers | `Cache-Control: no-store`, `Pragma: no-cache` on every response |
| Errors | problem+json per `060` §7.1; `detail` never echoes input |

### 6.2 `POST /api/webanalytics/events` (C13; WA-1)

Body ≤ 64 KiB (Content-Length plus counted stream), ≤ 200 events (more than 200 events in one request → **413**, not 400, so furchert-ch splits and retries; over HTTP the 64 KiB cap answers first, at about 115 full events, so the count check is a defensive validation tested at service level, not over HTTP), Jackson `StreamReadConstraints` (nesting ≤ 8, string ≤ 512, document ≤ 64 KiB), unknown properties fail, per-event validation, `statement_timeout` 2 s per statement, one transaction per batch; no `synchronous_commit = off`. Paired with the 10 s forward timeout in furchert-ch (§5.10): the per-statement timeout bounds each statement, and a replay is idempotent, so a hidden commit at worst produces a duplicate that is classified as such.

Event JSON field names (exactly 28, all always present): `eventId`, `type`, `occurredAt`, `receivedAt`, `visitorId`, `pageviewId`, `seq`, `path`, `locale`, `landing`, `referrerDomain`, `utmSource`, `utmMedium`, `utmCampaign`, `country`, `deviceClass`, `browserFamily`, `osFamily`, `viewport`, `engagedMs`, `scrollMax`, `fits`, `sectionMask`, `formStarted`, `clickKind`, `clickTarget`, `clickArea`, `goal`.

Shared validation fixtures are canonical in data-service at `src/test/resources/webanalytics/c13-fixtures.json` with relative time tokens `now±Nm`; furchert-ch (WA-2b) copies them and its test asserts that it uses the same file version (comment with the data-service commit).

```json
{ "events": [ { "eventId": "e1…", "type": "pageview", "occurredAt": "2026-11-08T15:00:00.000Z", "receivedAt": "2026-11-08T15:00:00.120Z",
                "visitorId": "3f0c…", "pageviewId": "p1…", "seq": 0, "path": "/automation", "locale": "de",
                "landing": true, "referrerDomain": "google.com", "utmSource": "linkedin", "utmMedium": "social", "utmCampaign": "2026-11-ki",
                "country": "CH", "deviceClass": "desktop", "browserFamily": "firefox", "osFamily": "macos", "viewport": "1024-1439",
                "engagedMs": null, "scrollMax": null, "fits": null, "sectionMask": null, "formStarted": null,
                "clickKind": null, "clickTarget": null, "clickArea": null, "goal": null } ],
  "edgeDrops": { "bot": 0, "signed_in": 0, "consent": 0, "invalid": 0, "path": 0, "rate_limited": 0, "mint_limited": 0, "overflow": 0, "expired": 0 } }
```

| Field | Type | Null | Rule |
|---|---|---|---|
| `eventId` | uuid | no | idempotency key |
| `type` | string | no | `pageview`, `engagement`, `click`, `goal`, `enquiry` |
| `occurredAt`, `receivedAt` | instant | no | `receivedAt` ∈ [now − 2 h, now + 1 min]; `receivedAt − 15 min ≤ occurredAt ≤ receivedAt` |
| `visitorId` | uuid | yes | `null` only for enquiry |
| `pageviewId`, `seq` | uuid, int | yes | non-null for pageview/engagement/click; `null` for goal/enquiry |
| `path`, `locale` | string | yes | `path`: locale-free form `^/([a-z0-9][a-z0-9-]{0,63}(/[a-z0-9][a-z0-9-]{0,63}){0,2})?$`, ≤ 200 chars; `locale` `de`, `en`; both `null` only for enquiry. The literal `(other)` is valid only for nav click targets (`clickTarget` of kind `nav`, same pattern otherwise), never for `path`. The pattern cannot tell a locale-prefixed `/de/x` from a real page `/de/x`, so data-service does not reject locale-prefixed paths; furchert-ch canonicalises (§5.5) and is solely responsible for sending locale-free paths |
| pageview context fields | — | yes | pageview only; `landing` and families non-null there |
| engagement fields | — | yes | engagement only, all non-null there |
| `clickKind`, `clickTarget`, `clickArea` | — | yes | click only; `null` target for mailto/tel |
| `goal` | string | yes | goal only: `contact_submit` |
| `edgeDrops` | object | no | fixed reason keys; values must be integers 0 to 1 000 000, otherwise 400; may accompany 0 events |

An `enquiry` event carries only `eventId`, `type`, `occurredAt`, `receivedAt`; every other field is present and `null` (a non-null value rejects the event). It increments `daily_enquiries(day)` (Zurich day of `occurredAt`) with an in-memory 2 h dedupe of `eventId`; no row in `events`; it counts toward `webanalytics_enquiries_total`, not toward `webanalytics_events_accepted_total` or the response's `accepted`. Others: `INSERT … ON CONFLICT DO NOTHING`. Response 200: `{"accepted": 18, "duplicates": 1, "rejected": 1, "capped": false}`.

**Counting rules.** Enquiry events are not reflected in `accepted` or `duplicates`; an enquiry duplicate within the 2 h window is silently ignored; an invalid enquiry counts as `rejected`. **Strict presence:** every listed field must be present in each event; a missing JSON key is a 400 for the whole batch, `null` must be written explicitly. An event whose `(pageviewId, seq)` already exists with a **different** `eventId` is rejected with reason `other`; the same `eventId` again counts as a duplicate.

### 6.3 Statuses

| Status | When | Built in |
|---|---|---|
| 200 | envelope valid | WA-1 |
| 400 / 401 / 403 / 405 / 413 / 415 | schema (incl. `edgeDrops` values outside 0 to 1 000 000), token, scope/`sub` or any `ROLE_*` authority, method, size or more than 200 events (413), content type | WA-1 |
| 429 | cap would be exceeded: `{"accepted": 0, "duplicates": 0, "rejected": 0, "capped": true, "capScope": "hour" \| "day", "retryAt": "…Z"}`, all-or-nothing per batch | [WA-5] |

### 6.4 Caps [WA-5]

| Cap | Value | Counted on |
|---|---|---|
| Daily | 10 000 accepted analytics events | UTC day of `received_at` |
| Hourly | 2 500 | UTC hour of `received_at` |
| Per visitor | 500 events per visitor id per UTC day; excess rejected (`visitor_cap`) | in-memory map, seeded per visitor on first sight |

Seeded at startup from `events.received_at`. Exempt: `goal`, `enquiry` (bounded by the contact form's limits). `retryAt` = next UTC hour or 00:00 UTC.

### 6.5 `DELETE /api/webanalytics/visitors/{visitorId}` and tombstones [WA-5]

Write scope. Deletes all `events` rows of that id, adds it to an in-memory tombstone set for 2 h; events for a tombstoned id are rejected (`erased`). 204 (also when nothing matched), 400 for a bad uuid. Log `[webanalytics] visitor erased rows=<n>` only. Tombstones are lost on restart; the furchert-ch queue purge covers the normal case. Called synchronously by the forget handler (§5.4).

---

## 7. data-service storage, rollup, retention, metrics

### 7.1 Naming and Flyway

| Item | Value |
|---|---|
| Schema | `webanalytics` (owner role `data_service`) |
| Flyway (next free at PR time) | WA-1: `V6__webanalytics_ingest.sql` (schema, `events`, `daily_ingest_stats`, `daily_enquiries`); WA-3a: `V7__webanalytics_core_aggregates.sql`; WA-3b: `V8__webanalytics_path_aggregates.sql` |
| Config | `spring.flyway.schemas: public,netmon,webanalytics`; V6 runs `CREATE SCHEMA IF NOT EXISTS webanalytics` |
| Package | `ch.furchert.homelab.data.webanalytics` |

### 7.2 Raw and ingest-maintained tables (WA-1)

**`webanalytics.events`** (events only, context on pageview rows; the `visit` + `event` split needs a client visit id, which K5 removes):

| Column | Type | Null | Notes |
|---|---|---|---|
| event_id | uuid | no | PK |
| event_type | text | no | CHECK in (`pageview`, `engagement`, `click`, `goal`) |
| occurred_at, received_at | timestamptz | no | CHECK `occurred_at <= received_at AND occurred_at >= received_at - interval '15 minutes'` |
| visitor_id | uuid | no | never leaves data-service |
| pageview_id, seq | uuid, smallint | yes | `NULL` only for goal |
| path, locale | text | no | CHECK pattern / (`de`, `en`) |
| landing, referrer_domain, utm_source, utm_medium, utm_campaign, country, device_class, browser_family, os_family, viewport | — | yes | pageview only |
| engaged_ms, scroll_max, fits, section_mask, form_started | — | yes | engagement only |
| click_kind, click_target, click_area | text | yes | click only |
| goal | text | yes | goal only (`contact_submit`) |
| source, ingested_at | text, timestamptz | no | `furchert-ch`, default `now()` |

Shape CHECK per type; UNIQUE `(pageview_id, seq)`; indexes `(occurred_at)`, `(visitor_id, occurred_at)`, `(received_at)`; autovacuum scale factors 0.02 / insert 0.05 / analyze 0.02.

**`daily_ingest_stats`**: columns `day` (Zurich day of receipt), `stage` ∈ {`accepted`, `duplicate`, `rejected`, `edge`}, `reason` (for `rejected` the §7.9 reason labels; for `edge` the nine `edgeDrops` keys; otherwise `''`) and `events` (counter); PK `(day, stage, reason)`; the CHECK constraints are format-only so WA-5 can add stages; upsert-increment at ingest, id-free, never touched by the rollup. Enquiries (valid, duplicate or invalid) are not counted here. **`daily_enquiries`**: PK `(day)`, `submissions`, increment-only, id-free, never touched by the rollup.

### 7.3 Size (≈ 300 B per row)

Base (50 k events/month): ≈ 650 k rows, ≈ 200 MB at steady state. Worst case at the cap: ≈ 3.96 M rows, ≈ 1.2 GB (≈ 24 % of the shared 5 Gi PVC). Aggregates ≈ 40 to 50 MB/year. Until WA-5 there is no cap and no retention; the dark launch keeps volume at zero.

### 7.4 No partitioning

Partition keys break `event_id` dedupe; `ctid` batching is unsafe on partitioned parents; no pg_partman. Revisit above 20 M rows.

### 7.5 Nightly rollup

| Item | Contract | Built in |
|---|---|---|
| Runner | `NetmonCollector` `webanalytics-rollup` via `CollectorRunner`; `NetmonCollector.group()` (default `netmon`, the webanalytics collectors `webanalytics`) and `/api/netmon/status` filters by group, not by name prefix, so it excludes the `webanalytics` group (network strip unchanged); `/api/webanalytics/status` lists them | WA-3a |
| Default off | ships with `netmon.collectors.webanalytics-rollup.enabled=false`. `CollectorMetricsInitializer` exports no freshness gauge for a disabled collector, so the existing `NetmonCollectorStale` catch-all cannot fire before the alert change is live | WA-3a |
| Enable gate | (1) homelab WA-3a PR (daily class + catch-all exclusion) merged; (2) the owner runs playbook `41_monitoring.yml`; (3) only then a follow-up data-service `k8s/deployment.yaml` change sets the environment variable `NETMON_COLLECTORS_WEBANALYTICS_ROLLUP_ENABLED=true` (relaxed binding of the dashed property name works while the explicit YAML entry `netmon.collectors.webanalytics-rollup.enabled: false` is present; the form without separators does not; `SPRING_APPLICATION_JSON` is only an alternative), and the explicit `false` default in the committed YAML stays mandatory (env binding for the dashed collector name verified in WA-3a phase 1) | WA-3a |
| Schedule | two daily runs, both `zone = "Europe/Zurich"` and through the same `CollectorRunner` (one lock, so they never overlap): **01:12** `@Scheduled(cron = "0 12 1 * * *")` (night run, §7.6) and **07:30** `@Scheduled(cron = "0 30 7 * * *")` (morning run, after yesterday closes at 07:15). 07:30 is clear of Longhorn 02:00, restic 03:00, `RetentionJob` (04:30/05:30), Longhorn trim 05:00 and blocklists (06:00/07:00); the mba1 scheduled reboot at 07:40 only happens after ≥ 3.5 days uptime and the run takes seconds, so an interrupted run is simply redone by the next night's lookback. It shares the minute mark with the 30-minute reputation and 5-minute Cloudflare collectors, which the scheduler pool (size 4) runs in parallel. Documented exception to "crons in UTC" | WA-3a |
| Lock | `pg_try_advisory_xact_lock(hashtext('webanalytics-rollup'))` per day; a failed lock stops the whole run (warning and early return), it never skips a single day | WA-3a |
| First run | no `rollup_day` rows yet: process yesterday only if it is closed (zero rows + a `rollup_day` row when empty); a first trigger at 07:30 does yesterday only if it is closed, otherwise nothing | WA-3a |
| Selection | one `eligible(day, now)` predicate for every selection path (catch-up, lookback, backfill, finalisation); [WA-5] freeze-guard conditions hook in there. Candidate days come from a gap scan over `rollup_day` (missing or non-final days in [first rolled day, yesterday]); a day is final iff `now ≥ close(D)`, derived from the clock, not from a trigger or pass flag; at the morning slot the candidates are only closed non-final days. A failing day aborts the run; `now` is taken immediately before the window is loaded; each day is its own transaction. `collector_state.last_window_end` = the newest day of the all-final contiguous prefix (status display only), updated in the per-day transaction, so `/status` `lastWindowEnd` = `start(D + 1)` of that day | WA-3a |
| Days per run | **01:12:** the last 2 complete days (yesterday provisional, the day before final), catch-up by the gap scan, up to 31 days with an outdated `definition_version`, newest first, within 30 days. **07:30:** every day that is closed but still has `final = false` (normally only yesterday), written as final | WA-3a |
| Final vs provisional | a day D is **closed** once `start(D + 1) + 6 h` (visit cap) `+ 75 min` (60 min forward-queue age + 15 min clock-skew window) has passed, i.e. D + 1 at 07:15 Zurich time. A rollup of D before that writes `rollup_day.final = false` (provisional); a rollup after it writes `final = true`. The 01:12 run writes yesterday as provisional; the 07:30 run rewrites it as final the same morning. `lastCompleteDay` = the newest day with `final = true`; read endpoints serve only final days (provisional rows are not exposed). On DST-change days the close is computed in Europe/Zurich elapsed time and moves by ±1 h (06:15 on fall-back days, 08:15 on spring-forward days); on a spring-forward day the 07:30 run leaves yesterday provisional and the next 01:12 run finalises it. After 07:30 "data through" is therefore normally yesterday; between 00:00 and 07:30 it is the day before yesterday | WA-3a |
| Empty days | always a `rollup_day` row, so `lastCompleteDay` advances | WA-3a |
| Write mode | per day one transaction: DELETE the day from every rollup-owned table, then batch INSERT of the rows computed by the Java visit model (a documented deviation from INSERT … SELECT, because visits are built in Java; never `daily_ingest_stats`, `daily_enquiries`) | WA-3a |
| Freeze guard | a day is (re)computed only if (a) `day < today`; (b) `day ≥ today − (retentionDays − 1)`, with `retentionDays` = the configured `webanalytics.retention.events-days`; (c) `day ≥ today − 30` or no `rollup_day` row; (d) not (`rollup_day.raw_events > 0` and now 0 raw events). Needed only once retention deletes data | [WA-5] |

**Algorithm for day D:** load events in [start(D) − 6 h, start(D + 1) + 6 h); per visitor order by `occurred_at`, `event_id` (`seq` within a pageview); split at gaps > 30 min and at landings with referrer/UTM; cut at 6 h (continuous activity beyond 6 h is cut and the remainder starts a further visit: a documented data-quality limit, rare); keep visits starting in D (no pageview → `orphan_visits`); exclude visits with > 100 pageviews or > 500 events; merge same-path pageviews within 30 s (≤ 30.000 s); per original `pageviewId` MAX engaged/scroll, OR masks, then `engagedMs` summed across the reload-merged ids; engagement and click events with a known `pageviewId` attach to that pageview's visit regardless of any gap, and only pageviews, goals and events with an unknown `pageviewId` open visits or measure gaps; a visitor is new on D if any of its visits on D is new; per visit entry/exit, entry locale, device class, landing attributes, engaged (≥ 10 s, or ≥ 2 distinct pages, or a key event), offer visit, contact intent, converting, new/returning; channel and first channel; WA-3b: funnels, group path, entry × exit, seen-before, transitions, dimensions, CF baseline, submits by day; top 50 per open dimension, rest `(other)`; write rows and `rollup_day(D)`. Funnels and path keys in Java; `SET LOCAL work_mem = '16MB'`, `statement_timeout = '120s'`.

**Raw-history reads beyond the day window** (all on `webanalytics.events`, all within raw retention):

| Purpose | Read | Bound |
|---|---|---|
| New vs returning | per visitor of D: `EXISTS (event with the same visitor_id and occurred_at < the visit's first pageview)` via index `(visitor_id, occurred_at)` | a visitor id lives ≤ 365 days, raw keeps 396 days, so every earlier event of a live id is still present for every day inside the 30-day recompute horizon |
| First-known channel (converting visits) | per converting visitor of D: its earliest `landing = true` pageview (`min(occurred_at)`) and that pageview's referrer/UTM, classified with §8.4 | same bound as above |
| Rolling uniques (`visitors_7d`, `visitors_28d`, `repeat_offer_viewers_28d`) | distinct visitors of NON-excluded visits starting in [start(D − 6), start(D + 1)) and [start(D − 27), start(D + 1)), from the same Java visit model as the day rollup (excluded visits only add to `excluded_visits`); repeat offer viewers rebuild visits over the 28-day window | ≤ 28 days back, always inside retention |
| `monthly_visitors` | distinct visitors of non-excluded visits over the current Zurich month (and the previous one on days 1 to 2), same visit model | ≤ 62 days back |

Before WA-5 there is no retention, so these reads see all raw data; with the dark launch that is empty until go-live.

### 7.6 Rollup slot (K6)

A second run at 07:30 writes the final days (§7.5).

| Job | Time | Zone |
|---|---|---|
| Longhorn `daily-snapshot` (incl. Postgres PVC) | 02:00 | node-local Europe/Zurich |
| restic (raspi5) | 03:00 | node-local |
| netmon `RetentionJob` (from WA-5 also `webanalytics.events`) | 03:30 UTC = 04:30 CET / 05:30 CEST | UTC |
| Longhorn `metrics-snapshot-cleanup` / `metrics-filesystem-trim` | 04:00 / 05:00 | node-local |
| netmon `blocklists` | 05:00 UTC | UTC |
| mba2 / mba1 scheduled reboots | 06:10 / 07:40 | node-local |
| netmon collectors | :15 s each minute; every 5 min at :00/:30 s; :04/:19/:34/:49; :07; :00/:30 | UTC |
| k3s kine compaction; auth-service hourly cleanups | continuous / hourly | — |
| n8n workflow schedules | unknown (repo not cloned) | owner check, WA-5 |

**Chosen: 01:12 Europe/Zurich.** No daily job runs between 00:00 and 02:00 local; 01:12 avoids the collectors' minute marks; it follows the final Cloudflare hour (00:15 local) and finishes before the 02:00 snapshot, which then captures fresh aggregates; it never meets the reboots; it exists once per day across DST. 04:30 collides with `RetentionJob`; 01:15 meets the 5-minute Cloudflare run.

### 7.7 Retention [WA-5]

- `RetentionTarget` gains a validated `schema` (default `netmon`) and an optional per-target batch size; `RetentionJob` hard-codes `netmon.` today and batches by `ctid` (safe: nothing is partitioned).
- Target `webanalytics.events` / `occurred_at` / `webanalytics.retention.events-days` = **396** (< 370 fails startup).
- Runs inside the existing 03:30 UTC job; log `[retention] webanalytics.events deleted=<n>`.
- Never registered: aggregates, `rollup_day`, `daily_ingest_stats`, `daily_enquiries`.
- 396 days is internal (spec, data-service docs), not stated publicly (Q1).

### 7.8 Aggregate tables

No uuid column and no `visitor_id`/`visit_id` column (information_schema test); count columns named `visitors…` (for example `visitors_7d`) are fine. Key columns use `''` for "none". Counts `NOT NULL`, `CHECK (x >= 0)`, `computed_at`. Replace per day; no retention.

Re-evaluation: an id-free per-visit fact table is rejected (rare country + device + path + timing combinations single out a person at this volume). Instead every visit-scoped table is keyed by `entry_locale` and `device_class`, so the `locale` and `device` filters mean the same everywhere and a visit is counted once per path even if it viewed both language versions; the page-locale split is pageview-based (`pageviews_de`, `pageviews_en`).

| Table | Primary key | Counts | WA |
|---|---|---|---|
| `daily_visits` | `(day, entry_locale, device_class)` | `visits`, `new_visits`, `returning_visits`, `engaged_visits`, `offer_visits`, `engaged_offer_visits`, `contact_intent_visits`, `form_start_visits`, `converting_visits`, `conversions`, `pageviews`, `excluded_visits` | 3a |
| `daily_visitors` (visitors: distinct visitors of non-excluded visits starting on D, same visit model; new if any visit on D is new) | `(day)` | `visitors`, `new_visitors`, `returning_visitors`, `visitors_7d`, `visitors_28d`, `repeat_offer_viewers_28d` | 3a |
| `monthly_visitors` | `(month)` | `visitors`, `new_visitors`, `returning_visitors`, `repeat_offer_viewers` | 3a |
| `daily_page` | `(day, path, entry_locale, device_class)` | `pageviews`, `pageviews_de`, `pageviews_en`, `visits_viewed`, `entries`, `exits`, `landing_engaged_visits`, `landing_converting_visits`, `engagement_samples`, `engaged_ms_sum`, `eng_h0`…`eng_h7` (0–5 s, 5–10 s, 10–30 s, 30–60 s, 1–2 min, 2–5 min, 5–10 min, > 10 min), `scroll_samples`, `scroll_25`…`scroll_100` | 3a |
| `daily_section` | `(day, entry_locale, device_class, section)` | `reached_pageviews`, `deepest_at_exit_visits` | 3a |
| `daily_click` | `(day, path, entry_locale, device_class, kind, target, area)` | `clicks`, `visits`, `converting_visits` | 3a |
| `daily_source` | `(day, entry_locale, device_class, channel, referrer_domain, utm_source, utm_medium, utm_campaign)` | `visits`, `new_visits`, `engaged_visits`, `offer_visits`, `converting_visits` | 3a |
| `daily_conversion` | `(day, entry_locale, device_class, entry_path, channel, first_channel)` | `converting_visits`, `conversions` | 3a |
| `rollup_day` | `(day)` | `raw_events` (all event types with `occurred_at` in [start(D), start(D + 1)) Zurich), `raw_pageviews` (the same for pageviews; the ±6 h margin events are excluded from both), `visits`, `orphan_visits`, `definition_version`, `final` (boolean), `rolled_up_at` | 3a |
| `daily_transition` | `(day, entry_locale, device_class, from_path, to_path)` | `transitions` | 3b |
| `daily_funnel` | `(day, funnel_id, step, entry_locale, device_class)` | `visits` | 3b |
| `daily_group_path` | `(day, path_key)` | `visits`, `converting_visits` | 3b |
| `daily_entry_exit` | `(day, entry_path, exit_path)` | `visits` | 3b |
| `daily_intent_seen` | `(day, seen)` (`about`, `projects`, `prices`, `none`) | `visits` | 3b |
| `daily_dimension` | `(day, dimension, value)` (`country`, `browser_family`, `os_family`, `viewport`, `visitor_type`) | `visits`, `engaged_visits`, `converting_visits` | 3b |
| `daily_cf_baseline` | `(day, path, locale)` | `requests`, `sampled` | 3b |
| `daily_submits` | `(day)` = Zurich day of the goal event's `occurred_at` (submission day) | `consented_submits` (goal events, excluded visits included) | 3b |

Page groups: home `/`; offer `/automation`, `/it`; proof `/projects`, `/projects/*`, `/about`; personal `/rowing`; contact `/contact`; repeats collapsed, first 4 steps then `…`, `(exit)` terminal.

`daily_cf_baseline` from `netmon.inbound_request_groups` (host `furchert.ch`, `GET`, 200–299, path `^/(de|en)(/[a-z0-9][a-z0-9-]{0,63}){0,2}/?$` → locale-free path + locale, hours inside the Zurich day), no IP-derived column. **One-time backfill:** when empty, the first WA-3b run fills every day netmon still holds (≈ 90 days) as a pre-launch baseline; then nightly.

### 7.9 Metrics and alerts

| Metric | Type | Built in |
|---|---|---|
| `webanalytics_events_accepted_total`, `_duplicate_total` (analytics events only; enquiries excluded) | counter | WA-1 |
| `webanalytics_enquiries_total` (separate counter for enquiry increments) | counter | WA-1 |
| `webanalytics_events_rejected_total{reason}` (`shape`, `enum`, `range`, `time`, `path`, `other`; [WA-5] `erased`, `visitor_cap`) | counter | WA-1 |
| `webanalytics_edge_dropped_total{reason}` | counter | WA-1 |
| `webanalytics_ingest_capped`, `webanalytics_events_today` (UTC day, `received_at`), `webanalytics_raw_table_bytes` (every 15 min) | gauge | [WA-5] |
| `netmon_collector_last_success_timestamp_seconds{collector="webanalytics-rollup"}` | gauge | WA-3a (exported only once the collector is enabled, §7.5) |

**Rollup staleness (homelab, WA-3a):** add `webanalytics-rollup` to the `NetmonCollectorStale` 26 h daily class regex and to the 15-min catch-all exclusion, with a promtool test; it must be live (playbook `41_monitoring.yml` run) before the collector is enabled (§7.5).

**WebAnalytics rules** (key `homelab-webanalytics`, single `additionalPrometheusRulesMap`, promtool tests): five rules in WA-5, `WebAnalyticsIngestSilent` in WA-6 (go-live), because before go-live there is no traffic and the rule would fire.

| Alert | Expression (sketch) | For | Severity | WA |
|---|---|---|---|---|
| `WebAnalyticsIngestCapped` | `max(webanalytics_ingest_capped) == 1` | 5m | warning | 5 |
| `WebAnalyticsIngestSpike` | hourly accepted > 3 × 7-day hourly average and > 500 | 15m | warning | 5 |
| `WebAnalyticsRejectRatioHigh` | rejects / (rejects + accepted) > 0.5 and rejects > 100/h | 30m | info | 5 |
| `WebAnalyticsSecondLineRejects` | `increase(webanalytics_events_rejected_total{reason!~"erased\|visitor_cap"}[1h]) > 0` | 0m | warning | 5 |
| `WebAnalyticsTableLarge` | `webanalytics_raw_table_bytes > 1.5 GiB` (above the ≈ 1.2 GB steady state at the cap) | 1h | warning | 5 |
| `WebAnalyticsIngestSilent` | no increase of `webanalytics_events_accepted_total` (enquiries not counted) for 7 days while data-service and furchert-ch are up | 1h | info | 6 |

---

## 8. Read API for the dashboard (WA-3a, WA-3b)

### 8.1 Conventions

| Item | Contract |
|---|---|
| Base | `http://data-service.apps.svc.cluster.local:8082/api/webanalytics` |
| Auth | `SCOPE_analytics:read` and `sub ∈ webanalytics.api.read-clients`; `GET` only; any token carrying a `ROLE_*` authority is rejected with 403 (defence in depth, as in §6.1) |
| Source | aggregates only (repository test); `/status.ingest` from memory; no visitor id in any response |
| Range | `from`, `to` (Zurich dates, inclusive); default `to` = `lastCompleteDay`, `from` = `to − 27 d`; span ≤ 366 d; `to` clamped to `lastCompleteDay` (provisional days are never served, §7.5); invalid → 400 `invalid_window` |
| Range echo | every endpoint that takes a range returns `"range": {"from", "to", "days", "lastCompleteDay", "previous": {"from", "to"} \| null}`; the empty state (before any final rollup) is `{"from": null, "to": null, "days": 0, "lastCompleteDay": null, "previous": null}` |
| Compare | `compare=previous` (default) or `none` (`previous` is then `null`) |
| Edge cases | `to < from` after clamping → 200 with the empty range (`from`, `to` and `previous` null, `days` 0, `lastCompleteDay` keeps its known value); `/clicks` `kind` is optional (missing = all kinds); a whole calendar month takes precedence and uses the month basis, whose `previous` is the previous calendar month; `/status` `lastWindowEnd` is `start(D + 1)` Europe/Zurich as an instant (ISO-8601 UTC) |
| Filters | `locale=de\|en` (entry locale), `device=desktop\|mobile\|tablet`; echoed as `"filters": {"applied": {…}, "ignored": [...]}` |
| Numbers | counts only; rates, intervals, medians in furchert-ch; daily series |
| Lists | `limit` default 20, max 100; remainder in `(other)` |
| Empty data | every day up to `lastCompleteDay` with zeros; before any final rollup `lastCompleteDay` `null` |

| Endpoint | WA | `locale` | `device` |
|---|---|---|---|
| `/status` | 3a | ignored | ignored |
| `/overview` | 3a | yes (visitors block ignores) | yes |
| `/pages`, `/pages/detail` | 3a (detail `previous`/`next` 3b) | yes | yes |
| `/clicks`, `/sources` | 3a | yes | yes |
| `/funnels` | 3b | yes | yes |
| `/paths` | 3b | `transitions` only | `transitions` only |
| `/audience`, `/coverage` | 3b | ignored | ignored |

### 8.2 Endpoints

**`GET /status`**: `{"collectors": [{"name": "webanalytics-rollup", "enabled", "lastSuccessAt", "lastWindowEnd", "consecutiveFailures", "lastErrorCode", "stale"}], "lastCompleteDay", "provisionalDay", "rawRetentionStart", "definitionVersion", "ingest": {"lastEventAt", "eventsToday", "dailyCap", "capped"}}`. `stale` = older than 26 h. `lastCompleteDay` = newest `final` day: after the 07:30 run normally yesterday, between 00:00 and 07:30 the day before yesterday. `provisionalDay` = newest rolled-up day with `final = false`, informational only: it is yesterday between the 01:12 and the 07:30 run and `null` otherwise. `eventsToday` = accepted cap-counted events with `received_at` in the current UTC day. `dailyCap` and `capped` are `null` before WA-5; `rawRetentionStart` is `null` before WA-5.

**`GET /overview`**

```json
{ "range": {…}, "filters": {…},
  "current":  { "visits": 160, "newVisits": 90, "returningVisits": 70, "engagedVisits": 100, "offerVisits": 80,
                "engagedOfferVisits": 55, "contactIntentVisits": 20, "formStartVisits": 6, "convertingVisits": 3,
                "conversions": 3, "pageviews": 402, "excludedVisits": 0, "enquiriesTotal": 5 },
  "previous": { "…": "same shape" },
  "visitors": { "current": {"value": 120, "basis": "28d"}, "previous": {"value": 98, "basis": "28d"} },
  "daily": [ {"day": "2026-10-11", "visits": 5, "offerVisits": 3, "engagedVisits": 3, "contactIntentVisits": 1,
              "convertingVisits": 0, "pageviews": 14, "enquiries": 0} ] }
```

`visitors` non-null only without filters and for exactly 7 or 28 days or whole months; `enquiriesTotal` ignores filters.

**`GET /pages`**: `items[]` with `path`, `pageviews`, `pageviewsByLocale {de, en}`, `visitsViewed`, `entries`, `exits`, `landingEngagedVisits`, `landingConvertingVisits`, `engagementSamples`, `engagedMsSum`, `engagedHistogram [8]`, `scrollSamples`, `scrollReached {p25, p50, p75, p90, p100}`.

**`GET /pages/detail?path=…`**: `summary` (one pages item), `previous`/`next` (`[{path, count}]`, `null` until WA-3b), `clicks` (`[{kind, target, area, clicks, visits, convertingVisits}]`), `sections {reached [{section, pageviews}], deepestAtExit [{section, visits}]}` and `faqOpens [{faq, opens, visits}]` (only `/automation`), `daily [{day, pageviews, visitsViewed}]`.

**`GET /clicks?kind=…`**: `items[]` with `kind`, `target` (`null` for mailto/tel), `path`, `area`, `clicks`, `visits`, `convertingVisits`, `pageVisits`.

**`GET /sources`**: `channels [{channel, visits, newVisits, engagedVisits, offerVisits, convertingVisits}]` (all seven), `referrers [{domain, channel, visits, convertingVisits}]`, `campaigns [{source, medium, campaign, visits, convertingVisits}]`, `converters {byLandingChannel, byFirstChannel, byEntryPath}`.

**`GET /funnels`** (3b): `definitionVersion`, `funnels [{id: "offer" | "contact_form", steps [{index, key, visits}], previous [...]}]`; F1 keys `visit`, `offer_visit`, `reached_prices`, `contact_intent`, `form_start`, `contact_submit`; F2 keys `contact_pageview`, `form_start`, `contact_submit`.

**`GET /paths`** (3b): `groupPaths [{path, visits, convertingVisits}]`, `entryExit [{entry, exit, visits}]`, `seenBeforeContacting {intentVisits, items [{seen, visits}]}`, `transitions [{fromPath, toPath, count}]`.

**`GET /audience`** (3b): `newVsReturning {newVisits, returningVisits}`, `repeatOfferViewers {value, basis}`, `deviceClass`, `entryLocale`, `dimensions {country, browserFamily, osFamily, viewport, visitorType}` (each `[{value, visits}]`).

**`GET /coverage`** (3b): `baselineFrom`, `daily [{day, consentedPageviews, cloudflareRequests, sampled}]`, `byPage [{path, locale, consentedPageviews, cloudflareRequests, sampled}]` (page locale), `enquiries {consentedSubmits, totalSubmits}`, `dataQuality {edge {…}, secondLine {…}, duplicates, cappedDays}`. **Coverage window starts at go-live:** `baselineFrom` = the first day with `rollup_day.raw_pageviews > 0` (go-live day), `null` before; `daily`, `byPage` and the CF totals cover only `[max(from, baselineFrom), to]`. The pre-launch CF rows from the backfill stay stored but are never compared with tracked pageviews. `enquiries` counts both sides by **submission day**: `consentedSubmits = Σ daily_submits.consented_submits` and `totalSubmits = Σ daily_enquiries.submissions` over the same days (not by visit start day).

### 8.3 Metric definitions (binding)

| Metric | Formula |
|---|---|
| Visits, pageviews, clicks, sections, conversions, funnel steps | sums of daily rows |
| Visitors | never summed across days; `visitors_7d`, `visitors_28d`, `monthly_visitors` only |
| New / returning visit | first visit of the visitor id in raw data / later visits; "at least" |
| Engaged visit | ≥ 10 s total engaged time OR ≥ 2 distinct pages OR ≥ 1 key event; a key event is a `cta` click, contact intent (a `mailto` or `tel` click or a `/contact` pageview), `formStarted`, or the goal |
| Engaged visit rate | `engagedVisits / visits`; headline `engagedOfferVisits / offerVisits` |
| Bounce (landing page only) | `1 − landingEngagedVisits / entries` |
| Exit rate | `exits / visitsViewed` |
| Median engaged time | median bucket of the summed histogram, n = `engagementSamples` |
| Scroll reach | `scrollReached.pNN / scrollSamples` |
| Section reach | `reached_pageviews / pageviews(/automation)` |
| CTR | `visits / pageVisits` |
| Visit conversion rate | `convertingVisits / visits` (visit-start day) |
| Conversion per entry page | `landingConvertingVisits / entries` |
| Repeat offer viewer | offer pageviews in ≥ 2 visits within the basis window |
| Attribution | visit-scoped last touch; secondary first known channel; `heardVia` stays manual |
| Consent coverage | two separate series from `baselineFrom`; rounded 4-week band only if both ≥ 50; no consent-rate %; enquiry coverage `Σ daily_submits.consented_submits / Σ daily_enquiries.submissions`, both by submission day |

### 8.4 Channels

`campaign` (`utm_source` present) → `ai` (`chatgpt.com`, `chat.openai.com`, `perplexity.ai`, `claude.ai`, `gemini.google.com`, `copilot.microsoft.com`) → `search` (google.*, `bing.com`, `duckduckgo.com`, `ecosia.org`, `search.brave.com`, `startpage.com`, `yahoo.com`) → `social` (`linkedin.com`, `lnkd.in`, `facebook.com`, `instagram.com`, `x.com`, `t.co`, `reddit.com`) → `referral` → `direct` (no referrer, landing) → `internal` (first pageview not a landing).

### 8.5 Funnels (`DEFINITION_VERSION = 1`)

F1 `offer`: visit → offer visit → reached `preise` → contact intent → form start → `contact_submit`. F2 `contact_form`: `/contact` pageview → form start → `contact_submit`. F3: `daily_section`. A definition change recomputes the last 30 days.

### 8.6 Small-numbers rules (furchert-ch)

| Rule | Threshold | Below |
|---|---|---|
| Percentage | n ≥ 30 | "x of n" |
| Interval | 30 ≤ n < 200 | Wilson 95 %: `(p + z²/2n ± z·√(p(1−p)/n + z²/4n²)) / (1 + z²/n)`, z = 1.96 |
| Count delta | both ≥ 20 | change only if `\|a − b\| ≥ 2·√(a + b)` |
| Rate delta | both n ≥ 30 | both "x of n" |
| Rows, paths, funnel cells | ≥ 3 | "other (n)" |
| Median | ≥ 10 samples | `–` + n |
| Winner badge | leader ≥ 5 and ≥ 2× runner-up | none |
| Charts | ≤ 31 d daily; ≤ 6 months weekly; beyond monthly | — |

---

## 9. Dashboard `/[locale]/dashboard/analytics` (WA-4a, WA-4b)

### 9.1 Contract

| Item | Contract |
|---|---|
| Route | `src/app/[locale]/dashboard/analytics/page.tsx`, `force-dynamic`, noindex |
| Gate (C16) | as `/dashboard/network`; no data-service call before the ADMIN check |
| Nav | `DevSubnav` gains `'analytics'` after `network` |
| Data | `src/lib/analytics/read.ts`, result union like `NetmonResult`, `no-store`, 5 s timeout, one retry after 401, per-section `allSettled`, honest "unavailable" / "no data yet" / "not yet available" |
| Token | `analytics:read` only; env `DATA_SERVICE_URL`, `DATA_SERVICE_TOKEN_URL` reused |
| Rendering (C16) | React text only; no `dangerouslySetInnerHTML`, no stored-value hrefs; inline SVG/div, ETHON tokens |
| Controls | range `7d`/`28d` (default)/`90d`/`12m`/custom, compare on, locale (entry), device; ignored filters shown per section |
| Header | "Data through <lastCompleteDay> · consented visits only · own visits excluded" (`lastCompleteDay` is the newest final day: normally yesterday after the 07:30 run, the day before yesterday before it) |
| Design pass | `dataviz` + `frontend-design` skills, owner review (WA-4a, whole page) |

### 9.2 Sections

| # | Section | API | WA |
|---|---|---|---|
| 0 | Status strip | `/status` | 4a |
| 1 | Offer at a glance (visits, offer visits, engaged rate on offer visits, contact intents, submits consented/total, visitors) | `/overview` | 4a |
| 2 | Offer funnel F1, F2 | `/funnels` | 4b |
| 3 | Pages + drilldown (clicks, scroll, sections, FAQ opens; previous/next in 4b) | `/pages`, `/pages/detail` | 4a |
| 4 | Clicks | `/clicks` | 4a |
| 5 | Sources | `/sources` | 4a |
| 6 | Paths | `/paths` | 4b |
| 7 | Audience | `/audience` | 4b |
| 8 | Coverage and data quality (from `baselineFrom`) | `/coverage` | 4b |
| 9 | This browser (never-track switch) | client | 4a |

No per-visitor timeline, converting-visit list, id lookup or export. Docs (`INTERFACES.md`, `OVERVIEW.md`, `CHANGELOG.md`) in each WA-4 PR.

### 9.3 "Never track this browser" (D8)

On: `fa_optout`, abort in-flight requests, forget, stop. Off: remove `fa_optout`. Per browser/device; not auto-enabled on sign-in.

---

## 10. Consent bar and privacy text

### 10.1 Bar (WA-2a; copy sign-off in WA-5)

| Item | Contract |
|---|---|
| Placement | fixed bottom bar outside `<main>`, client-only after hydration, no CLS; the portal host is the first child of `<body>` (visually fixed at the bottom, first in focus order) |
| First layer | title, text naming random identifier, 12 months, page views, clicks, successful contact submission without content, owner-only analysis, footer link, privacy link; "Ablehnen" / "Erlauben" |
| Equal prominence | same `Btn` variant and size, Decline first; no "Alle akzeptieren", no "Später", no pre-selection; Esc/close/scroll ≠ consent |
| Non-modal | page usable, no focus trap, `role="region"` + `aria-labelledby`, ≥ 44 px, visible focus, contrast ≥ 4.5:1, no motion under `prefers-reduced-motion` |
| LCP | one or two short lines, smaller than the hero |
| Reopen | footer "Datenschutz-Einstellungen" / "Privacy settings" with current state |
| Multi-tab | same-tab `CustomEvent` + `storage` event |
| Forget | the consent controller owns one serialised `forget()` (single in-flight promise, cancellable retry, retry only while tracking is not allowed); WA-2a calls the forget contract through a stub, the minimal route ships in WA-2b, and WA-2b and the WA-4a opt-out call the same `forget()` |
| Events | the `fa:consent` event is for observers (UI) only; `stop()` and request aborts run only through the controller port |
| Design pass | `frontend-design`, owner review |

Copy (Q3; final sign-off in WA-5):
- DE: **Nutzungsstatistik.** Darf diese Website messen, wie sie genutzt wird? Mit Ihrer Einwilligung speichert Ihr Browser eine zufällige Kennung für 12 Monate. Seitenaufrufe, Klicks und das erfolgreiche Absenden des Kontaktformulars (ohne Inhalte) wertet dann der Betreiber selbst aus, ohne externe Analyse- oder Werbedienste. Ihre Wahl können Sie jederzeit unter «Datenschutz-Einstellungen» am Seitenende ändern. [Datenschutz] `[Ablehnen]` `[Erlauben]`
- EN: **Usage statistics.** May this website measure how it is used? With your consent, your browser stores a random ID for 12 months. Page views, clicks and successful contact-form submissions (never their content) are then analysed by the site owner only, with no external analytics or advertising services. You can change your choice at any time via "Privacy settings" at the bottom of the page. [Privacy] `[Decline]` `[Allow]`

i18n: `analytics.consent.{title, body, bodyMore, privacyLink, accept, decline, current, currentGranted, currentDenied, signalNotice}`, `footer.privacySettings`, `dashboard.subnav.analytics`, `dashboard.analytics.*`.

### 10.2 `src/data/legal.ts` changes (drafted in WA-5; merged only in the WA-6 go-live PR)

| # | Change |
|---|---|
| L1 | New section after "Sicherheitsüberwachung": "Nutzungsstatistik (nur mit Einwilligung)" / "Usage statistics (only with consent)": cookie `fa_vid` for 12 months; data list per §3.8/§3.6; consent basis; GPC/DNT = refusal; withdrawal deletes the identifier and erases the individual events recorded with it from the website's live data. **No server retention period, no location, no backup statement (Q1, Q2)** |
| L2 | "Sicherheitsüberwachung": aggregated per-page request counts without IP addresses also serve as a reference figure |
| L3 | "Cookies" → "Cookies und lokaler Speicher": cookie `fa_vid` (only with consent, 12 months), the cookie `fa_forget` (only while an erasure request could not yet be completed, removed once it succeeds) and the choice in local storage (also when declined, 12 months) |
| L4 | "Ihre Rechte": consent can be withdrawn at any time via "Datenschutz-Einstellungen" |
| L5 | Header comment: dated owner decisions 2026-11-08 (Q1 "Keine Fristen", Q2 "So lassen") and the consent-version bump rule |
| L6 | `updated` and `PAGE_LAST_MODIFIED['/privacy']` bumped |
| L7 | `legal.test.ts`: existing guards unchanged; add needles `fa_vid`, `fa_forget`, `Nutzungsstatistik`/`Usage statistics`, `Datenschutz-Einstellungen`/`Privacy settings`; the section's only duration is "12 Monate"/"12 months" |

---

## 11. Auth, configuration, secrets

| Scope | Client | Used by | Checked by |
|---|---|---|---|
| `analytics:write` (new, WA-0) | `furchert-ch` (`client_credentials`) | forward queue, forget handler | `POST /events`, [WA-5] `DELETE /visitors/{id}` |
| `analytics:read` (new, WA-0) | `furchert-ch` | dashboard | `GET /api/webanalytics/*` |
| `netmon:read` | `furchert-ch` | `/dashboard/network` | `/api/netmon/**` |

One token per scope, never combined; client reused. auth-service: `application.yaml`, idempotent migration (expected V10), `INTERFACES.md`.

| Repo | Name | Default | Purpose |
|---|---|---|---|
| furchert-ch | `ANALYTICS_COLLECT_ENABLED` (env) | `true` | kill switch for `/api/v`, goal, enquiry (forget unaffected) |
| furchert-ch | `ANALYTICS_UI_ENABLED` (code) | `false` until WA-6 | bar, footer link, tracker, goal |
| furchert-ch | `ANALYTICS_CONSENT_VERSION` (code) | `1` | §4.3 |
| furchert-ch | `ANALYTICS_DEV_ORIGIN` (env, optional) | unset | dev `Origin` |
| data-service | `webanalytics.api.write-clients` / `read-clients` | `[furchert-ch]` | `sub` allowlists |
| data-service | `webanalytics.ingest.daily-cap` / `hourly-cap` / `visitor-daily-cap` [WA-5] | `10000` / `2500` / `500` | §6.4 |
| data-service | `webanalytics.retention.events-days` [WA-5] | `396` (min 370) | §7.7 |
| data-service | `netmon.collectors.webanalytics-rollup.enabled` | `false` explicit default (enabled by the WA-3a follow-up through `NETMON_COLLECTORS_WEBANALYTICS_ROLLUP_ENABLED=true`, §7.5) | rollup kill switch |
| data-service | `webanalytics.timezone` | `Europe/Zurich` | day boundaries |

No new env var in data-service or auth-service beyond the WA-3a enable switch; no new SOPS variable or Secret key.

---

## 12. Ownership, compatibility, rollout, rollback

### 12.1 Owner and consumers

| Artifact | Owner | Consumers |
|---|---|---|
| This spec | homelab | all |
| Scopes | homelab-auth-service | furchert-ch, homelab-data-service |
| Tracker, bar, `fa_*`, registry, `/api/v`, forget, goal, enquiry count | furchert-ch | browsers |
| `POST /events`, `DELETE /visitors/{id}`, `GET /api/webanalytics/*` | homelab-data-service | furchert-ch |
| Schema `webanalytics` | homelab-data-service | itself only |
| `netmon.inbound_request_groups` read, `collector_state` row | homelab-data-service | itself |
| Metrics | homelab-data-service | Prometheus |
| `NetmonCollectorStale` daily class change, `WebAnalytics*` rules | homelab | Alertmanager → Discord |
| Privacy text | furchert-ch | visitors |

### 12.2 Compatibility

All additive; **no backwards-incompatible change.** `/api/netmon/status` output is unchanged (filter); `RetentionTarget` gains an optional schema; furchert-ch adds routes, components, an optional `analytics` input, two `FROM_IDS` (mail «Quelle:» may show `about-contact`/`rowing-contact`) and redirect query strings.

### 12.3 Rollout order (aligned with §17)

1. WA-0: spec; auth-service scopes live.
2. WA-1: data-service ingest live; port-forward smoke test.
3. WA-2a, WA-2b: furchert-ch merged dark (the enquiry counter starts counting, §1.4).
4. WA-3a: data-service WA-3a deployed with the rollup **disabled**; homelab daily-class PR merged; the owner runs playbook `41_monitoring.yml`; then the data-service follow-up enables the rollup. Then WA-3b.
5. WA-4a, WA-4b: dashboard (it shows "no data yet" while dark).
6. WA-5 "Compliance & hardening": auth-service side finding; data-service hardening rolled out first; then furchert-ch hardening (dark) and the homelab alerts; owner checks; final texts on the WA-6 branch.
7. WA-6 go-live: one furchert-ch PR (legal text + flag flip); end-to-end checklist right after the flip (no production end-to-end test is possible earlier; accepted); then the homelab `WebAnalyticsIngestSilent` rule.

### 12.4 Rollback

- furchert-ch: `ANALYTICS_COLLECT_ENABLED=false` (pod delete) stops ingest, goal, enquiry; forget keeps working; or revert the go-live PR.
- data-service: rollup kill switch, or the previous image: Flyway ignores applied future migrations by default (`ignore-migration-patterns: *:future`, verify in WA-1 phase 1); never edit or undo a merged migration.
- auth-service: scopes stay (harmless).

---

## 13. Security and privacy notes

- **Controls:** local-only security report (§15) T1 to T13, C1 to C18. Early (WA-1, WA-2b): C1, C2, C4, C6 (signed-in part), C7, C8, C10 to C13, C16 to C18. [WA-5]: C3, C6 bot list, C14, mint limit, per-visitor cap, C5 WAF owner check. Safe because the collect path stays dark until WA-6.
- **Pseudonymous data:** visitor ids in raw rows (internally ≤ 396 days from WA-5); never exposed; no join with netmon IP data; cells < 3 suppressed.
- **Enquiry count (Q4):** a per-day integer created server-side without identifier, content, cookie or device access; not personal data, no device access, so neither consent nor a disclosure is needed. Following the owner rule of 2026-11-07 ("promise nothing the site does not do") and `contact-sources.test.ts` lines 92 to 103, neither the note under the form nor the privacy text makes a counting statement.
- **Erasure and backups (Q2 "So lassen"):** erasure on withdrawal and retention act on live data only; Longhorn snapshots, restic copies and the Mac app-data dumps are not edited and age out on their own rotation (the Mac dumps when the owner deletes them). The privacy text speaks only of erasure from the website's live data and never claims it reaches backups.
- **Cookie visibility:** `Path=/` (needed by the Server Action); visible to Cloudflare, already a listed processor.
- **Operating rules:** never match an enquiry's time to analytics; never paste raw analytics into AI tools.
- **Cloudflare [WA-5 owner checks]:** Web Analytics/RUM beacon and Zaraz off; `/api/v` outside the auth rate-limit rule; optional WAF custom rule `(http.host eq "furchert.ch" and starts_with(http.request.uri.path, "/api/v") and (http.request.method ne "POST" or cf.client.bot))` → Block if `cf.client.bot` exists on Free.

### 13.1 Record of processing (internal; finalised in WA-5)

| Item | Content |
|---|---|
| Controller | Dominic Furchert (furchert.ch) |
| Purpose | measure use of the website to improve the offer |
| Legal basis | consent (CH FMG Art. 45c; EU ePrivacy Art. 5(3) opt-in) |
| Data subjects | visitors who chose Allow |
| Categories | pseudonymous visitor id; paths, engaged time, scroll, section reach; clicks (CTA ids, outbound host, mailto/tel type, nav target, locale switch); contact-success fact; referrer host; utm source/medium/campaign; country; device class; browser/OS family; viewport bucket; page locale. Separately a daily enquiry count (not personal) |
| Recipients | none beyond the controller; Cloudflare transports |
| Retention (internal) | raw 396 days, then id-free aggregates; cookie and choice 12 months fixed; `fa_forget` at most 30 days and only while an erasure is pending; backups per their own rotation |
| TOMs | §5.3, §6, ADMIN-only dashboard, aggregate-only reads, cluster-internal API, identifier-free logs |

### 13.2 DPIA threshold note (finalised in WA-5)

No DPIA: no sensitive data, no high-risk profiling, first party, no third-party recipients, not large-scale systematic monitoring. CH: DSG Art. 22 not met. GDPR Art. 3(2)(b) not assessed by a lawyer (Q5).

---

## 14. Umami v3.4.1 (MIT): adopted vs different

| Topic | Umami | Here |
|---|---|---|
| Endpoint | `POST /api/send` | same-origin `/api/v` |
| SPA pageviews | patches `history.pushState` | `usePathname()` |
| Identity | hash of IP, UA, monthly salt | random id in a server-set cookie after consent |
| Visit | hourly salt + 30 min | 30-min gap in the rollup, 6 h cap |
| Referrer | domain, path, query | host only |
| UTM, click ids | five UTM + click ids | source, medium, campaign |
| Bots | `isbot` | consent + hand-rolled regex |
| Geo | headers or MaxMind, region, city | country only |
| Device | `ua-parser-js`, screen | families; viewport buckets |
| Clicks | `data-umami-event`, delayed navigation | `data-track="<kind>:<id>"`; no delay |
| Transport | `fetch keepalive` | adopted |
| Opt-out | `umami.disabled` | `fa_optout` |
| Consent | DNT only | opt-in; GPC/DNT = decline |
| Bounce | 1 pageview, no event | engaged visit, per landing page |
| Time | last − first event | engaged time, scroll, sections |
| Storage | live queries over raw | raw + nightly id-free aggregates |

---

## 15. Specialist input

Local-only specialist reports (not in this repo), summarised in this section. A = adopted, D = adapted, R = rejected, owner = owner decision. "→ WA-5" = adopted but delivered in the late compliance sub-project.

| Report | Recommendation | Decision | Where / reason |
|---|---|---|---|
| privacy-consent | Opt-in; no consent-free tracker; CF/netmon baseline | A | §1.4, §8.3 |
| privacy-consent | Banner checklist | A | §10.1 |
| privacy-consent | Choice in `localStorage`, 12 months fixed; no consent log | A | §4.2 |
| privacy-consent | Visitor id in `localStorage` | R | K2 server cookie |
| privacy-consent | No client session id | A | §3.2, §7.5 |
| privacy-consent | Minimised fields | A | §3.8, §5.5, §5.7 |
| privacy-consent | GPC/DNT = Decline | A → WA-5 | §4.1 |
| privacy-consent | Delete-on-withdraw | A → WA-5 | §4.4, §5.4, §6.5 (cookie cleared early) |
| privacy-consent | Goal as bare fact, never linked | A | §5.9, §13 |
| privacy-consent | Dashboard aggregate-only | A | §9 |
| privacy-consent | Retention/location in text (OD5) | owner | Q1: neither |
| privacy-consent | Backups vs retention (OD6) | owner | Q2: "So lassen" |
| privacy-consent | Legal drafts | D → WA-5/WA-6 | §10.2 |
| privacy-consent | Record of processing, DPIA note | A → WA-5 | §13.1, §13.2 |
| privacy-consent | Lawyer on Art. 3(2)(b) | owner | Q5: no |
| privacy-consent | CF Web Analytics/Zaraz off; no join; no AI tools | A | §13 (owner check WA-5) |
| privacy-consent | Exclude collect path from per-IP netmon | R | security visibility |
| analytics-metrics | KPIs and definitions | A | §3.1, §8.3 |
| analytics-metrics | Channels incl. AI | A | §8.4 |
| analytics-metrics | Registry, FROM_IDS as CTA ids, new ids, FAQ ids | A | §3.3 |
| analytics-metrics | Section reach, FAQ opens, form start | D | engagement fields, click kind `faq` |
| analytics-metrics | `from` on pageview / goal | R | path-only, fact-only |
| analytics-metrics | Funnels, group paths, entry × exit, seen-before | A | §7.8, §8.5 |
| analytics-metrics | Small-numbers rules, 28-vs-28 | A | §8.6 |
| analytics-metrics | Histogram medians; uniques | D | pre-aggregated uniques |
| analytics-metrics | Dashboard order, filters | A | §9.2, §8.1 |
| analytics-metrics | Do-not-build list | A | §1.3 |
| analytics-metrics | OD1 converting-visit list | R | privacy wins |
| analytics-metrics | OD2 enquiry counter | owner | Q4: yes |
| analytics-metrics | OD3 accept/decline counters | R | privacy §2.4 |
| analytics-metrics | OD4 landing info before Allow | R | nothing before consent |
| analytics-metrics | Tag own links | D | Q6; owner habit (WA-6) |
| tracker-engineering | Mount, singleton, `usePathname`, StrictMode, session wait | A | §3.4, §3.10 |
| tracker-engineering | Engagement, scroll, `fits` | A | §3.5 |
| tracker-engineering | Heartbeat | D | capped at 20 |
| tracker-engineering | `sendBeacon` `text/plain` | R | K1 |
| tracker-engineering | Capture-phase clicks, no delay | A | §3.6 |
| tracker-engineering | Goal via DOM event | R | server-side |
| tracker-engineering | HttpOnly cookie | A | `Path=/`; no `fc_off` |
| tracker-engineering | `/api/v`, presence-check drop, budget, pure modules | A | §5, §3.10 |
| tracker-engineering | 16 KiB / 50 events; 60 req/min | R | K4 |
| tracker-engineering | `after()` without retry | D | ordered queue |
| tracker-engineering | Device from viewport; screen W×H | R | UA/CH families; buckets |
| tracker-engineering | Manual browser checklist | A | WA-2b, WA-6 |
| security-ingest | C1, C2, C4, C7 to C12 | A | §5 (C9 adapted) |
| security-ingest | C3, C6 bot list, mint limit | A → WA-5 | §5.3, §5.8 |
| security-ingest | C13 | A | §6.2 |
| security-ingest | C14 caps | D → WA-5 | all-or-nothing, goal/enquiry exempt |
| security-ingest | C15 partitions, route FK | R | §7.4; page list owned by furchert-ch |
| security-ingest | Rollup 04:30 | R | §7.6 |
| security-ingest | C16 to C18 | A | §9.1, §5.10, §13 |
| security-ingest | Scopes, chains, client reuse | A | §6.1, §11 |
| security-ingest | Auth-service hardening | A → WA-5 | see homelab-auth-service#143 (WA-5), go-live dependency |
| security-ingest | 7 alerts | D | rollup staleness via daily class (WA-3a); 5 rules → WA-5; IngestSilent → WA-6 |
| security-ingest | No CF rate-limit rule; optional WAF rule | A → WA-5 | owner check |
| security-ingest | Runbooks | A → WA-5 | |
| data-model | JDBC, CollectorRunner, no partitioning | A | §7.4, §7.5 |
| data-model | `visit` + `event`, client visit id | R | K5 |
| data-model | `(visit_id, seq)` | D | `(pageview_id, seq)` |
| data-model | Skew correction | D | 15-min window |
| data-model | Replace-per-day, `rollup_day`, version backfill | A | §7.5 |
| data-model | Freeze guard | A → WA-5 | needed only with retention |
| data-model | Rollup 01:15 | D | 01:12 (provisional) + 07:30 (final) |
| data-model | Id-free aggregates, uniques, `daily_cf_path` | A | §7.8 |
| data-model | Locale as path prefix | R | `entry_locale` keys |
| data-model | `RetentionTarget` extension, 396 d | A → WA-5 | §7.7 |
| data-model | Size, PVC measurement, restore test | A | §7.3, WA-1, WA-5 |

---

## 16. Risks and owner questions

| # | Risk | Mitigation |
|---|---|---|
| R1 | Tracker fires before consent | gate tests; DevTools check |
| R2 | Linking analytics to named leads | aggregate-only; operating rules |
| R3 | Mac dumps keep raw ids indefinitely | owner accepted (Q2); privacy text claims nothing about backups |
| R4 | Low consent rate | §8.6; coverage |
| R5 | Forged events | WA-5 limits, caps, alerts; dark until WA-6 |
| R6 | Shared 5 Gi PVC | WA-5 cap (≤ 1.2 GB), size alert |
| R7 | Lost snapshots, at-most-once loss | heartbeat; accepted |
| R8 | CF baseline includes bots, prefetches | separate lines |
| R9 | First 12 months almost everyone "new" | UI note |
| R10 | Content blockers | accepted |
| R11 | Erased visitor's events in flight | abort on withdrawal, queue purge, synchronous delete, tombstone |
| R12 | WA-5 slips while value work is done | go-live depends on WA-5; flag stays off |
| R13 | Two ids minted at consent in browsers without Web Locks; a collect completing after abort and forget leaves an orphan id | documented data-quality limit (§3.9); accepted residual risk (§4.4): orphan ids are unlinkable, expire with raw retention, tombstoned ids reject late events (WA-5) |
| R14 | A forget abandoned on Allow (429 or 503): the old id stays in use (429) or pending in `fa_forget` (503) until the next withdrawal; earlier events stay linked to it | accepted residual (§4.4); the id is pseudonymous, aggregate-only, expires with raw retention |

**Owner questions:** all answered on 2026-11-08 (Q1 to Q7, O1; §1.2). None open.

---

## 17. Delivery plan

Order: **WA-0 → WA-1 → (WA-2a ∥ WA-2b ∥ WA-3a → WA-3b) → (WA-4a → WA-4b) → WA-5 Compliance & hardening → WA-6 Go-live.** Value first (WA-0 to WA-4), one late sub-project for mandatory topics without direct value (WA-5), go-live last (WA-6, depends on WA-5). Everything stays dark until WA-6.

**Per issue:** one branch and PR per repo; a child worklog referencing the parent worklog; a per-repo plan-reviewer pass before coding; "verify in phase 1" items recorded first; the review gate before merge; the checklist items below are acceptance criteria; early issues list what is **deferred to WA-5** and to which WA-5 issue.

| ID | Goal | Lead repo | Other | Depends on | PD |
|---|---|---|---|---|---|
| WA-0 | Contract committed; scopes exist | homelab | homelab-auth-service | — | 1.5 |
| WA-1 | Ingest API, validation, dedupe, enquiry counter, basic metrics | homelab-data-service | — | WA-0 | 2.5 |
| WA-2a | Consent bar, settings link, stop + forget on Decline (dark) | furchert-ch | — | WA-0 | 2.0 |
| WA-2b | Tracker, `/api/v` basic safety, minimal forget, goal, enquiry, registries, redirects (dark) | furchert-ch | — | WA-1 | 4.0 |
| WA-3a | Core rollup (shipped disabled, enabled after the alert gate), core aggregates, read API | homelab-data-service | homelab (daily class) | WA-1 | 4.5 |
| WA-3b | Paths, funnels, audience, CF baseline + backfill, coverage | homelab-data-service | — | WA-3a | 4.0 |
| WA-4a | Dashboard core + never-track switch | furchert-ch | — | WA-3a, WA-2b | 3.5 |
| WA-4b | Dashboard funnel, paths, audience, coverage, previous/next | furchert-ch | — | WA-3b, WA-4a | 3.5 |
| WA-5 | Compliance & hardening | all four | — | WA-0..WA-4 | 5.5 |
| WA-6 | Go-live | furchert-ch | homelab (IngestSilent rule) | WA-5 | 0.5 |
| | **Total** | | | | **31.5** |

### WA-0 (1.5 PD)

**homelab: "WA-0: Commit web analytics spec 100, forwarder and ADR 0002 note"**
- Canonical spec in `infrastructure/docs/`; parent forwarder; `docs/INDEX.md` entry.
- ADR 0002 dated amendment note (push exception).
- `docs/052-architecture-target.md` names schema `webanalytics`, the write path and both scopes.
- §17 issue map filled.

**homelab-auth-service: "WA-0: analytics:write and analytics:read scopes for the furchert-ch client"**
- Idempotent migration (next free number; expected V10); Testcontainers: second run no-op, fresh DB 0 rows.
- `application.yaml` lists both scopes; per-scope tokens with `sub=furchert-ch`, no `role`; `netmon:read` and auth-code tests unchanged.
- `INTERFACES.md`.
- Deferred to WA-5: auth-service hardening, see homelab-auth-service#143 (WA-5).

### WA-1 (2.5 PD)

**homelab-data-service: "WA-1: webanalytics ingest API, validation, dedupe and enquiry counter"**
- Verify in phase 1: Flyway schema handling; `ignore-migration-patterns` default for image rollback; `pg_database_size()` per DB and PVC usage recorded.
- V6 creates schema, `events`, `daily_ingest_stats`, `daily_enquiries`; app starts on a V5 DB.
- Write chain tests: wrong scope 403, foreign `sub` 403, `ROLE_ADMIN` user token 403, GET 405, `no-store` incl. 401/403; write token 403 on `/api/netmon/status`.
- C13 with shared fixtures (canonical file `src/test/resources/webanalytics/c13-fixtures.json`, relative time tokens `now±Nm`): > 200 events → 413 (service-level test; over HTTP the 64 KiB cap answers first); `edgeDrops` outside 0 to 1 000 000 → 400; token with any `ROLE_*` authority → 403; size/depth/unknown property → 400/413; missing key → 400 (strict presence); per-event rejection; duplicates; `(pageview_id, seq)` reuse with a different `eventId` → reason `other`, same `eventId` → duplicate; time window; mailto/tel target rejected; path rule `^/([a-z0-9][a-z0-9-]{0,63}(/[a-z0-9][a-z0-9-]{0,63}){0,2})?$` ≤ 200 chars; `(other)` accepted for nav `clickTarget`, rejected for `path`.
- `daily_ingest_stats` columns, stages and format-only CHECKs; enquiries not counted there, not in `accepted`/`duplicates`; enquiry duplicate within 2 h ignored; invalid enquiry → `rejected`.
- Enquiry: all non-core fields must be `null`; increments `daily_enquiries` with 2 h dedupe, no `events` row, counted in `webanalytics_enquiries_total` only (not in `accepted`).
- Metrics accepted/duplicate/enquiries/rejected/edge-dropped with bounded labels; `INTERFACES.md`, `CHANGELOG.md`, `DEPLOYMENT.md` (rollback note).
- Deferred to WA-5 (WA-5 data-service issue): daily/hourly/per-visitor caps with 429 `capScope`/`retryAt`; `DELETE /visitors/{id}` and tombstones; retention; capped/today/table-bytes gauges.

### WA-2a (2.0 PD)

**furchert-ch: "WA-2a: Consent bar and privacy settings link" (skill: `frontend-design`)**
- Design pass first; owner review.
- Before a choice: zero requests to `/api/v`, zero `setItem` (`removeItem` only for an expired or wrong-version `fa_consent`), no device-property reads (tests + DevTools); equal buttons, Decline first; Esc/close/scroll ≠ consent.
- Decline and withdrawal store `denied` first, stop the tracker, abort in-flight requests (`AbortController`) and only then call forget (stubbed contract test incl. order of operations and `fa_forget_pending` retry).
- `fa_consent` 12 months fixed; version bump re-asks; multi-tab withdrawal.
- Pending-forget rules (§4.4): granted + pending at load → one forget awaited, marker dropped on any answer, then the tracker starts; no stored choice + pending → no network before a choice, the marker is sent with the next choice; the controller owns one serialised `forget()`; the portal host is the first child of `<body>`; async-only consent layer within the §3.10 budgets (post-build CI step).
- Footer link with current state; a11y; Lighthouse: bar not LCP, CLS 0; behind `ANALYTICS_UI_ENABLED = false`; no `legal.ts` change.
- Deferred to WA-5 (WA-5 furchert-ch issue): GPC/DNT auto-decline; final copy sign-off.

### WA-2b (4.0 PD)

**furchert-ch: "WA-2b: Tracker, /api/v with basic safety, minimal forget, goal and enquiry, registries, redirects"**
- Verify in phase 1: `CF-IPCountry` reaches the pod; locale switch soft vs full reload; `fetch keepalive` on `pagehide` (Chrome, Safari macOS/iOS, Firefox) with `Sec-Fetch-Site`/`Origin`; `globalThis` singletons shared in a production build.
- Tracker §3.4 to §3.10 with unit tests (landing rule, engagement, scroll, sections, clicks, transport incl. `AbortController` per request and the Web Locks first-flush serialisation with fallback, singleton, payload hygiene); bundle budget test; `navigator.webdriver` off.
- Registries and wiring (`TRACKED_PATHS`, `NAV_TARGETS`, `TRACK_IDS` ≤ 100 with source test, FAQ ids, `data-track-section`, `track` props); `about-contact`/`rowing-contact`; `contact-sources.test.ts` FROM_IDS regex `/^(automation|home|about|rowing)-[a-z-]+$/` and `CTA_FILES` gains the about and rowing pages; `CHANGELOG.md` notes the new «Quelle:» values.
- `/api/v` basic safety tested: 405, 415, 403 (foreign/missing `Sec-Fetch-Site`+`Origin`), 8 KiB streamed cap incl. chunked, 21 events → 400, unknown key → 400, signed-in drop, `cv`/`consentDate` drop (and no `Set-Cookie` on such a request), canonicalisation (query and fragment stripping, UTM rules, referrer → host, `mailto:x@y` → type only, `/imprint`/`/privacy` dropped), `XX`/`T1` → null, kill switches; forwarded payload never contains IP or UA.
- Copy of the C13 fixtures from data-service with a test asserting the same file version (comment with the data-service commit); forward timeout 10 s, `edgeDrops` zeroed on retries (test).
- Nav click targets and paths are sent in the §6.2 locale-free form.
- Cookie minted only when absent/stale with exact attributes and expiry; minimal forget expires it, is never rate-limited, works with `ANALYTICS_COLLECT_ENABLED=false` and while signed in.
- Goal per §5.9 (server-generated `eventId`; no goal without an existing `fa_vid`, while the enquiry still counts; the form's `analytics` flag follows §4.1; a client-posted goal is dropped); enquiry for every successful submission, server-generated `eventId`, serialised with every other field `null`, live with `ANALYTICS_UI_ENABLED = false` (test); note under the form unchanged.
- Collect completing after abort and forget does not re-set `fa_vid` in the browser (forget runs after the abort and clears again; test); landing pageview flushed immediately on start/Accept; the contact form waits for a pending first flush for at most 1 s, then submits without a goal (test).
- Forward queue: test on the full serialized envelope that both limits (200 events, 48 KiB) hold and that event order is preserved across splits; batches split at 200 events and 48 KiB; a 413 splits and retries without dropping valid events (test); order, retry, circuit, age and C17 logging tested; Q6 redirects with `src/redirects.test.ts`; endpoint-path pin test; `securityHeaders.test.ts` unchanged; `ANALYTICS_COLLECT_ENABLED: "true"` in `k8s/deployment.yaml`; `INTERFACES.md`, `DEPLOYMENT.md`, `.env.local.example`, `CHANGELOG.md`.
- Deferred to WA-5 (WA-5 furchert-ch issue): collect rate limits, forget's own limit, mint limit, bot UA list, 429 `retryAt` pause, forget queue purge and synchronous erasure with `fa_forget`.

### WA-3a (4.5 PD)

**homelab: "WA-3a: NetmonCollectorStale daily class covers webanalytics-rollup"**
- `webanalytics-rollup` in the 26 h daily class regex and in the catch-all exclusion.
- promtool test: stale > 26 h fires the daily class; the catch-all never fires for it; no duplicate YAML key.
- Gate: after merge the owner runs playbook `41_monitoring.yml`; the run is recorded in the issue, and only then is the data-service enable follow-up merged.

**homelab-data-service: "WA-3a: Core rollup, core aggregates and read API"**
- Verify in phase 1: environment binding of `netmon.collectors.webanalytics-rollup.enabled` from `k8s/deployment.yaml`.
- Shipped with `netmon.collectors.webanalytics-rollup.enabled=false`: test that no `netmon_collector_last_success_timestamp_seconds{collector="webanalytics-rollup"}` series exists while disabled; enabling is a separate follow-up PR (`k8s/deployment.yaml`) merged only after the homelab WA-3a PR is merged and playbook `41_monitoring.yml` has run.
- V7 creates the WA-3a tables (incl. `rollup_day.final`); information_schema test for id-free aggregates.
- Rollup with two triggers, 01:12 and 07:30 Europe/Zurich, both through the same `CollectorRunner` lock (test: the two runs never overlap); first run on empty state, 2-day lookback, catch-up, version backfill within 30 days, idempotent (byte-identical), advisory lock, `rollup_day` for empty days; provisional/final rule tested with a fixed clock: the 01:12 run writes yesterday with `final = false`, the 07:30 run rewrites it with `final = true` (yesterday closes at 07:15), so after 07:30 `lastCompleteDay` = yesterday and before it the day before yesterday; provisional days are not served; a skipped 07:30 run is made good by the next 01:12 lookback; `/api/netmon/status` filters by `group()`, excluding the `webanalytics` group (test).
- Data tests: `Σ daily_page.pageviews = Σ daily_visits.pageviews`; `Σ entries = Σ exits = visits`; `new + returning = visitors`; `max(daily) ≤ visitors_7d ≤ Σ daily`; **exact 7-day uniques: one visitor with visits on two different days of the window counts once in `visitors_7d` (and once in `visitors_28d`)**; DST cases (2026-10-25 23:30, 2026-03-29 00:30, midnight crossing); gap and referrer/UTM split; 6 h cut; 30-s merge; bot exclusion; engaged MAX; channels; first-channel from the visitor's earliest landing; new vs returning with an earlier event 300 days back; top-50 `(other)`; entry-locale filter counts a visit once.
- Fixed-clock DST test for the final/provisional close on the spring-forward day 2027-03-28 and a fall-back day.
- Cross-day test for first-known channel: the earliest landing of a visitor is on an earlier day than the rollup day and still decides the channel.
- Visit-model tests: uniques with an excluded visit and with a cross-midnight visit; `raw_events`/`raw_pageviews` exclude the ±6 h margin events; engagement and click events attach to their pageview's visit regardless of gap; `engagedMs` 8 s + 7 s across a reload merge counts as engaged; a visitor is new on D if any visit on D is new; read-API edge cases (§8.1: `to < from`, `kind` optional, month basis, `compare=none`, `lastWindowEnd`); any `ROLE_*` token → 403 on the read chain; `NetmonCollector.group()` filter for `/api/netmon/status`.
- Read chain and JSON contract tests for `/status` (incl. `provisionalDay`), `/overview`, `/pages`, `/pages/detail` (`previous`/`next` `null`), `/clicks`, `/sources`; filter echo; no raw-table reads (test); < 2 s for 365 days measured on the cluster; docs.
- Deferred to WA-5 (WA-5 data-service issue): freeze guard.

### WA-3b (4.0 PD)

**homelab-data-service: "WA-3b: Paths, funnels, audience, CF baseline with backfill and coverage"**
- Verify in phase 1: `edgeResponseContentTypeName` availability (follow-up only).
- V8 tables (incl. `daily_submits`); `DEFINITION_VERSION` bump recomputes the horizon.
- Funnels monotonic, out-of-order not counted; transitions `(entrance)` = `(exit)` = visits; group paths, entry × exit, seen-before.
- **Exact uniques test: one visitor with offer pageviews in visits on two different days within 28 days counts once in `repeat_offer_viewers_28d`, and one visitor active on two days of the same 7-day range counts once in the audience visitors figure.**
- `daily_cf_baseline` one-time backfill when empty (seeded netmon rows), nightly afterwards, `sampled` carried, no IP column; empty-table and idempotency tests.
- `/coverage`: `baselineFrom` = first day with tracked pageviews, comparisons only from there (test with pre-launch CF rows); `consentedSubmits` by submission day (test: a visit starting 23:50 with a goal at 00:10 counts the submit on the second day, matching `daily_enquiries`).
- Contract tests for `/funnels`, `/paths`, `/audience`, `/coverage`, detail `previous`/`next`.

### WA-4a (3.5 PD)

**furchert-ch: "WA-4a: /dashboard/analytics core and never-track switch" (skills: `dataviz`, `frontend-design`)**
- Design pass for the whole page; owner review.
- Gate tests (SignInGate, NoAccess without data call, ADMIN, `DevSubnav` tab).
- Sections 0, 1, 3, 4, 5, 9; 4b sections "not yet available"; §8.6 functions tested; "Data through" shows `lastCompleteDay` (final days only).
- C16 XSS fixtures as text; grep test against `dangerouslySetInnerHTML` and stored-value hrefs.
- Controls validated server-side; ignored filters shown; never-track switch (abort, forget, tracker silent); docs.

### WA-4b (3.5 PD)

**furchert-ch: "WA-4b: Funnel, paths, audience, coverage and page-flow sections" (skills: `dataviz`, `frontend-design`)**
- Sections 2, 6, 7, 8 and drilldown previous/next per the WA-4a design.
- Small-cell rule on paths and funnels; coverage as two lines from `baselineFrom`, band only when both ≥ 50; enquiry coverage by submission day.
- States, DE/EN, lint/typecheck/test/build, docs.

### WA-5 Compliance & hardening (5.5 PD; all of it before go-live, everything still dark)

Order inside WA-5: the auth-service issue and the **data-service issue are rolled out first**; the furchert-ch issue and the homelab alert issue follow only after the data-service WA-5 rollout (the furchert-ch 429 handling, the synchronous erasure and the alerts need its caps, delete endpoint and gauges).

**homelab-auth-service: "WA-5: auth-service hardening (homelab-auth-service#143)" (0.5 PD)**
- Auth-service hardening as specified in homelab-auth-service#143, with tests; `INTERFACES.md` updated.

**homelab-data-service: "WA-5: Caps, erasure with tombstones, retention and freeze guard" (1.5 PD; rolled out before the furchert-ch and homelab WA-5 issues)**
- Daily/hourly caps with 429 `capScope`/`retryAt`, all-or-nothing, seeded from `received_at`; per-visitor cap (`visitor_cap`); goal/enquiry exempt (boundary tests).
- `DELETE /visitors/{id}` erases only that id; 2 h tombstone (`erased`); integration test "batch after DELETE leaves 0 rows".
- `RetentionTarget` schema extension; `webanalytics.events` purged at 396 d; `< 370` fails startup; netmon targets unchanged.
- Freeze guard (a) to (d), with (b) derived from the configured retention (`today − (retentionDays − 1)`): a forced rollup of a purged day is refused and its aggregates stay unchanged; test with a non-default retention value.
- Gauges `ingest_capped`, `events_today`, `raw_table_bytes`; `/status` `dailyCap`, `capped`, `rawRetentionStart`; docs.

**furchert-ch: "WA-5: Abuse limits, durable forget erasure, GPC/DNT and final texts" (2.0 PD; after the data-service WA-5 rollout)**
- Collect rate limits per key and global with `Retry-After`, IPv6 /64, mint limit 5/h, bot UA list (`bots.ts` test table), `Sec-Purpose: prefetch` drop; forget has its own limit (30/min per key) and is never blocked by the collect limits; over its limit it answers 429 with `Retry-After` and keeps `fa_vid`; the tracker keeps `fa_forget_pending` and retries (tests incl. a NAT neighbour exhausting the limit).
- Forward queue honours 429 `retryAt`; goal and enquiry keep flowing.
- Durable forget (§5.4): when both `fa_vid` and `fa_forget` are present both ids are erased (test); purge queued events of the id, wait for the in-flight batch, synchronous `DELETE` with 3 attempts; 204 on success (clears `fa_forget`); 503 with `fa_forget` when data-service is unreachable; the tracker keeps `fa_forget_pending` and the next load's retry erases via `fa_forget` (race tests: queued batch, in-flight batch, data-service down then up; Allow with `fa_forget_pending` set: the pending forget runs first, the tracker starts after it, and the new events are not erased; two concurrent first collects without Web Locks then withdrawal: the cookie id is erased and the orphan id is documented as residual, §4.4).
- GPC/DNT auto-decline stores `denied` (`by: "signal"`) and calls forget once; explicit Allow (`by: "user"`) overrides, also for the goal flag (tests).
- `legal.ts` L1 to L7 (incl. `fa_forget` in L3) and the final bar copy prepared as a reviewed commit on the WA-6 go-live branch (never merged before the flip); owner sign-off of the copy recorded.

**homelab: "WA-5: WebAnalytics alerts, record of processing, runbooks and owner checks" (1.0 PD, plus 0.5 PD integration re-test across repos; after the data-service WA-5 rollout)**
- Five §7.9 WA-5 rules under `homelab-webanalytics`, promtool tests, no duplicate key (IngestSilent follows in WA-6).
- Record of processing and DPIA note finalised in the canonical spec (§13.1, §13.2).
- `DEPLOYMENT.md` runbooks: purge a day after poisoning, change caps, disable ingest, reset the rollup mark; "Cloudflare rules" with the optional WAF rule and "`/api/v` outside the auth rate-limit rule"; backup note per Q2 (dumps unchanged, contain pseudonymous ids); NetworkPolicy unchanged; restore test of `data_service` into a scratch DB with matching `webanalytics` row counts.
- Owner checks recorded: Cloudflare Web Analytics/RUM and Zaraz off; `cf.client.bot`; n8n schedules vs 01:12 and 07:30; PVC usage vs threshold.
- Infra `INTERFACES.md` lists `furchert.ch/api/v`.

### WA-6 Go-live (0.5 PD)

**furchert-ch: "WA-6: Go-live: privacy text and enable consent bar and tracking"**
- Preconditions: every WA-5 issue merged and rolled out (incl. the auth-service fix and the five alerts).
- One PR: `legal.ts` L1 to L7 (no retention period, no location, no backup claim) + `ANALYTICS_UI_ENABLED = true` + `PAGE_LAST_MODIFIED['/privacy']`.
- Flipped-flag bundle check: with `ANALYTICS_UI_ENABLED=true` no consent chunk is referenced from the prerendered HTML.
- End-to-end checklist right after the flip (live site, fresh profile): no request and no `fa_vid` before a choice; Decline → one forget, no `fa_vid`; GPC browser → no bar, one forget; Allow → pageview without reload, `fa_vid` with exact attributes; two tabs allowing at once → one `fa_vid`; one pageview per soft navigation; locale button → `lang` click only; flush on hide/close; bfcache eligible; clicks incl. middle click and Enter; one goal per successful submit, none on failure; enquiry count +1 with and without consent; signed-in browsing and the never-track switch send nothing; withdrawal during an in-flight request leaves no `fa_vid` and erases that id's rows; `ingest.eventsToday` moves within 1 min; the visit appears once its day is final (the next morning after 07:30); `/coverage.baselineFrom` equals the go-live day.
- `/dashboard/network` and `/api/netmon/status` regression check; owner reminded to tag shared links with UTM; PVC usage re-recorded 30 days later (homelab).

**homelab: "WA-6: WebAnalyticsIngestSilent rule" (within the 0.5 PD; after the go-live end-to-end checklist passed)**
- Rule per §7.9 (7 days, info) under `homelab-webanalytics`; promtool test; enquiries do not keep it silent (it reads `webanalytics_events_accepted_total` only).

### Issue map

| Sub-project | homelab | homelab-data-service | homelab-auth-service | furchert-ch |
|---|---|---|---|---|
| Epic | #348 | — | — | — |
| WA-0 | #349 | — | #142 | — |
| WA-1 | — | #53 | — | — |
| WA-2 | — | — | — | #153 (a), #154 (b) |
| WA-3 | #350 (3a daily class) | #54 (3a), #55 (3b) | — | — |
| WA-4 | — | — | — | #155 (4a), #156 (4b) |
| WA-5 | #351 | #56 | #143 | #157 |
| WA-6 | #352 (IngestSilent) | — | — | #158 |

---

## 18. Revision 3 changes

**Owner answers (2026-11-08):** Q1 "Keine Fristen" (no retention period or location in the privacy text; §10.2, §13); Q2 "So lassen" (dumps unchanged; erasure covers live data only; §13, R3); Q3 drafts adopted (sign-off in WA-5); Q4 enquiry counter yes (§5.9, §6.2, §7.2, §13); Q5 no lawyer; Q6 redirect UTM yes (WA-2b); Q7 full scope accepted; O1 value first, compliance and hardening late, go-live last (§1.2, §17).

**Delivery restructure (O1):** WA-5 is now "Compliance & hardening" (server-side erasure with queue purge and tombstones, GPC/DNT auto-decline, rate limits, mint limit, per-visitor cap, daily/hourly cap with `capScope`/`retryAt`, bot list, WAF owner check, alerts, retention and freeze guard, record of processing, DPIA note, final texts, auth-service side finding); WA-6 is go-live. Early stays: consent gating, stop + cookie clearing on Decline/withdrawal (minimal forget), signed-in exclusion, schema/allowlist/size validation on both lines, JSON + same-origin, scopes and allowed-client check, dark-launch flags, the daily-class alert change. Contract parts built late are marked [WA-5].

**Plan-review findings:**

| Item | Change | Sections |
|---|---|---|
| F1 | Rollup staleness via the NetmonCollectorStale daily class; separate rule dropped | §7.5, §7.9, §12.3, §17 |
| F2 | Queue purge, delete ordered after pending batches, 2 h tombstones, integration test (WA-5) | §4.4, §5.4, §6.5 |
| F3 | Every Decline calls forget; principle exception (GPC/DNT part in WA-5) | §1.4, §4.1, §4.4 |
| F4 | Empty state, first run, zero days, one-time CF backfill | §7.5, §7.8, §8.1 |
| F5, F6 | 429 `capScope`/`retryAt`, all-or-nothing; goal/enquiry exempt (WA-5) | §5.10, §6.3, §6.4 |
| F7 | Per-visit fact table rejected; uniform `entry_locale`/`device_class` keys; filters per endpoint, echo | §7.8, §8.1 |
| F8 | Landing rule per document load | §3.4 |
| F9 | `globalThis` singletons, production-build check | §3.10 |
| F10 | Side finding is a go-live dependency (in WA-5) | §17 |
| F11 | FROM_IDS test changes, «Quelle:» CHANGELOG note | §17 WA-2b |
| F12 | IngestSilent after 7 days | §7.9 |
| F13 | WA-3 and WA-4 split; re-estimate | §17 |
| F14 | Erasure on live data only; no backup claim | §13, §10.2 |
| F15 | ~300 B/row, ≈ 1.2 GB at cap, TableLarge 1.5 GiB | §7.3, §7.9 |
| F16 | Forget independent of kill switches | §5.4 |
| F17 | End-to-end checklist right after the flip | §12.3, §17 WA-6 |
| F18 | Visit cap 6 h | §3.1, §7.5 |
| F19 | UTC caps from `received_at`; Zurich ingest stats; `eventsToday` defined | §6.4, §7.2, §8.2 |
| F20 | Next free Flyway number in both repos | header, §7.1, §11 |
| F21 | Stubbed forget contract test in WA-2a; legal text only with the go-live PR | §10.1, §17 |
| F22 | Child worklog and plan-reviewer per issue; rollback notes | §12.4, §17 |
| F23 | `/api/netmon/status` excludes `webanalytics-*` | §7.5, §12.2 |
| RQ4 | Mint limit 5/h; per-visitor cap 500/day (WA-5) | §5.8, §6.4 |
| RQ5 | At-most-once loss accepted | §1.4, §5.10 |
| RQ6 | `Path=/` kept; Cloudflare sees the cookie | §4.2, §13 |

### Revision 3.1 (plan re-review, 2026-11-08)

| Item | Change | Sections |
|---|---|---|
| N1 | Rollup ships with `netmon.collectors.webanalytics-rollup.enabled=false` (no gauge, so the catch-all cannot fire); enabled by a follow-up data-service `k8s/` change only after the homelab daily-class PR is merged and the owner has run playbook `41_monitoring.yml` | §7.5, §7.9, §11, §12.3, §17 WA-3a (both issues) |
| N2 | `WebAnalyticsIngestSilent` moved to WA-6; enquiries use the separate counter `webanalytics_enquiries_total` and do not count toward `webanalytics_events_accepted_total` or `accepted` | §6.2, §7.9, §12.3, §17 WA-1/WA-5/WA-6 |
| N3 | WA-5 order: data-service WA-5 rolled out before furchert-ch WA-5 and the homelab WA-5 alerts | §12.3, §17 WA-5 |
| N4 | Coverage window starts at go-live (`baselineFrom` = first day with tracked pageviews); enquiry counter deliberately live from WA-2b | §1.4, §8.2, §8.3, §9.2, §17 WA-3b/WA-4b/WA-6 |
| N5 | Enquiry events are serialised with every other field `null` | §5.9, §6.2, §17 WA-1/WA-2b |
| N6 | Goal flag = consent granted and either a user grant (`by: "user"`) or no GPC/DNT signal, aligned with §4.1 | §5.9, §17 WA-2b/WA-5 |
| N7 | Freeze guard (b) derived from the configured retention: `day ≥ today − (retentionDays − 1)` | §7.5, §17 WA-5 |
| N8 | §9 subsections renumbered 9.1 to 9.3, §10 subsections 10.1 to 10.2; references updated | §1.2, §9, §10, §15, §18 |

### Revision 3.2 (CodeRabbit design review of homelab PR #353, 2026-11-08)

WA issue numbers (confirmed by the main session): homelab #349 (WA-0), #350 (WA-3a daily class), #351 (WA-5), #352 (WA-6 IngestSilent); data-service #53 (WA-1), #54 (WA-3a), #55 (WA-3b), #56 (WA-5); auth-service #142 (WA-0 scopes), #143 (WA-5 side finding); furchert-ch #153 (WA-2a), #154 (WA-2b), #155 (WA-4a), #156 (WA-4b), #157 (WA-5), #158 (WA-6). The §17 issue map is filled with them.

| # | Item | Sections changed | Affected WA issues |
|---|---|---|---|
| 1 | Withdrawal writes `denied`, aborts in-flight requests via `AbortController`, then calls forget; a late collect `Set-Cookie` is cleared by the later forget; `/api/v` never mints without a current `cv` and a valid `consentDate`. Cross-tab first mint: the first flush per tab is serialised with the Web Locks API (`fa-first-flush`); without it, two ids are a documented data-quality limit (R13) | §3.9, §4.2, §4.4, §5.3, §9.3, §16, §17 WA-2a/WA-2b/WA-4a/WA-6 | furchert-ch #153, #154, #155, #158 |
| 2 | Forget is never subject to the collect rate limits; separate limiter (30/min per key); every forget response clears `fa_vid` first, also when its own limit is hit (superseded by rev 3.3 #2) | §3.10, §5.3, §5.4, §5.8, §17 WA-2b/WA-5 | furchert-ch #154, #157 |
| 3 | Durable erasure [WA-5]: forget purges the queue, waits for the in-flight batch and calls the data-service `DELETE` synchronously with a bounded retry before answering; 503 when unreachable, with a new cookie `fa_forget` (Path=/api/v/forget, 30 d) so the id survives; the tracker keeps `fa_forget_pending` and retries on the next load. Early forget stays cookie-only. Privacy text names `fa_forget` | §2, §4.2, §4.4, §5.1, §5.3, §5.4, §5.10, §6.5, §10.2 (L3, L7), §11, §16, §17 WA-2b/WA-5 | furchert-ch #154, #157, #158; data-service #56 |
| 4 | Goal and enquiry `eventId`s generated server-side (`crypto.randomUUID()`); a submission without an existing `fa_vid` records no goal, the enquiry counter still counts it | §5.9, §17 WA-2b | furchert-ch #154 |
| 5 | Forward batches capped at 200 events and 48 KiB; a 413 splits the batch and retries, never dropping valid events | §5.10, §17 WA-2b | furchert-ch #154 |
| 6 | Final vs provisional days: a day is closed at D + 1 07:15 Zurich (6 h visit cap + 75 min margin). A second daily rollup run at **07:30** Europe/Zurich (after the close; clear of Longhorn 02:00, restic 03:00, retention 04:30/05:30, trim 05:00) rewrites yesterday as `final = true`; the 01:12 run stays and writes yesterday as provisional. `lastCompleteDay` only covers final days, so after 07:30 the dashboard normally shows data through yesterday (before 07:30 through the day before yesterday); provisional days are not served; `/status.provisionalDay` added | §2, §7.5, §7.8, §8.1, §8.2, §9.1, §15, §17 WA-3a/WA-4a/WA-5/WA-6 | data-service #54; furchert-ch #155, #158; homelab #351 (owner check vs 07:30) |
| 7 | Explicit raw-history reads (new/returning, first-known channel, rolling uniques, monthly visitors) and their bound by raw retention (396 d > 365 d id lifetime) | §7.5, §17 WA-3a | data-service #54, #55 |
| 8 | `consentedSubmits` counted by submission day via the new rollup table `daily_submits`, matching `daily_enquiries` | §7.5, §7.8, §8.2, §8.3, §17 WA-3b/WA-4b | data-service #55; furchert-ch #156 |
| 9 | Exact uniques tests: one visitor on two days counts once in `visitors_7d`/`visitors_28d` (WA-3a) and in `repeat_offer_viewers_28d` and the audience figure (WA-3b) | §17 WA-3a/WA-3b | data-service #54, #55 |

### Revision 3.3 (second CodeRabbit round on homelab PR #353, 2026-11-08)

| # | Item | Sections changed | Affected WA issues |
|---|---|---|---|
| 1 | Withdrawal race accepted as documented residual risk: a collect completing after abort and forget, or a second tab's id minted without Web Locks, leaves an orphan pseudonymous id (unlinkable, expires with raw retention, tombstone rejects late events in WA-5); new tests | §4.4, §16 R13, §17 WA-2b/WA-5 | furchert-ch #154, #157 |
| 2 | Forget over its own limit answers 429 with `Retry-After` and keeps `fa_vid`; the tracker retries via `fa_forget_pending`; "clears first" applies to every response except 429 | §4.4, §5.3, §5.4, §5.8, §17 WA-2b/WA-5 | furchert-ch #154, #157 |
| 3 | Goal before `fa_vid`: landing pageview flushed immediately on start/Accept; the form waits at most 1 s for a pending first flush; otherwise no goal (enquiry still counts) | §3.9, §5.9, §17 WA-2b | furchert-ch #154 |
| 4 | Test on the full serialized envelope: both limits hold, order preserved across splits | §17 WA-2b | furchert-ch #154 |
| 5 | Cross-day test for first-known channel (earliest landing on an earlier day) | §17 WA-3a | data-service #54 |
| 6 | Clarification of rev 3.3 item 1: no new collect-route rule (`fa_forget` has `Path=/api/v/forget` and never reaches `/api/v`); instead forget erases both ids when `fa_vid` and `fa_forget` are present | §5.4, §17 WA-5 | furchert-ch #157 |
| 7 | `daily_ingest_stats` columns, stages (`accepted`, `duplicate`, `rejected`, `edge`), reasons and format-only CHECKs; enquiries not counted | §7.2, §17 WA-1 | data-service #53 |
| 8 | Path rule: locale-free pattern, ≤ 200 chars, literal `(other)`; also for nav click targets | §6.2, §17 WA-1/WA-2b | data-service #53, furchert-ch #154 |
| 9 | Same `(pageviewId, seq)` with a different `eventId` → reason `other`; same `eventId` → duplicate | §6.2, §17 WA-1 | data-service #53 |
| 10 | Enquiry counting rules (not in `accepted`/`duplicates`, duplicate ignored, invalid → `rejected`) and strict key presence (missing key → 400) | §6.2, §17 WA-1 | data-service #53 |
| 11 | Any token with a `ROLE_*` authority → 403 | §6.1, §17 WA-1 | data-service #53 |
| 12 | `edgeDrops` values must be integers 0 to 1 000 000, otherwise 400 | §6.2, §6.3, §17 WA-1 | data-service #53 |
| 13 | More than 200 events → 413 (client splits and retries); the 28 event field names listed and checked against the example | §6.2, §6.3, §17 WA-1 | data-service #53 |
| 14 | Shared validation fixtures canonical in data-service (`c13-fixtures.json`, `now±Nm` tokens); furchert-ch copies them and asserts the file version | §6.2, §17 WA-1/WA-2b | data-service #53, furchert-ch #154 |
| 15 | Paired timeouts: data-service `statement_timeout` 2 s, furchert-ch forward timeout 10 s, no `synchronous_commit = off` | §5.10, §6.2 | data-service #53, furchert-ch #154 |
| 16 | Retries send `edgeDrops` zeroed; remaining replay double-count accepted as data-quality residual | §5.10 | furchert-ch #154 |
| 17 | Forget erases both ids when `fa_vid` and `fa_forget` are present (replaces the withdrawn collect-route rule of item 6) | §5.4, §17 WA-5 | furchert-ch #157 |
| 18 | Re-consent while a forget is pending: the pending forget runs first, the retry runs only while the choice is not `granted`; test | §4.4, §17 WA-5 | furchert-ch #157 |
| 19 | DST handling of the final/provisional close; fixed-clock DST test | §7.5, §17 WA-3a | data-service #54 |
| 20 | Forget worst case about 22 s, keepalive fetch without blocking the UI; `statement_timeout` wording softened (replay idempotent) | §5.4, §6.2 | furchert-ch #157, data-service #53 |
| 21 | Wording: late `fa_vid` cleared except on 429 or network failure; `fa_forget` in the retention row; invalid enquiries not in `daily_ingest_stats`; §7.6 mentions the 07:30 run; ADR/spec aligned to decisions 1 and 2 | §4.4, §7.2, §7.6, §13.1 | none |

### Revision 3.4 (spec follow-up after the WA-1 to WA-3a reviews, 2026-11-08)

| # | Item | Sections changed | Affected WA issues |
|---|---|---|---|
| 1 | More than 200 events → 413 is unreachable over HTTP (the 64 KiB cap answers first, at about 115 full events); kept as a defensive, service-level check | §6.2, §17 WA-1 | data-service #53 |
| 2 | data-service cannot reject locale-prefixed paths (the pattern allows `/de/x`); furchert-ch canonicalises and is responsible | §6.2 | data-service #53, furchert-ch #154 |
| 3 | `(other)` is valid only for nav click targets, not for `path` | §6.2 | data-service #53, furchert-ch #154 |
| 4 | `fa_forget` carries one or two ids separated by `.` (only those not yet deleted); "abandoned" = any answer other than 204; `fa_forget_pending` removal also after a pending-forget run; residual for an abandoned Allow-triggered forget (503 and 429), R14 | §4.2, §4.4, §5.4, §16 | furchert-ch #157 |
| 5 | Pending-forget rules: granted + pending at load → forget, await, drop the marker, then start; no choice + pending → no network before a choice | §4.4, §17 WA-2a | furchert-ch #153 |
| 6 | Removing an expired or wrong-version `fa_consent` record before a choice is allowed (`setItem` stays zero) | §1.4, §4.2 | furchert-ch #153 |
| 7 | The controller owns one serialised `forget()`; `fa:consent` is observer-only | §10.1, §17 WA-2a | furchert-ch #153, #154 |
| 8 | The consent bar portal host is the first child of `<body>` | §10.1, §17 WA-2a | furchert-ch #153 |
| 9 | §3.10 budget re-baselined: consent layer async-only, controller ≤ 2.75 KB, bar ≤ 1.0 KB, link ≤ 0.75 KB gzip, one controller chunk, post-build CI step | §3.10, §17 WA-2a | furchert-ch #153 |
| 10 | `bodyMore` added to the §10.1 key list; flipped-flag bundle check in the WA-6 checklist | §10.1, §17 WA-6 | furchert-ch #153, #158 |
| 11 | `consentDate` validity = `consentExpired()` (age 0 to 364 days, 1 day skew) instead of the 365-day literal | §5.2 | furchert-ch #154 |
| 12 | Tracker budget re-baselined (async-only, one chunk, measured + 10 %, at most 6 KB) | §3.10 | furchert-ch #154 |
| 13 | `/ki` and `/bau` redirects carry `utm_source=print&utm_medium=shortlink&utm_campaign=ki` or `bau` | §3.3 | furchert-ch #154 |
| 14 | "Key event" defined: `cta` click, contact intent, `formStarted`, goal | §8.3 | data-service #54 |
| 15 | Read API `range` echo `{from, to, days, lastCompleteDay, previous}` and the empty state | §8.1 | data-service #54 |
| 16 | Any `ROLE_*` token → 403 on the read chain | §8.1, §17 WA-3a | data-service #54 |
| 17 | "Id-free" = no uuid and no `visitor_id`/`visit_id` column; count columns named `visitors…` are fine | §7.8 | data-service #54 |
| 18 | Rollup enable through `NETMON_COLLECTORS_WEBANALYTICS_ROLLUP_ENABLED=true` in `k8s/deployment.yaml` (`SPRING_APPLICATION_JSON` only as an alternative); the explicit YAML `false` default stays mandatory | §7.5, §11 | data-service #54 |
| 19 | `NetmonCollector.group()`; `/api/netmon/status` filters by group | §7.5, §17 WA-3a | data-service #54 |
| 20 | Uniques from the visit model (non-excluded visits starting in the window); a visitor is new if any visit on D is new | §7.5, §17 WA-3a | data-service #54 |
| 21 | `raw_events`/`raw_pageviews` defined (±6 h margin excluded) | §7.8, §17 WA-3a | data-service #54 |
| 22 | Engagement and click events attach by `pageviewId` regardless of gap | §7.5, §17 WA-3a | data-service #54 |
| 23 | `engagedMs` MAX per original `pageviewId`, SUM across merged ids; "within 30 s" = ≤ 30.000 s | §7.5 | data-service #54 |
| 24 | Batch INSERT instead of INSERT … SELECT (documented deviation); `tel` in contact intent | §7.5, §3.1 | data-service #54 |
| 25 | Read API edge cases: `to < from`, `kind` optional, month basis, `compare=none`, `lastWindowEnd` | §8.1, §17 WA-3a | data-service #54 |
| 26 | Continuous activity beyond 6 h is cut: documented data-quality limit | §7.5 | data-service #54 |
| 27 | `fa_forget` separator is `.` (valid cookie octet; `,` is not) | §4.2, §5.4 | furchert-ch #157 |
| 28 | §7.5 rollup selection aligned with the WA-3a rulings: gap scan, one `eligible(day, now)` predicate, final from the clock, failed lock stops the run, first run at 07:30, `last_window_end` = newest day of the all-final prefix | §7.5, §8.2 | data-service #54 |
| 29 | Timed and load-time forget retry only with a stored `denied` choice or opt-out, never before a choice | §4.4 | furchert-ch #153, #154 |
| 30 | Residual for an abandoned forget on Allow with a 429 (same id stays in use): R14 | §4.4, §16 | furchert-ch #153, #157 |
| 31 | `consentExpired()` is the single "12 months" rule; skew applies to future dates only | §5.2 | furchert-ch #154 |
| 32 | §17 criteria aligned: WA-3a filters by `group()`, WA-2a zero `setItem` (`removeItem` only for an invalid record), WA-1 `(other)` only for nav `clickTarget` | §17 WA-1/WA-2a/WA-3a | data-service #53, #54, furchert-ch #153 |
| 33 | Daily visitors and new/returning from the non-excluded visit model | §7.8 | data-service #54 |
| 34 | For `to < from` after clamping `lastCompleteDay` keeps its known value | §8.1 | data-service #54 |

### Committed (2026-11-08, WA-0)

Revision 3.3 committed with these differences from the working draft: status Accepted, Epic and Parent worklog lines, auth-service migration expected V10, and the WA-5 auth-service hardening referenced by issue only (`homelab-auth-service#143`).
