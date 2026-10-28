# AGENTS.md

Instructions for AI coding agents working in this repo. This is the canonical file: `CLAUDE.md` imports it for Claude Code, and Codex reads it directly. `apps/server/AGENTS.md` and `apps/client/AGENTS.md` add framework-specific rules.

TransparaSpec (T-Spec) is a social/short-video platform. The team is the user plus AI coding agents (Claude Code, Codex). Read `docs/architecture.md` and the ADRs in `docs/adr/` before designing anything new. Before touching ranking, interests or feed sessions, read `docs/ranking.md`: the plain-language spec of the ranker with its real defaults.

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
- `apps/server`: Elixir/Phoenix monolith. Contexts: Accounts, Content, Social, Events, Feed, Transparency, Moderation, Ledger, Billing. Uses Oban for jobs and Channels for push. Ranking lives in `TSpec.Feed` (`Candidates` → pure `Ranker` → `Ranking.serve` writes impressions; `Session` per client feed; `Interests` learns per view).
- `services/ml`: Python FastAPI, stateless. Called only from Oban jobs. Returns scores and topics, never approve/reject booleans.
- `packages/api-schema`: OpenAPI spec exported from the server, plus the generated TS client. Regenerate after any API change.
- `infra/`: Fly.io configs and scripts. `docs/`: requirements, architecture, ADRs, roadmap, open questions.

## Conventions
- **Content**: new content kinds are a payload table on top of `content_items` (ADR 0008). Don't create parallel content systems.
- **Video**: access goes only through the `VideoProvider` behaviour. Video bytes never pass through Phoenix.
- **Rust**: only when profiling justifies it, for ranking or graph hot paths (ADR 0004).
- **Ranking docs**: `docs/ranking.md` must describe what the code does. Change a weight, formula or rule, and update it in the same commit. `test/tspec/docs/ranking_doc_test.exs` checks its defaults table.
- **Pull requests: one per milestone, not one per phase.** The human reviewer reads every PR, so each must be reviewable in one sitting.
  - Branch per milestone (`phase-1b/m1-ml-service`), PR into `main`. If the next milestone needs one that isn't merged yet, stack it: base its branch and PR on the previous milestone's branch (GitHub retargets it to `main` when that merges).
  - Aim for under ~1,500 lines of hand-written logic per PR. If a milestone grows past that, split it.
  - Fixes from a review round go in their own PR (or as new commits on the open one), never folded into a later milestone.
  - In the PR description, split the line count into logic, tests and generated/vendored code, and say where to start reading.
  - Plan milestones with PR size in mind; a plan that implies one huge PR should be re-cut.
- **Security checks** (`make security`):
  - A Sobelow false positive gets `# sobelow_skip ["<Check>"]` above the function, with a comment saying why it's safe. Never skip a whole check class.
  - An npm advisory that can't reach the app bundle goes in `scripts/npm-audit-allowlist.json` with the reason. Fix or upgrade anything else.
  - Inline `<script>` and `<style>` tags in server-rendered HTML need `nonce={@csp_nonce}` (`TSpecWeb.ContentSecurityPolicy`).
- **Decisions**: architecture-shaping decisions get a new ADR in `docs/adr/` and a row in its README. Resolve items in `docs/open-questions.md` as they're decided.
- **Testing**: ExUnit + StreamData property tests on the server; Jest + RNTL on the client; Maestro/Playwright end-to-end.
- **User background**: strongest in Go, some Elixir and Rust, new to recommender systems. Explain Elixir idioms and recommender concepts when introducing them.

## Commands
- `make setup` / `make dev` (API :4000) / `make web` (:8081) / `make android`
- `cd apps/server && mix tspec.seed_demo`: demo creators and topic-labeled content for For You (dev, idempotent)
- `make test`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, client `tsc` + `expo lint` + `jest`, and `make api-check`
- `make e2e`: Playwright web flow. It reads sign-in codes from `GET /dev/mailbox/json`.
- `make security`: `mix hex.audit`, Sobelow and the npm advisory check. Needs the network; CI runs it on every push and weekly.
- `make api-gen`: run after any API change, and commit the regenerated `packages/api-schema`
- Shells need mise activated for Erlang/Elixir (`eval "$(mise env -s bash)"`) and Node 24 (`nvm use`).

## Gotchas learned in Phase 0
- **Server**:
  - API controllers use `OpenApiSpex.Plug.CastAndValidate`, so request bodies arrive as schema structs. Test conns must send JSON: use `json_conn/0`.
  - Partition DDL (`Events.PartitionWorker`) deadlocks against concurrent sandboxed tests, so its test is `async: false`.
- **Client (Expo SDK 58 / RN 0.88 / TS 6)**:
  - Check versioned Expo docs, not memory (see `apps/client/AGENTS.md`).
  - TS 6 doesn't auto-include `@types/*`; `tsconfig.json` lists `types`.
  - React Native Testing Library v14 is async: `await render(...)`, `await rerender(...)`.
  - `expo/fetch` rejects React Native's `{ uri, name, type }` FormData parts. Use an `expo-file-system` `File`.
  - The React Compiler is on. Components that drive `expo-video`'s imperative player opt out with `'use no memo'`.
  - On Android, use `player.replay()` to restart an ended video.
- **Video**: the dev/test `LocalProvider` is the only place video bytes touch Phoenix. Never enable `:local_video` in production.

## Gotchas learned in Phase 1a
- **Server**:
  - `Feed.Session` processes run under the app's supervisors, outside the test process. Tests that start sessions (directly, via `/api/feed/for-you`, or the feed channel) must be `async: false` and call `on_exit(&TSpec.DataCase.stop_feed_sessions/0)`.
  - Sessions are registered with `:global` (one owner per cluster). `test/tspec/feed/session_cluster_test.exs` starts a real second node with `:peer`; it needs `epmd`, which ships with Erlang.
  - When a race needs a precise pause point, give the function a small test seam in its options (e.g. `apply_dirty_views(user, before_upsert: fn -> … end)`) rather than relying on timing.
  - Tests that need *real* concurrent transactions (lock waits, late commits) use `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` in an `async: false` module and must delete what they commit. See `test/tspec/feed/interests_concurrency_test.exs`.
  - `jsonb` stores numbers as decimals and has no `-0.0`; ranker contributions are normalized so stored traces stay bit-identical to what ranked.
  - A partitioned table's primary key must include the partition key: `impressions` is keyed `(id, served_at)`, with `served_at` taken from the UUIDv7 id (`Impression.served_at_for/1`).
  - Concurrency-sensitive code gets a mutation check: break the guard (a lock, the delta-of-delta, the stale-version check) and confirm a test fails.
  - `make dev` runs `iex`, which exits immediately without a terminal. For a background server use `cd apps/server && mix phx.server`.
- **Client**:
  - Don't start Expo with `CI=1` while developing: it turns off Metro's file watching, so edits never reach the running bundle.
  - New routes need `expo start` to run once to regenerate typed routes (`.expo/types/router.d.ts`) before `tsc` passes.
  - The React Compiler lint rejects reading refs during render and synchronous `setState` in effects; use the "adjust state during render" pattern or give helper objects a setter called from an effect (see `useSettingsEditor`).
  - Charts use validated palette slots, never ad hoc colors (`dashboard-panel.tsx`; in Claude Code, the dataviz skill).

