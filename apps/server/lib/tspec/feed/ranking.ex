defmodule TSpec.Feed.Ranking do
  @moduledoc """
  The For You pipeline (ADR 0006/0011), stitched together:

      features + candidates  →  Ranker.rank  →  serve (write impressions)

  `rank/3` is read-only. `serve/3` is the moment of truth: it writes one
  impression per served item with the exact trace that ranked it, and
  returns the impression ids the client reports exposure against.
  `TSpec.Feed.Session` (M4) drives this for live feeds.
  """

  alias TSpec.{Content, Events, Transparency}
  alias TSpec.Accounts.Scope
  alias TSpec.Feed.{Candidates, Interests, Ranker, Settings}
  alias TSpec.Feed.Interests.Weights

  @doc """
  The user features the ranker reads, at `now`. In non-personalized mode the
  learned maps are empty and `personalized` is false (ADR 0012).
  """
  def features(user_id, %Settings{} = settings, now \\ DateTime.utc_now()) do
    if settings.non_personalized do
      %{now: now, personalized: false, topic_affinity: %{}, creator_affinity: %{}}
    else
      w = Weights.get()

      squash = fn affinities ->
        Map.new(affinities, fn {k, a} -> {k, Interests.feature_value(a.score, w)} end)
      end

      %{
        now: now,
        personalized: true,
        topic_affinity: squash.(Interests.topic_affinities(user_id, now)),
        creator_affinity: squash.(Interests.creator_affinities(user_id, now))
      }
    end
  end

  @doc """
  Gathers and ranks candidates for a user. Options are passed to
  `Candidates.gather/4` (`:exclude`, `:now`, ...) and `Ranker.rank/5`
  (`:recent`).
  """
  def rank(user_id, %Settings{} = settings, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    features = features(user_id, settings, now)
    candidates = Candidates.gather(user_id, settings, features, Keyword.put(opts, :now, now))
    Ranker.rank(candidates, features, settings, Content.topics_by_id(), opts)
  end

  @doc """
  Writes impressions for a page of ranked items and returns
  `{:ok, [{scored, impression_id}]}`. `ctx` has `:feed_session_id`, `:rev`,
  `:start_position` and `:settings` (whose version and snapshot are stored
  on every row, so explanations show the settings as they were).
  """
  def serve(%Scope{} = scope, scored, %{} = ctx) do
    snapshot_id = Transparency.snapshot_settings(scope.user.id, ctx.settings)

    entries =
      scored
      |> Enum.with_index(ctx.start_position)
      |> Enum.map(fn {s, position} ->
        %{
          content_id: s.content_id,
          feed_session_id: ctx.feed_session_id,
          rev: ctx.rev,
          position: position,
          ranker_version: Ranker.version(),
          candidate_source: s.candidate_source,
          sources: s.sources,
          final_score: s.final_score,
          contributions: s.contributions,
          settings_version: ctx.settings.version,
          settings_snapshot_id: snapshot_id
        }
      end)

    with {:ok, ids} <- Events.record_impressions(scope, entries) do
      {:ok, Enum.zip(scored, ids)}
    end
  end
end
