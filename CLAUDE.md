# CLAUDE.md

TransparaSpec (T-Spec) is a social/short-video platform. The team is the user + Claude. Read `docs/architecture.md` and the ADRs in `docs/adr/` before designing anything new.

## Pillars (every feature must respect these)
1. **Transparency and control.**
   - The ranker must stay decomposable: `score = Σ w·f`.
   - Every served item's contribution trace is saved to `impressions` at serve time.
   - "Why am I seeing this?" reads the saved trace and **never recomputes** it.
   - Keep the invariant `final_score == Σ contributions` under test.
2. **Data dividend readiness.**
   - Every engagement event and impression records `consent_version`, via `Events.record/2`.
   - Money is integer micro-units (`bigint`), never floats.
   - Each ledger transaction's entries sum to zero.
3. **Fair, public revenue sharing** (ADR 0009).
   - Revenue splits platform / creators / viewers using a versioned `revenue_split_policies` row that every ledger transaction references.
   - Creator subscription share is allocated per subscriber.
   - Purchase attribution is tap-only.
   - Reversals are compensating entries, never edits.
   - **Monetization signals never feed the content ranker.** Ads go in labeled slots outside it.
   - The `Ads` context assigns overlay / post-roll / lead-in to host videos in a pass *after* ranking, for the free tier only (ADR 0010).
   - Lead-ins are always labeled with the creator they support, and move as a pair with their host.
   - No forced pre-roll on short-form.
   - Only viewable impressions are billed or credited.
   - `creator_earnings` is derived from the ledger and must reconcile to it.

## Layout
- `apps/client`: Expo + Expo Router (iOS/Android/Web), TypeScript, TanStack Query, generated API client.
- `apps/server`: Elixir/Phoenix monolith. Contexts: Accounts, Content, Social, Events, Feed, Transparency, Moderation, Ledger, Billing. Uses Oban for jobs and Channels for push.
- `services/ml`: Python FastAPI, stateless. Called only from Oban jobs. Returns scores and topics, never approve/reject booleans.
- `packages/api-schema`: OpenAPI spec exported from the server, plus the generated TS client. Regenerate after any API change.
- `infra/`: Fly.io configs and scripts. `docs/`: requirements, architecture, ADRs, roadmap, open questions.

## Conventions
- **Content**: new content kinds are a payload table on top of `content_items` (ADR 0008). Don't create parallel content systems.
- **Video**: access goes only through the `VideoProvider` behaviour. Video bytes never pass through Phoenix.
- **Rust**: only when profiling justifies it, for ranking or graph hot paths (ADR 0004).
- **Decisions**: architecture-shaping decisions get a new ADR in `docs/adr/` and a row in its README. Resolve items in `docs/open-questions.md` as they're decided.
- **Testing**: ExUnit + StreamData property tests on the server; Jest + RNTL on the client; Maestro/Playwright end-to-end.
- **User background**: strongest in Go, some Elixir and Rust, new to recommender systems. Explain Elixir idioms and recommender concepts when introducing them.
