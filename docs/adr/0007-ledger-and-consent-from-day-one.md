# ADR 0007: Ledger and consent from day one

- **Status:** Accepted
- **Date:** 2026-10-20

## Context
The data dividend (paying users for revenue their data generates) won't launch with the beta, and may be delayed further by legal, tax and fraud work. If the data needed to attribute revenue isn't captured from the start, it can never be reconstructed, and users can't be paid fairly for the time before launch.

Revenue model: **ads + subscriptions**.

## Decision
Build these in Phase 0–1, even though no money moves:
- **Versioned consent records.** Every engagement event and impression stores the `consent_version` in force when it happened.
- **Append-only engagement events and impressions** (ADR 0006).
- **A double-entry ledger** (`ledger_accounts`, `ledger_transactions`, `ledger_entries`, `revenue_periods`).
  - Amounts are integer **micro-units** (`bigint`); no floats ever.
  - Each transaction's entries must sum to zero (property test plus DB constraint/trigger).
- **Hybrid attribution:**
  - **Ads**: direct, per ad impression × realized CPM to the viewer.
  - **Subscriptions**: a per-period pool (X% of net) shared by contribution units.
- **"Your data's estimated value" page** showing accrued (unpaid) balances.

Deferred until legal review:
- payout rails (Stripe Connect / PayPal)
- KYC
- tax reporting
- minimum payout thresholds
- sybil / bot-farm defenses

## Consequences
- Dividends can be switched on later without migrating history.
- Every write path that produces events must record consent. That's a small cost per feature, and the code makes it unavoidable by construction (an `Events.record/2` API that requires it).
- Open question: whether ad-free subscribers accrue for their ranking data ([open-questions.md](../open-questions.md)).
