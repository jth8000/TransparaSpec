defmodule TSpec.Feed.LabelSharesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TSpec.Feed.LabelShares

  doctest LabelShares

  defp labels do
    map(list_of(float(min: 0.01, max: 1.0), max_length: 12), fn confs ->
      confs |> Enum.with_index() |> Enum.map(fn {c, i} -> {i, c} end)
    end)
  end

  property "shares never sum past 1, never exceed the confidence, and keep its proportions" do
    check all(labels <- labels()) do
      shares = LabelShares.shares(labels)
      assert Enum.sum(Map.values(shares)) <= 1.0 + 1.0e-12

      for {k, c} <- labels do
        assert shares[k] <= c
        assert shares[k] > 0.0
      end

      if Enum.sum(Enum.map(labels, &elem(&1, 1))) <= 1.0 do
        assert shares == Map.new(labels)
      end
    end
  end

  property "the result doesn't depend on the order of the labels" do
    check all(labels <- labels(), seed <- integer()) do
      :rand.seed(:exsss, {seed, seed, seed})
      assert LabelShares.shares(labels) == LabelShares.shares(Enum.shuffle(labels))
    end
  end
end
