defmodule TSpec.Feed.Interests.Weights do
  @moduledoc """
  Tunable constants of the interest model (ADR 0012). These are hand-tuned
  starting points, to be calibrated from beta data (docs/open-questions.md).
  Override any of them with `config :tspec, TSpec.Feed.Interests.Weights, ...`.

  Per-view target delta (one per playback episode):

    * `complete` — watched to the end (+ `loop_bonus` once if it looped)
    * `early_skip` — swiped away within `early_skip_ms`
    * `partial` — otherwise, times the fraction watched (capped at 1, so a
      long video is worth no more than a short one at the same fraction)
    * `text_view` — a text post was viewed (no duration to measure)

  Affinity scores decay with a `half_life_days` half-life and are squashed
  into (-1, 1) as `tanh(score / squash)` for use as ranking features. A
  tier-2 topic credits its tier-1 parent at `parent_share`.
  """

  @defaults %{
    complete: 1.0,
    loop_bonus: 0.25,
    early_skip: -0.5,
    early_skip_ms: 2_000,
    partial: 0.8,
    text_view: 0.1,
    half_life_days: 14,
    squash: 3.0,
    parent_share: 0.5
  }

  def get, do: Map.merge(@defaults, Map.new(Application.get_env(:tspec, __MODULE__, [])))

  def defaults, do: @defaults
end
