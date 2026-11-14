defmodule TSpec.Feed.RankerTest do
  @moduledoc "Ranker invariants (ADR 0006/0012), as properties over random inputs."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TSpec.Feed.{LabelShares, Ranker}
  alias TSpec.Feed.Ranker.{Candidate, Defaults}
  alias TSpec.Feed.Settings

  doctest Ranker

  # health > fitness, food > cooking, plus a parentless "music".
  @taxonomy %{
    "health" => %{id: "health", slug: "health", parent_id: nil},
    "fitness" => %{id: "fitness", slug: "fitness", parent_id: "health"},
    "food" => %{id: "food", slug: "food", parent_id: nil},
    "cooking" => %{id: "cooking", slug: "cooking", parent_id: "food"},
    "music" => %{id: "music", slug: "music", parent_id: nil}
  }
  @topics Map.keys(@taxonomy)
  @now ~U[2026-10-21 12:00:00Z]

  ## Generators

  defp affinity, do: float(min: -0.99, max: 0.99)

  # A random subset of `keys` (a boolean mask: no retries, unlike uniq_list_of).
  defp subset(keys) do
    map(list_of(boolean(), length: length(keys)), fn flags ->
      for {k, true} <- Enum.zip(keys, flags), do: k
    end)
  end

  # A map over a random subset of `keys`.
  defp subset_map(keys, value) do
    gen all(ks <- subset(keys), vs <- list_of(value, length: length(ks))) do
      Map.new(Enum.zip(ks, vs))
    end
  end

  defp multiplier, do: member_of([0.0, 0.25, 0.5, 1.0, 1.5, 2.0])

  defp candidate do
    gen all(
          n <- integer(1..10_000),
          author <- member_of(~w(a1 a2 a3 a4)),
          age_hours <- integer(0..400),
          sources <- subset(Settings.sources()),
          labels <- map(subset(@topics), &Enum.take(&1, 3)),
          confs <- list_of(member_of([0.3, 0.5, 0.7, 1.0]), length: length(labels)),
          quality <- float(min: 0.0, max: 1.0),
          following <- boolean()
        ) do
      %Candidate{
        content_id: "c#{String.pad_leading("#{n}", 5, "0")}",
        author_id: author,
        published_at: DateTime.add(@now, -age_hours * 3600, :second),
        sources: if(sources == [], do: ["fresh"], else: sources),
        labels:
          Enum.zip_with(labels, confs, &%{topic_id: &1, confidence: &2, sources: ["creator"]}),
        quality: quality,
        following: following
      }
    end
  end

  defp candidates do
    map(uniq_list_of(candidate(), uniq_fun: & &1.content_id, max_length: 30), & &1)
  end

  defp features do
    gen all(
          personalized <- boolean(),
          topic_aff <- subset_map(@topics, affinity()),
          creator_aff <- subset_map(~w(a1 a2 a3 a4), affinity())
        ) do
      %{
        now: @now,
        personalized: personalized,
        topic_affinity: topic_aff,
        creator_affinity: creator_aff
      }
    end
  end

  defp settings do
    gen all(
          topics <-
            subset_map(
              @topics,
              fixed_map(%{
                multiplier: multiplier(),
                hard_off: frequency([{4, constant(false)}, {1, constant(true)}])
              })
            ),
          sources <- subset_map(Settings.sources(), multiplier()),
          np <- boolean()
        ) do
      %Settings{version: 1, topics: topics, sources: sources, non_personalized: np}
    end
  end

  defp item_with(labels) do
    %Candidate{
      content_id: "c1",
      author_id: "a1",
      published_at: @now,
      sources: ["fresh"],
      labels: for({t, c} <- labels, do: %{topic_id: t, confidence: c, sources: ["creator"]})
    }
  end

  defp rank(cands, feats, settings, opts \\ []),
    do: Ranker.rank(cands, feats, settings, @taxonomy, opts)

  ## Invariants

  property "final_score is exactly the sum of the trace, and each contribution is weight × value" do
    check all(cands <- candidates(), feats <- features(), s <- settings()) do
      for item <- rank(cands, feats, s) do
        assert item.final_score === Ranker.sum(item.contributions)
        for c <- item.contributions, do: assert(c.contribution == c.weight * c.value)
      end
    end
  end

  property "the trace survives a JSON round-trip bit for bit" do
    check all(cands <- candidates(), feats <- features(), s <- settings()) do
      for item <- rank(cands, feats, s) do
        decoded =
          item.contributions
          |> Jason.encode!()
          |> Jason.decode!(keys: :atoms)

        assert Ranker.sum(decoded) === item.final_score
      end
    end
  end

  property "ranking is deterministic and independent of input order" do
    check all(cands <- candidates(), feats <- features(), s <- settings(), seed <- integer()) do
      :rand.seed(:exsss, {seed, seed, seed})
      assert rank(cands, feats, s) == rank(Enum.shuffle(cands), feats, s)
    end
  end

  property "hard-off topics (and their children) never appear at confidence ≥ 0.5" do
    check all(cands <- candidates(), feats <- features(), s <- settings()) do
      off = MapSet.new(Settings.hard_off_slugs(s))
      by_id = Map.new(cands, &{&1.content_id, &1})

      for item <- rank(cands, feats, s),
          label <- by_id[item.content_id].labels,
          label.confidence >= 0.5 do
        topic = @taxonomy[label.topic_id]
        parent = topic.parent_id && @taxonomy[topic.parent_id].slug
        refute MapSet.member?(off, topic.slug)
        refute parent && MapSet.member?(off, parent)
      end

      # And nothing eligible was dropped.
      expected = Enum.count(cands, &Ranker.eligible?(&1, s, @taxonomy))
      assert length(rank(cands, feats, s)) == expected
    end
  end

  property "hard-off reads raw confidence: other labels can't dilute an off topic past the filter" do
    check all(
            cand <- candidate(),
            feats <- features(),
            off <- member_of(@topics),
            others <- list_of(member_of(@topics -- [off]), min_length: 1, max_length: 2)
          ) do
      # Up to three labels at full confidence: each one's share is ⅓.
      labels =
        for t <- Enum.uniq([off | others]),
            do: %{topic_id: t, confidence: 1.0, sources: ["creator"]}

      cand = %{cand | labels: labels}
      s = %Settings{topics: %{off => %{multiplier: 1.0, hard_off: true}}}

      refute Ranker.eligible?(cand, s, @taxonomy)
      assert rank([cand], feats, s) == []
    end
  end

  property "topic rows are scaled by the label's share, and an item's shares sum to at most 1" do
    check all(cands <- candidates(), feats <- features(), s <- settings()) do
      by_id = Map.new(cands, &{&1.content_id, &1})

      for item <- rank(cands, feats, s) do
        labels = by_id[item.content_id].labels
        shares = LabelShares.shares(Enum.map(labels, &{&1.topic_id, &1.confidence}))
        assert Enum.sum(Map.values(shares)) <= 1.0 + 1.0e-12

        for c <- item.contributions, c.feature in ["topic_affinity", "topic_preference"] do
          assert c.label_share == shares[c.topic]
          assert c.label_share <= c.confidence
          if c.feature == "topic_preference", do: assert(c.value == c.label_share)
        end
      end
    end
  end

  property "more labels never add up to more than one fully-matching label" do
    check all(
            feats <- features(),
            labels <- map(subset(@topics), &Enum.take(&1, 3)),
            a <- affinity()
          ) do
      feats = %{feats | personalized: true, topic_affinity: Map.new(@topics, &{&1, a})}
      cand = item_with(Enum.map(labels, &{&1, 1.0}))
      one = item_with([{"music", 1.0}])

      topic_total = fn c ->
        Ranker.score(c, feats, %Settings{}, @taxonomy).contributions
        |> Enum.filter(&(&1.feature == "topic_affinity"))
        |> Ranker.sum()
      end

      # Every topic has affinity value a, so the labels can at most add up to
      # one label's worth: |Σ| ≤ |a|.
      assert abs(topic_total.(cand)) <= abs(topic_total.(one)) + 1.0e-12
    end
  end

  property "a slider at the default contributes no topic_preference" do
    check all(cands <- candidates(), feats <- features()) do
      for item <- rank(cands, feats, %Settings{}), c <- item.contributions do
        refute c.feature == "topic_preference"
      end
    end
  end

  property "moving a topic slider up never lowers that topic's items (any affinity, even negative)" do
    check all(
            cand <- candidate(),
            feats <- features(),
            topic <- member_of(@topics),
            conf <- member_of([0.3, 0.5, 0.7, 1.0])
          ) do
      cand = %{cand | labels: [%{topic_id: topic, confidence: conf, sources: ["creator"]}]}

      scores =
        for m <- [0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0] do
          s = %Settings{topics: %{topic => %{multiplier: m, hard_off: false}}}
          Ranker.score(cand, %{feats | personalized: true}, s, @taxonomy).final_score
        end

      assert scores == Enum.sort(scores), "not monotonic: #{inspect(scores)}"
    end
  end

  property "moving a slider up never lowers a multi-label item's score" do
    check all(cand <- candidate(), feats <- features(), topic <- member_of(@topics)) do
      extra = Enum.reject(cand.labels, &(&1.topic_id == topic))
      cand = %{cand | labels: [%{topic_id: topic, confidence: 1.0, sources: ["creator"]} | extra]}

      scores =
        for m <- [0.0, 0.5, 1.0, 1.5, 2.0] do
          s = %Settings{topics: %{topic => %{multiplier: m, hard_off: false}}}
          Ranker.score(cand, %{feats | personalized: true}, s, @taxonomy).final_score
        end

      assert scores == Enum.sort(scores), "not monotonic: #{inspect(scores)}"
    end
  end

  test "the monotonicity guarantee rests on topic_preference > topic_affinity" do
    assert Defaults.feature(:topic_preference) > Defaults.feature(:topic_affinity)
  end

  property "a source multiplier of 0 zeroes exactly that source's prior" do
    # Not explore: its slider sets the explore slot rate instead (ADR 0015).
    check all(
            cand <- candidate(),
            feats <- features(),
            source <- member_of(Settings.sources() -- ["explore"])
          ) do
      cand = %{cand | sources: [source]}
      base = Ranker.score(cand, feats, %Settings{}, @taxonomy)
      zeroed = Ranker.score(cand, feats, %Settings{sources: %{source => 0.0}}, @taxonomy)

      for {b, z} <- Enum.zip(base.contributions, zeroed.contributions) do
        if b.feature == "source_prior",
          do: assert(z.contribution == 0.0),
          else: assert(z == b)
      end
    end
  end

  property "the Explore slider never changes a score, only where explore slots fall" do
    check all(cand <- candidate(), feats <- features(), m <- multiplier()) do
      cand = %{cand | sources: ["explore"]}
      base = Ranker.score(cand, feats, %Settings{}, @taxonomy)
      moved = Ranker.score(cand, feats, %Settings{sources: %{"explore" => m}}, @taxonomy)
      assert moved == base
    end
  end

  describe "explore slots" do
    defp slot?(position, every), do: every != nil and rem(position + 1, every) == 0

    property "a slot holds an explorable item whenever one is left, and only slots are marked" do
      check all(
              cands <- candidates(),
              feats <- features(),
              s <- settings(),
              start <- integer(0..25)
            ) do
        every = if feats.personalized, do: Ranker.explore_every(s)
        ranked = rank(cands, feats, s, start_position: start)
        explorable_total = Enum.count(ranked, & &1.explorable)

        ranked
        |> Enum.take(50)
        |> Enum.with_index(start)
        |> Enum.reduce(0, fn {item, position}, explorable_before ->
          if slot?(position, every) and explorable_total > explorable_before do
            assert item.placement == "explore"
            assert item.explorable
          else
            assert item.placement == nil
          end

          explorable_before + if(item.explorable, do: 1, else: 0)
        end)

        # Beyond the diversity depth, nothing is placed.
        for item <- Enum.drop(ranked, 50), do: assert(item.placement == nil)
      end
    end

    property "no slots when the Explore slider is at 0 or the feed isn't personalized" do
      check all(cands <- candidates(), feats <- features(), s <- settings()) do
        off = %{s | sources: Map.put(s.sources, "explore", 0.0)}
        for item <- rank(cands, feats, off), do: assert(item.placement == nil)

        for item <- rank(cands, %{feats | personalized: false}, s),
            do: assert(item.placement == nil)
      end
    end

    property "a slot changes an item's position, never its trace or score" do
      check all(cands <- candidates(), feats <- features(), s <- settings()) do
        for item <- rank(cands, feats, s), item.placement == "explore" do
          assert item.final_score === Ranker.sum(item.contributions)
          refute Enum.any?(item.contributions, &(&1.feature == "explore"))
        end
      end
    end

    property "boosting a topic never takes its items out of explore slots" do
      check all(
              feats <- features(),
              s <- settings(),
              topic <- member_of(@topics),
              m <- member_of([1.25, 1.5, 2.0])
            ) do
        at = fn mult ->
          %{s | topics: Map.put(s.topics, topic, %{multiplier: mult, hard_off: false})}
        end

        assert Ranker.explore_blocked_topic_ids(feats, at.(m), @taxonomy) ==
                 Ranker.explore_blocked_topic_ids(feats, at.(1.0), @taxonomy)
      end
    end

    property "blocked topics come in whole tier-1 families" do
      check all(feats <- features(), s <- settings()) do
        blocked = Ranker.explore_blocked_topic_ids(feats, s, @taxonomy)

        for {id, %{parent_id: parent}} <- @taxonomy, parent != nil do
          assert MapSet.member?(blocked, id) == MapSet.member?(blocked, parent)
        end
      end
    end

    property "no slots when nothing is blocked" do
      check all(cands <- candidates(), feats <- features(), s <- settings()) do
        if Ranker.explore_blocked_topic_ids(feats, s, @taxonomy) == MapSet.new() do
          for item <- rank(cands, feats, s), do: assert(item.placement == nil)
        end
      end
    end

    test "the slider sets the spacing" do
      every = fn m -> Ranker.explore_every(%Settings{sources: %{"explore" => m}}) end
      assert Enum.map([0.0, 0.25, 0.5, 1.0, 1.5, 2.0], every) == [nil, 40, 20, 10, 7, 5]
      assert Ranker.explore_every(%Settings{non_personalized: true}) == nil
    end
  end

  property "non-personalized ranking uses no learned signals" do
    check all(cands <- candidates(), feats <- features(), s <- settings()) do
      for item <- rank(cands, %{feats | personalized: false}, s), c <- item.contributions do
        refute c.feature in ["topic_affinity", "creator_affinity"]
      end
    end
  end

  describe "examples" do
    defp item(id, author, labels, opts \\ []) do
      %Candidate{
        content_id: id,
        author_id: author,
        published_at: Keyword.get(opts, :published_at, @now),
        sources: Keyword.get(opts, :sources, ["fresh"]),
        labels: for({t, c} <- labels, do: %{topic_id: t, confidence: c, sources: ["creator"]}),
        quality: 0.5
      }
    end

    @feats %{now: @now, personalized: true, topic_affinity: %{}, creator_affinity: %{}}

    test "a negative learned affinity still loses to an explicit boost" do
      feats = %{@feats | topic_affinity: %{"cooking" => -0.9}}
      cooking = item("c1", "a1", [{"cooking", 1.0}])

      neutral = Ranker.score(cooking, feats, %Settings{}, @taxonomy)

      boosted =
        Ranker.score(
          cooking,
          feats,
          %Settings{topics: %{"cooking" => %{multiplier: 2.0, hard_off: false}}},
          @taxonomy
        )

      assert boosted.final_score > neutral.final_score

      assert [
               %{feature: "topic_affinity", weight: 2.0},
               %{feature: "topic_preference", weight: 1.5}
             ] =
               Enum.filter(boosted.contributions, &(&1[:topic] == "cooking"))
    end

    test "a topic with no history falls back to half its parent's affinity" do
      feats = %{@feats | topic_affinity: %{"health" => 0.8}}
      scored = Ranker.score(item("c1", "a1", [{"fitness", 1.0}]), feats, %Settings{}, @taxonomy)

      assert [%{feature: "topic_affinity", topic: "fitness", value: 0.4}] =
               Enum.filter(scored.contributions, &(&1[:topic] == "fitness"))
    end

    test "three labels split the topic signal three ways, and say so in the trace" do
      feats = %{@feats | topic_affinity: %{"cooking" => 0.6, "fitness" => 0.6, "music" => 0.6}}
      three = item("c1", "a1", [{"cooking", 1.0}, {"fitness", 1.0}, {"music", 1.0}])
      one = item("c2", "a1", [{"cooking", 1.0}])

      rows = fn c ->
        Ranker.score(c, feats, %Settings{}, @taxonomy).contributions
        |> Enum.filter(&(&1.feature == "topic_affinity"))
      end

      assert [%{value: 0.6, confidence: 1.0, label_share: 1.0}] = rows.(one)
      assert [_, _, _] = rows.(three)

      for r <- rows.(three) do
        assert r.label_share == 1 / 3
        assert r.value == 0.6 * (1 / 3)
      end
    end

    test "a topic labeled with its own parent splits the item rather than counting twice" do
      feats = %{@feats | topic_affinity: %{"health" => 0.8, "fitness" => 0.8}}
      both = item("c1", "a1", [{"fitness", 1.0}, {"health", 1.0}])

      rows =
        Ranker.score(both, feats, %Settings{}, @taxonomy).contributions
        |> Enum.filter(&(&1.feature == "topic_affinity"))

      assert Enum.map(rows, &{&1.topic, &1.value}) == [{"fitness", 0.4}, {"health", 0.4}]
    end

    test "a lone low-confidence label keeps its low weight" do
      feats = %{@feats | topic_affinity: %{"cooking" => 0.5}}
      scored = Ranker.score(item("c1", "a1", [{"cooking", 0.3}]), feats, %Settings{}, @taxonomy)

      assert [%{value: 0.15, label_share: 0.3}] =
               Enum.filter(scored.contributions, &(&1.feature == "topic_affinity"))
    end

    test "a tier-2 topic inherits its parent's slider and hard-off" do
      s = %Settings{topics: %{"health" => %{multiplier: 2.0, hard_off: false}}}
      assert Settings.topic_multiplier(s, "fitness", "health") == 2.0

      off = %Settings{topics: %{"health" => %{multiplier: 1.0, hard_off: true}}}
      refute Ranker.eligible?(item("c1", "a1", [{"fitness", 0.5}]), off, @taxonomy)
      # Below the threshold the label doesn't count.
      assert Ranker.eligible?(item("c2", "a1", [{"fitness", 0.4}]), off, @taxonomy)
    end

    test "diversity spreads out a prolific creator, and says so in the trace" do
      # Five equally good items from a1, then a slightly weaker one from a2.
      a1 = for n <- 1..5, do: item("a1-#{n}", "a1", [])
      a2 = item("a2-1", "a2", [], published_at: DateTime.add(@now, -3600, :second))

      [first, second | _] = Ranker.rank(a1 ++ [a2], @feats, %Settings{}, @taxonomy)
      assert first.author_id == "a1"
      assert second.author_id == "a2"

      third = Enum.at(Ranker.rank(a1 ++ [a2], @feats, %Settings{}, @taxonomy), 2)
      assert %{feature: "diversity", value: -1.0} = List.last(third.contributions)
    end

    test "a mature profile still sees a new topic every 10th item" do
      feats = %{@feats | topic_affinity: %{"cooking" => 0.95}}
      # Fifteen strong cooking items from distinct creators, one weak music item.
      cooking = for n <- 1..15, do: item("c#{n}", "cook#{n}", [{"cooking", 1.0}])
      music = item("m1", "musician", [{"music", 1.0}], sources: ["explore"])

      ranked = Ranker.rank([music | cooking], feats, %Settings{}, @taxonomy)

      assert %{content_id: "m1", placement: "explore"} = Enum.at(ranked, 9)
      assert Enum.count(ranked, &(&1.placement == "explore")) == 1

      # Without the slot it would come last.
      off = %Settings{sources: %{"explore" => 0.0}}

      assert %{content_id: "m1", placement: nil} =
               List.last(Ranker.rank([music | cooking], feats, off, @taxonomy))
    end

    test "slots count from the feed's position, so a later page or re-rank keeps the spacing" do
      feats = %{@feats | topic_affinity: %{"cooking" => 0.95}}
      cooking = for n <- 1..15, do: item("c#{n}", "cook#{n}", [{"cooking", 1.0}])
      music = item("m1", "musician", [{"music", 1.0}])

      # Seven items already sent: the next slot is the 3rd item of this page.
      ranked = Ranker.rank([music | cooking], feats, %Settings{}, @taxonomy, start_position: 7)
      assert %{content_id: "m1", placement: "explore"} = Enum.at(ranked, 2)
    end

    test "the diversity window sees the explore pick" do
      feats = %{@feats | topic_affinity: %{"cooking" => 0.95}}
      cooking = for n <- 1..9, do: item("c#{n}", "cook#{n}", [{"cooking", 1.0}])
      music = item("m1", "musician", [{"music", 1.0}])
      # The musician again, on cooking: as good as c1..c9 (it loses their
      # ties on id), and fresher than c10.
      encore = item("m2", "musician", [{"cooking", 1.0}])
      older = item("c10", "cook10", [{"cooking", 1.0}], published_at: DateTime.add(@now, -3600))

      ranked = Ranker.rank([music, encore, older | cooking], feats, %Settings{}, @taxonomy)
      assert Enum.map(Enum.slice(ranked, 9..11), & &1.content_id) == ["m1", "c10", "m2"]

      # Only the musician just placed in the slot puts c10 ahead of m2.
      m2 = Enum.at(ranked, 11)
      assert %{feature: "diversity", value: value} = List.last(m2.contributions)
      assert value <= -1.0
    end

    test "a known topic blocks its whole tier-1 family, parents included" do
      # Fitness is known; its parent Health has faded below the threshold.
      feats = %{@feats | topic_affinity: %{"fitness" => 0.4, "health" => 0.01, "music" => 0.01}}
      blocked = Ranker.explore_blocked_topic_ids(feats, %Settings{}, @taxonomy)
      assert MapSet.equal?(blocked, MapSet.new(["health", "fitness"]))

      refute Ranker.explorable?(item("c1", "a1", [{"health", 1.0}]), blocked)
      refute Ranker.explorable?(item("c2", "a1", [{"music", 1.0}, {"fitness", 0.2}]), blocked)
      assert Ranker.explorable?(item("c3", "a1", [{"music", 1.0}]), blocked)
      refute Ranker.explorable?(item("c4", "a1", []), blocked)

      # Known through the caller (a recent forget, or shown in this session).
      held = Map.put(feats, :known_topic_ids, MapSet.new(["cooking"]))

      assert MapSet.equal?(
               Ranker.explore_blocked_topic_ids(held, %Settings{}, @taxonomy),
               MapSet.new(["food", "cooking"])
             )
    end

    test "a slider below 1× blocks a topic's family; a boost doesn't" do
      less = %Settings{topics: %{"food" => %{multiplier: 0.5, hard_off: false}}}

      assert MapSet.equal?(
               Ranker.explore_blocked_topic_ids(@feats, less, @taxonomy),
               MapSet.new(["food", "cooking"])
             )

      more = %Settings{topics: %{"food" => %{multiplier: 1.5, hard_off: false}}}
      assert Ranker.explore_blocked_topic_ids(@feats, more, @taxonomy) == MapSet.new()
    end

    test "nudging up a topic an explore slot introduced keeps it in the slots" do
      # The reviewer's case: someone who loves cooking sees Music in a slot,
      # likes it, and moves Music to 1.25×.
      feats = %{@feats | topic_affinity: %{"cooking" => 0.95}}
      cooking = for n <- 1..15, do: item("c#{n}", "cook#{n}", [{"cooking", 1.0}])
      music = item("m1", "musician", [{"music", 1.0}])

      position = fn m ->
        s = %Settings{topics: %{"music" => %{multiplier: m, hard_off: false}}}
        ranked = Ranker.rank([music | cooking], feats, s, @taxonomy)

        {Enum.find_index(ranked, &(&1.content_id == "m1")),
         Enum.find(ranked, &(&1.content_id == "m1"))}
      end

      assert {9, %{placement: "explore"}} = position.(1.0)

      # Any boost keeps it at least as early as its slot (before v1.3, a
      # boost made Music "known" and it fell to the end of the feed).
      for m <- [1.25, 1.5, 2.0] do
        assert {index, _} = position.(m)
        assert index <= 9, "at #{m}×, position #{index}"
      end
    end

    test "no slots while the user knows no topic (cold start)" do
      cands = for n <- 1..15, do: item("c#{n}", "a#{n}", [{"cooking", 1.0}])
      ranked = Ranker.rank(cands, @feats, %Settings{}, @taxonomy)
      assert Enum.all?(ranked, &(&1.placement == nil))
    end

    test "diversity carries over from items already shown" do
      a1 = item("a1-1", "a1", [])
      a2 = item("a2-1", "a2", [], published_at: DateTime.add(@now, -3600, :second))

      assert [%{author_id: "a1"} | _] = Ranker.rank([a1, a2], @feats, %Settings{}, @taxonomy)

      recent = [%{author_id: "a1", primary_topic: nil}]

      assert [%{author_id: "a2"} | _] =
               Ranker.rank([a1, a2], @feats, %Settings{}, @taxonomy, recent: recent)
    end
  end
end
