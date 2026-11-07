defmodule TSpec.Feed.LabelShares do
  @moduledoc """
  How much of an item each topic label stands for (ADR 0014):

      share(label) = confidence / max(1, Σ confidences of the item's labels)

  One label at full confidence keeps its whole weight. Three labels at 1.0
  get a third each, so adding labels spreads an item's topic signal instead
  of multiplying it. A lone low-confidence label keeps its low weight (a
  plain average would make it look certain). Shares never sum past 1.

  Ranking (`Feed.Ranker`) and learning (`Feed.Interests.topic_snapshot/3`)
  both use this, so an item teaches a viewer's profile in the same
  proportions it's ranked by. Hard-off never does: it keeps raw confidence,
  so three labels at 1.0 can't slip a switched-off topic under its
  threshold.
  """

  @doc """
  `[{key, confidence}]` → `%{key => share}`. Confidences are summed in
  sorted order, so the result doesn't depend on the order of the input.

      iex> TSpec.Feed.LabelShares.shares([{"a", 1.0}])
      %{"a" => 1.0}
      iex> TSpec.Feed.LabelShares.shares([{"a", 1.0}, {"b", 1.0}])
      %{"a" => 0.5, "b" => 0.5}
      iex> TSpec.Feed.LabelShares.shares([{"a", 0.3}, {"b", 0.2}])
      %{"a" => 0.3, "b" => 0.2}
  """
  def shares(labels) do
    total = labels |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.sum()
    divisor = max(total, 1.0)
    Map.new(labels, fn {key, confidence} -> {key, confidence / divisor} end)
  end
end
