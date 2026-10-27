defmodule TSpec.Feed.Settings do
  @moduledoc """
  A user's algorithm controls, as the ranker sees them (ADR 0012).

    * `topics` — `%{slug => %{multiplier: 0.0..2.0, hard_off: boolean}}`.
      A tier-2 topic without its own entry inherits its tier-1 parent's
      multiplier; hard-off on a tier-1 topic covers its children.
    * `sources` — `%{source => multiplier}` for the candidate sources.
    * `non_personalized` — no inferred signals (topic/creator affinity,
      co-engagement, explore).
    * `version` — the user's `settings_version`; stored on every impression.

  Missing entries mean the default (multiplier 1.0, not hard-off).
  """

  @sources ~w(following topic co_engagement trending explore fresh)

  defstruct version: 0, non_personalized: false, topics: %{}, sources: %{}

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          non_personalized: boolean(),
          topics: %{String.t() => %{multiplier: float(), hard_off: boolean()}},
          sources: %{String.t() => float()}
        }

  def sources, do: @sources

  @doc "The multiplier for a topic, falling back to its parent's, then 1.0."
  def topic_multiplier(%__MODULE__{topics: topics}, slug, parent_slug \\ nil) do
    case {topics[slug], parent_slug && topics[parent_slug]} do
      {%{multiplier: m}, _} -> m / 1
      {nil, %{multiplier: m}} -> m / 1
      _ -> 1.0
    end
  end

  def source_multiplier(%__MODULE__{sources: sources}, source),
    do: Map.get(sources, source, 1.0) / 1

  def hard_off_slugs(%__MODULE__{topics: topics}),
    do: for({slug, %{hard_off: true}} <- topics, do: slug)

  @doc "Topics whose slider is above the default (the `topic` source includes them)."
  def boosted_slugs(%__MODULE__{topics: topics}),
    do: for({slug, %{multiplier: m}} <- topics, m > 1.0, do: slug)

  @doc "A JSON-ready, key-sorted form, for snapshots and hashing."
  def to_snapshot(%__MODULE__{} = s) do
    %{
      "version" => s.version,
      "non_personalized" => s.non_personalized,
      "topics" =>
        Map.new(s.topics, fn {slug, t} ->
          {slug, %{"multiplier" => t.multiplier / 1, "hard_off" => t.hard_off}}
        end),
      "sources" => Map.new(s.sources, fn {k, m} -> {k, m / 1} end)
    }
  end

  @doc "A stable digest of the settings (excluding the version)."
  def hash(%__MODULE__{} = s) do
    s
    |> to_snapshot()
    |> Map.delete("version")
    |> canonical()
    |> then(&:crypto.hash(:sha256, &1))
  end

  # Deterministic JSON: maps encoded with sorted keys.
  defp canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(to_string(k)) <> ":" <> canonical(v) end)

    "{" <> inner <> "}"
  end

  defp canonical(other), do: Jason.encode!(other)
end
