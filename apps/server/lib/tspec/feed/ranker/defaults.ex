defmodule TSpec.Feed.Ranker.Defaults do
  @moduledoc """
  Default feature weights for ranker v1 — hand-tuned starting points
  (docs/open-questions.md). A user's settings multiply these; they never
  replace them.

  **Slider monotonicity** (ADR 0012): a topic slider `m` contributes
  `c·(w_aff·m·a + w_pref·(m − 1))`, whose slope in `m` is `c·(w_aff·a + w_pref)`.
  Affinity values `a` lie in (−1, 1), so `topic_preference > topic_affinity`
  makes moving a slider toward "more" always raise that topic's score. This
  module refuses to compile otherwise.
  """

  @features %{
    topic_affinity: 1.0,
    topic_preference: 1.5,
    creator_affinity: 0.6,
    following: 0.5,
    freshness: 0.4,
    quality: 0.3,
    diversity: 0.5
  }

  # Prior for the best candidate source an item came from.
  @source_priors %{
    "following" => 0.3,
    "co_engagement" => 0.25,
    "topic" => 0.2,
    "trending" => 0.2,
    "explore" => 0.1,
    "fresh" => 0.1
  }

  if @features.topic_preference <= @features.topic_affinity do
    raise CompileError,
      description:
        "topic_preference (#{@features.topic_preference}) must exceed topic_affinity " <>
          "(#{@features.topic_affinity}) or topic sliders stop being monotonic (ADR 0012)"
  end

  def feature(name), do: Map.fetch!(@features, name)
  def features, do: @features
  def source_prior(source), do: Map.fetch!(@source_priors, source)
  def source_priors, do: @source_priors
end
