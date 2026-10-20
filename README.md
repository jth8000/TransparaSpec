# TransparaSpec (T-Spec)

T-Spec is a social and video-sharing platform where you can see, and steer, the recommendation algorithm. It's also built to eventually pay users for the revenue their data generates.

**Status:** planning complete; Phase 0 (foundations) next.

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
- [Decision records](docs/adr/README.md)
- [Roadmap](docs/roadmap.md)
- [Open questions](docs/open-questions.md)
