# Security Policy

T-Spec is pre-beta. There is no production deployment yet, so the in-scope target is the code in this repository.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Instead, report them privately through GitHub: **Security → Report a vulnerability** on this repository.

Include what you found, how to reproduce it, and the impact you think it has. You'll get an acknowledgement within a week. This is a personal project, so there's no bug bounty, but reporters are credited in the fix if they'd like to be.

## Scope

In scope:
- the Phoenix API (`apps/server`): authentication, authorization, webhook verification, data exposure;
- the Expo client (`apps/client`): token handling, injection;
- anything that would let one user read or change another user's data, or record events on their behalf.

Known gaps, already tracked in [`docs/open-questions.md`](docs/open-questions.md) and the [roadmap](docs/roadmap.md), so no report is needed:
- no rate limiting on sign-in requests beyond per-code attempt limits;
- web sessions store the bearer token in `localStorage`;
- no content moderation or CSAM scanning yet;
- no account export or deletion yet.

The dev-only `LocalProvider` routes (`/dev/...`) and the dev mailbox are compiled out of production builds and are out of scope.
