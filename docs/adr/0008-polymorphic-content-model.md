# ADR 0008: Polymorphic content model

- **Status:** Accepted
- **Date:** 2026-10-20

## Context
The MVP has short videos and text posts. Later come long-form video, link and quote posts, X-style threads and Reddit-style communities. The feed, ranker, transparency, moderation and ledger should all work on "content" in general, not on each kind separately.

## Decision
- **One base table** for every kind of content: `content_items(id, author_id, kind, parent_id, root_id, status, visibility, community_id?, created_at)`.
- **One payload table per kind**, keyed by `content_id`: `short_videos`, `text_posts`, and later `long_videos`, `link_posts`.
- **Comments and replies are content items** with `parent_id` (direct parent) and `root_id` (top of thread). That gives arbitrary-depth threading for X/Reddit-style conversations.
- **Shared tables reference `content_items.id`**:
  - topics (`content_topics`) and embeddings (`content_embeddings`)
  - engagement events, impressions
  - moderation reports
- **Communities come later** as a `communities` table plus a nullable `content_items.community_id`.

## Consequences
- A new content kind needs only a payload table, an Ecto schema and a client renderer. The ranking, transparency and moderation code is reused.
- Kind-specific queries join the payload table. Feed queries mostly need only the base table plus topics.
- Comments being content means they can be ranked, explained and moderated with the same machinery.
