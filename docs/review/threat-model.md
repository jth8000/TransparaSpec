# Threat model (server)

Covers the Phoenix API as it is now: pre-beta, never deployed, with no money flowing yet. The client side comes in a later part of this packet. Known gaps that already have a decision pending are in [`SECURITY.md`](../../SECURITY.md) and [`docs/open-questions.md`](../open-questions.md); this page doesn't repeat them beyond a pointer.

## What we protect

| Asset | Where it lives | Why it matters |
|---|---|---|
| Account access | Bearer tokens (`users_tokens`, context `api`, SHA-256 hashed, 60 days); sign-in codes (`login_codes`, HMAC with `LOGIN_CODE_SECRET`, 10 minutes, 5 guesses); magic-link tokens (SHA-256 hashed, 15 minutes) | Whoever holds a token is the user. |
| Viewing history | `engagement_events`, `impressions` (both partitioned by month), `view_engagements` | It reveals what someone watched, and when. |
| Interest profile | `user_topic_affinity`, `user_creator_affinity`, learned from views | An inferred profile; the user can inspect and erase it. |
| Algorithm settings | `user_algorithm_settings`, `algorithm_settings_snapshots` | They steer the user's feed, and every impression records them. |
| Creator content | `content_items` and payload tables; video bytes at the provider | Integrity and availability of uploads; removal must stick. |
| Consent record | `consents`, plus `consent_version` on every event and impression | Pillar 2: data use must match what was consented. |
| Money (future) | Ledger, not built yet (Phase 3) | Out of scope until it exists. |

Birthdates are checked at onboarding and never stored, only the attestation time (`age_attested_at`).

## Who might attack

- **Anonymous internet clients.** They can reach sign-in, public reads, the webhook endpoint and the WebSocket upgrade.
- **Signed-in users.** They can reach everything onboarded users can, and try to read or change other users' data, or skew shared rankings (trending, quality, co-engagement) with fabricated events.
- **Someone who controls a user's inbox, or a link scanner inside it.** They can use the magic link or the code.
- **The video provider, or someone forging its webhooks.**
- **A compromised dependency.** CI runs `make security`, and Dependabot proposes updates.
- **An operator with database access.** Tokens and codes are stored hashed, so a database dump doesn't hold usable credentials.

## Trust boundaries

```
Expo client ──HTTPS/WSS──▶ Phoenix API ──▶ Postgres
  (untrusted)                │  ▲
                             │  └── webhooks (HMAC) ── video provider
                             └──▶ Oban jobs ──▶ video provider API, ML service (planned, Phase 1b)
```

- **Everything the client sends is untrusted.** That includes engagement events (see [open-questions](../open-questions.md), "Engagement abuse"), positions on the feed channel, and session ids, which the client mints.
- **Video bytes never pass through Phoenix in production.** The client uploads straight to the provider. The provider calls back with a signed webhook.
- **The ML service (Phase 1b) will be called only from Oban jobs,** and returns scores, never decisions (ADR 0003).

## Entry points

`/dev/*` routes and the local video provider are compiled into dev and test only. [prod_config_test](../../apps/server/test/tspec/prod_config_test.exs): "production never registers or serves the local video provider".

| Entry point | Auth | Limits | Notes |
|---|---|---|---|
| `POST /api/auth/request` | none | per client address: 10 per 10 minutes (per node); per email address: 5 an hour, 10 a day (Postgres, exact) | Always 202 for a well-formed email, so it doesn't reveal whether an account exists. Creates the account on first use. |
| `POST /api/auth/verify` | none | per client address: 30 per 10 minutes (per node); per code: 5 guesses | `{email, code}` or `{email, token}`. The token must match the email (I3 in [concurrency.md](concurrency.md)). |
| `DELETE /api/auth/session` | bearer | — | Revokes the token and closes its sockets (I4). |
| Public `GET`s: `/api/health`, `/consent/current`, `/topics`, `/users/:handle`, `/content/:id`, `/feed/latest` | none | — | `content/:id` shows ready public items, or the caller's own non-removed items. |
| `GET /api/me`, `POST /api/onboarding` | bearer | — | Onboarding rejects under-13s and deletes the account. |
| Everything else under `/api` (content, follows, feeds, events, algorithm settings, interests, impressions) | bearer and onboarded | none yet on `POST /api/events` | Owner checks are in the contexts (`get_own_item/2`, user-scoped queries). Events: at most 100 per batch, timestamps within 7 days, only content the caller can see. |
| WebSocket `/socket?token=` | bearer (at connect) | — | The token is filtered from logs. `user:<id>` is joinable only for your own id. `feed_session:<uuid>` is namespaced by user id in both the `:global` name and the PubSub topic, so a guessed session id reaches only your own session. |
| `POST /api/webhooks/video/:provider` | HMAC over the raw body | body at most 8 MB (413 above) | Cloudflare: `time` must be within 5 minutes; a replay inside that window is applied idempotently. |
| `/` and the server-rendered pages | none | — | Nonce-based CSP (`TSpecWeb.ContentSecurityPolicy`). Only the home page exists in production. |

## Controls already in place

- **Credentials at rest:** API tokens, magic-link tokens and sign-in codes are stored only as hashes or HMACs ([api_login_test](../../apps/server/test/tspec/accounts/api_login_test.exs): "stores only an HMAC of the code"; [api_login_test](../../apps/server/test/tspec/accounts/api_login_test.exs): "are stored hashed").
- **Sign-in:** per-address and per-email limits (I1, I2); a magic link that doesn't sign in until the user taps it, and only for the address it names (I3).
- **Rate limits per client address,** keyed on `Fly-Client-IP` in production ([rate_limit_test](../../apps/server/test/tspec_web/rate_limit_test.exs): "comes from the configured proxy header, so limits are per real client").
- **Logs:** `token`, `code`, `secret` and `password` parameters are filtered.
- **Request bodies:** no multipart parsing in production; webhook bodies are capped ([video_webhook_controller_test](../../apps/server/test/tspec_web/controllers/video_webhook_controller_test.exs): "a body over the parser's limit is refused, not buffered").
- **Transport:** TLS to Postgres with certificate verification by default ([prod_config_test](../../apps/server/test/tspec/prod_config_test.exs): "the database connection uses verified TLS unless DATABASE_SSL=false").
- **Static analysis and advisories:** `make security` runs `mix hex.audit`, Sobelow and the npm audit check in CI, on every push and weekly. Sobelow false positives are marked in the code with the reason.

## Known gaps

Tracked elsewhere, listed here so a reviewer sees the whole picture:

- **Engagement events are client-reported.** There's no view attestation and no rate limit on `POST /api/events`. Shared rankings count distinct users, but sybil accounts are cheap. ([open-questions](../open-questions.md))
- **The web client keeps its bearer token in `localStorage`.** ([open-questions](../open-questions.md), "Web sessions")
- **No moderation, reporting, CSAM matching, account export or account deletion yet.** (Phase 2, [roadmap](../roadmap.md))
- **Per-address rate limits are per node.** With N nodes, each address effectively gets N times the limit. The per-email caps are exact.
- **No admin interface or role.** LiveDashboard is dev-only.
