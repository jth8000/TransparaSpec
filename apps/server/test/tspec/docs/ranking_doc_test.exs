defmodule TSpec.Docs.RankingDocTest do
  @moduledoc """
  docs/ranking.md explains the ranker to people, AI agents and users. Its
  defaults table must match the code, so the explanation can't silently go
  stale when a weight is tuned.
  """
  use ExUnit.Case, async: true

  alias TSpec.Feed.{Candidates, Ranker}
  alias TSpec.Feed.Interests.Weights
  alias TSpec.Feed.Ranker.Defaults

  @doc_path Path.expand("../../../../../docs/ranking.md", __DIR__)

  defp documented do
    [_, table] = @doc_path |> File.read!() |> String.split("<!-- defaults:start -->")
    [table | _] = String.split(table, "<!-- defaults:end -->")

    for line <- String.split(table, "\n"),
        [_, name, value] <- [Regex.run(~r/^\|\s*`([^`]+)`\s*\|\s*([-0-9.]+)\s*\|/, line)],
        into: %{} do
      {name, String.to_float(if String.contains?(value, "."), do: value, else: value <> ".0")}
    end
  end

  defp in_code do
    Map.new(Defaults.features(), fn {k, v} -> {"feature.#{k}", v / 1} end)
    |> Map.merge(Map.new(Defaults.source_priors(), fn {k, v} -> {"source.#{k}", v / 1} end))
    |> Map.merge(Map.new(Weights.defaults(), fn {k, v} -> {"interest.#{k}", v / 1} end))
    |> Map.merge(%{
      "ranker.hard_off_threshold" => Ranker.hard_off_threshold() / 1,
      "quality.prior_views" => Candidates.prior_views() / 1,
      "quality.prior_rate" => Candidates.prior_rate() / 1
    })
  end

  test "docs/ranking.md lists every tunable default with the value the code uses" do
    assert documented() == in_code()
  end
end
