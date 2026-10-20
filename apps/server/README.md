# T-Spec server

Elixir/Phoenix API (ADR 0002). See the root `README.md` for setup and `docs/architecture.md` for the design.

```bash
mix setup          # deps, DB (Postgres on :5440 via docker compose), assets
mix phx.server     # http://localhost:4000 — dev mailbox at /dev/mailbox, dashboard at /dev/dashboard
mix test           # includes an ffmpeg-tagged pipeline test (skipped if ffmpeg is missing)
mix precommit      # compile --warnings-as-errors, format, test
```

Contexts: `Accounts` (sign-in, onboarding, consent, profiles), `Social` (follows), `Content` (items, payloads, provider events), `Video` (provider behaviour + LocalProvider/CloudflareStream), `Events` (append-only engagement log), `Feed` (Latest/Following).
