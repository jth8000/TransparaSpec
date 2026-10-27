# TransparaSpec (T-Spec)

T-Spec is a social and video-sharing platform where you can see, and steer, the recommendation algorithm. It's also designed so that users could eventually be paid for the revenue their data generates.

**Status: pre-beta, under active development, not production-ready.**

Expect breaking changes. Do not run this with real users or in production. There is no formal support. This is a personal project exploring what transparent, user-controllable recommendation systems and fairer creator/user economics could look like. It may or may not ever reach a private beta.

Phase 0 (foundations) and Phase 1a (transparent ranker with live controls and "Why?" explanations) are complete. Phase 1b (ML service for content understanding) is next.

## AI assistance disclosure

The large majority of the design elaboration, implementation, tests, and documentation in this repository was produced with heavy assistance from Claude (Anthropic). I (the repository owner) set the product direction, made the key decisions, reviewed the work, and own the project. I am not an Elixir/OTP, distributed-systems or security expert; the more sophisticated concurrency and ranking machinery should be treated accordingly. Before any private beta, the code base needs review by experts in those areas.

## Pillars
1. **Algorithm transparency and control.** Every recommendation comes with an exact "why", and you can change the weights and watch your feed re-rank live.
2. **Data dividend** (planned). A share of ad and subscription revenue is attributed back to the users whose data generated it.
3. **Fair creator pay** (planned). Each subscriber's money goes to the creators *they* watch, with no view threshold. Creators also get a share of the ad revenue their content earns. The revenue split is public.

## Stack

| Piece | Technology |
|---|---|
| Client | Expo (React Native + web), TypeScript: `apps/client` |
| Server | Elixir/Phoenix, Postgres + pgvector, Oban: `apps/server` |
| ML | Python FastAPI: `services/ml` |
| Video | Managed provider (Cloudflare Stream / Mux) |
| Hosting | Fly.io + Cloudflare |

## Docs
- [Requirements](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [How the For You ranker works](docs/ranking.md): the math, with the real defaults
- [Decision records](docs/adr/README.md)
- [Roadmap](docs/roadmap.md)
- [Open questions](docs/open-questions.md)

## Getting started

Prerequisites:
- **Erlang/Elixir** via [mise](https://mise.jdx.dev): `.tool-versions` pins OTP 28 + Elixir 1.20.
- **Node 24** via nvm (`nvm use`).
- **Docker**, for Postgres + pgvector on port 5440.
- **ffmpeg**, for the local video provider.
- **Android SDK + emulator** (`ANDROID_HOME`) for Android.

```bash
make setup     # start Postgres, create/migrate the DB, install deps
make dev       # Phoenix API on :4000 (dev mailbox with sign-in codes: /dev/mailbox)
make web       # Expo web on :8081
make android   # build + run on a running emulator (first build ~5 min)

make test      # server tests, client typecheck/lint/tests, API-client drift check
make e2e       # Playwright: upload → follow → watch, and the transparent-ranking flow, on web
make api-gen   # regenerate the OpenAPI spec + TS client after API changes
(cd apps/server && mix tspec.seed_demo)   # demo creators + topic-labeled videos for For You
```

In development, videos go to a local ffmpeg-based provider (`tmp/dev_media`). To use Cloudflare Stream instead, set `VIDEO_PROVIDER=cloudflare` plus `CF_ACCOUNT_ID`, `CF_STREAM_TOKEN`, `CF_WEBHOOK_SECRET` and `CF_CUSTOMER_SUBDOMAIN`.

## Security

Please report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

[AGPL-3.0](LICENSE). If you run a modified version as a network service, you must offer its source to that service's users.

Topics come from the [IAB Tech Lab Content Taxonomy](https://github.com/InteractiveAdvertisingBureau/Taxonomies) v3.1 (CC BY 3.0); see [NOTICE](NOTICE).

