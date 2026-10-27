defmodule TSpec.Feed.RankingTest do
  @moduledoc "Candidates → ranker → impressions, against the database."
  use TSpec.DataCase, async: true
  use ExUnitProperties

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Content, Events, Social, Transparency}
  alias TSpec.Events.Impression
  alias TSpec.Feed.{Candidates, Interests, Ranking, Settings, TrendingWorker}

  setup do
    viewer = onboarded_user_fixture()
    %{viewer: viewer, scope: Accounts.scope_for_user(viewer)}
  end

  defp watch!(scope, item, seconds \\ 2.0) do
    v = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, _} =
      Events.record(scope, [
        %{content_id: item.id, view_id: v, type: "view_start", occurred_at: now},
        %{content_id: item.id, view_id: v, type: "complete", value: seconds, occurred_at: now}
      ])

    {:ok, _} = Interests.apply_dirty_views(scope.user.id)
    v
  end

  defp ids(candidates_or_scored),
    do: candidates_or_scored |> Enum.map(& &1.content_id) |> MapSet.new()

  defp gather(viewer, settings \\ %Settings{}, opts \\ []) do
    Candidates.gather(viewer.id, settings, Ranking.features(viewer.id, settings), opts)
  end

  describe "candidate sources" do
    test "following, fresh and topic nominate, and say so", %{viewer: viewer, scope: scope} do
      friend = onboarded_user_fixture()
      stranger = onboarded_user_fixture()
      :ok = Social.follow(scope, friend)

      followed = text_post_fixture(friend)
      fitness = ready_video_fixture(stranger, topics: ["fitness-and-exercise"])
      other_fitness = ready_video_fixture(stranger, topics: ["fitness-and-exercise"])
      watch!(scope, fitness)

      by_id = Map.new(gather(viewer), &{&1.content_id, &1})

      assert "following" in by_id[followed.id].sources
      assert by_id[followed.id].following
      assert "fresh" in by_id[other_fitness.id].sources
      # Learned interest in fitness pulls in other fitness items.
      assert "topic" in by_id[other_fitness.id].sources
      # Just watched: filtered out for 48 hours.
      refute Map.has_key?(by_id, fitness.id)
    end

    test "a boosted topic is nominated even with no history", %{viewer: viewer} do
      cooking = text_post_fixture(onboarded_user_fixture(), topics: ["cooking"])
      boosted = %Settings{topics: %{"cooking" => %{multiplier: 1.5, hard_off: false}}}

      refute "topic" in (gather(viewer) |> Enum.find(&(&1.content_id == cooking.id))).sources

      assert "topic" in (gather(viewer, boosted)
                         |> Enum.find(&(&1.content_id == cooking.id))).sources
    end

    test "own items and hard-off topics (and their children) are never candidates",
         %{viewer: viewer} do
      creator = onboarded_user_fixture()
      mine = text_post_fixture(viewer)
      fitness = text_post_fixture(creator, topics: ["fitness-and-exercise"])
      cooking = text_post_fixture(creator, topics: ["cooking"])

      off = %Settings{topics: %{"healthy-living" => %{multiplier: 1.0, hard_off: true}}}
      found = ids(gather(viewer, off))

      refute MapSet.member?(found, mine.id)
      refute MapSet.member?(found, fitness.id)
      assert MapSet.member?(found, cooking.id)
    end

    test "a hard-off label below confidence 0.5 doesn't hide the item", %{viewer: viewer} do
      item = text_post_fixture(onboarded_user_fixture())

      Repo.insert!(%Content.ContentTopic{
        content_id: item.id,
        topic_id: Content.topics_by_slug()["fitness-and-exercise"].id,
        source: "model",
        confidence: 0.4
      })

      off = %Settings{
        topics: Map.new([{"fitness-and-exercise", %{multiplier: 1.0, hard_off: true}}])
      }

      assert MapSet.member?(ids(gather(viewer, off)), item.id)
    end

    test "trending and co-engagement", %{viewer: viewer, scope: scope} do
      creator = onboarded_user_fixture()
      shared = ready_video_fixture(creator)
      next = ready_video_fixture(creator)
      hit = ready_video_fixture(creator)

      # A peer completed what the viewer completed, plus `next`.
      peer = Accounts.scope_for_user(onboarded_user_fixture())
      watch!(peer, shared)
      watch!(peer, next)
      watch!(scope, shared)

      # Lots of completions make `hit` trend.
      for _ <- 1..3, do: watch!(Accounts.scope_for_user(onboarded_user_fixture()), hit)
      :ok = TrendingWorker.perform(%Oban.Job{})

      by_id = Map.new(gather(viewer), &{&1.content_id, &1})
      assert "co_engagement" in by_id[next.id].sources
      assert "trending" in by_id[hit.id].sources
    end

    test "views watched in non-personalized mode never drive co-engagement for anyone",
         %{viewer: viewer, scope: scope} do
      creator = onboarded_user_fixture()
      shared = ready_video_fixture(creator)
      next = ready_video_fixture(creator)

      # The peer watches in non-personalized mode.
      peer = Accounts.scope_for_user(onboarded_user_fixture())
      {:ok, _} = Transparency.set_non_personalized(peer, true)
      watch!(peer, shared)
      watch!(peer, next)
      watch!(scope, shared)

      refute Enum.any?(
               gather(viewer),
               &(&1.content_id == next.id and "co_engagement" in &1.sources)
             )

      # The same peer behavior in personalized mode does count.
      other = Accounts.scope_for_user(onboarded_user_fixture())
      watch!(other, shared)
      watch!(other, next)

      assert Enum.any?(
               gather(viewer),
               &(&1.content_id == next.id and "co_engagement" in &1.sources)
             )
    end

    test "one account replaying an item counts once in trending and quality", %{viewer: viewer} do
      creator = onboarded_user_fixture()
      replayed = ready_video_fixture(creator)
      fan = Accounts.scope_for_user(onboarded_user_fixture())
      for _ <- 1..5, do: watch!(fan, replayed)

      :ok = TrendingWorker.perform(%Oban.Job{})

      [score] =
        Repo.all(
          from t in "trending_scores",
            where: t.content_id == type(^replayed.id, :binary_id),
            select: t.score
        )

      assert_in_delta score, 1.0, 0.01

      # Smoothed completion rate: 1 completer of 1 viewer, not 5 of 5.
      candidate = Enum.find(gather(viewer), &(&1.content_id == replayed.id))
      assert_in_delta candidate.quality, (1 + 10 * Candidates.prior_rate()) / (1 + 10), 1.0e-9
    end

    test "non-personalized mode uses no source that reads the user's profile or history",
         %{viewer: viewer, scope: scope} do
      creator = onboarded_user_fixture()
      fitness = ready_video_fixture(creator, topics: ["fitness-and-exercise"])
      _more = ready_video_fixture(creator, topics: ["fitness-and-exercise"])
      watch!(scope, fitness)

      for c <- gather(viewer, %Settings{non_personalized: true}), source <- c.sources do
        assert source in ~w(following trending fresh)
      end

      assert Ranking.features(viewer.id, %Settings{non_personalized: true})
             |> Map.take([:personalized, :topic_affinity]) ==
               %{personalized: false, topic_affinity: %{}}
    end
  end

  describe "ranking" do
    test "learned interest lifts matching items, and the trace says why", %{
      viewer: viewer,
      scope: scope
    } do
      creator = onboarded_user_fixture()
      watched = ready_video_fixture(creator, topics: ["fitness-and-exercise"])
      fitness = text_post_fixture(onboarded_user_fixture(), topics: ["fitness-and-exercise"])
      cooking = text_post_fixture(onboarded_user_fixture(), topics: ["cooking"])
      watch!(scope, watched)

      ranked = Ranking.rank(viewer.id, %Settings{})
      position = fn id -> Enum.find_index(ranked, &(&1.content_id == id)) end
      assert position.(fitness.id) < position.(cooking.id)

      top = Enum.find(ranked, &(&1.content_id == fitness.id))

      assert %{
               feature: "topic_affinity",
               topic: "fitness-and-exercise",
               label_sources: ["creator"]
             } =
               Enum.find(top.contributions, &(&1[:topic] == "fitness-and-exercise"))
    end
  end

  test "a forgotten sub-topic gets no learned credit, not even half its parent's",
       %{viewer: viewer, scope: scope} do
    creator = onboarded_user_fixture()
    watch!(scope, ready_video_fixture(creator, topics: ["fitness-and-exercise"]))
    fitness = text_post_fixture(onboarded_user_fixture(), topics: ["fitness-and-exercise"])

    learned = fn ->
      Ranking.rank(viewer.id, %Settings{})
      |> Enum.find(&(&1.content_id == fitness.id))
      |> Map.fetch!(:contributions)
      |> Enum.filter(&(&1.feature == "topic_affinity"))
    end

    assert [%{topic: "fitness-and-exercise"}] = learned.()

    # Forget fitness; its parent (healthy living) keeps its learned interest.
    :ok = Transparency.forget_interest(scope, "fitness-and-exercise")
    healthy = Content.topics_by_slug()["healthy-living"].id
    assert Map.has_key?(Interests.topic_affinities(viewer.id), healthy)
    assert learned.() == []
  end

  describe "impressions" do
    defp serve!(scope, scored, settings \\ %Settings{version: 3}) do
      {:ok, served} =
        Ranking.serve(scope, scored, %{
          feed_session_id: Ecto.UUID.generate(),
          rev: 1,
          start_position: 0,
          settings: settings
        })

      served
    end

    test "are stored with the trace, the settings as they were, and the consent version",
         %{viewer: viewer, scope: scope} do
      _ = text_post_fixture(onboarded_user_fixture(), topics: ["cooking"])

      settings = %Settings{
        version: 3,
        topics: Map.new([{"cooking", %{multiplier: 2.0, hard_off: false}}])
      }

      [{scored, id} | _] = scope |> serve!(Ranking.rank(viewer.id, settings), settings)

      assert {:ok, %Impression{} = imp} = Events.get_impression(scope, id)
      assert imp.final_score === scored.final_score
      assert imp.settings_version == 3
      assert imp.consent_version == scope.consent_version
      assert imp.served_at == Impression.served_at_for(id)

      snapshot = Transparency.get_snapshot!(imp.settings_snapshot_id)
      assert snapshot.settings["topics"]["cooking"] == %{"multiplier" => 2.0, "hard_off" => false}

      # Identical settings reuse the snapshot.
      [{_, id2} | _] = serve!(scope, [scored], settings)
      {:ok, imp2} = Events.get_impression(scope, id2)
      assert imp2.settings_snapshot_id == imp.settings_snapshot_id
    end

    property "a trace read back from the database sums to the stored score, bit for bit" do
      slugs = ~w(fitness-and-exercise healthy-living cooking food-and-drink travel music)

      check all labels <-
                  list_of(
                    map(list_of(member_of(slugs), min_length: 1, max_length: 3), &Enum.uniq/1),
                    min_length: 1,
                    max_length: 6
                  ),
                multipliers <-
                  list_of(member_of([0.0, 0.5, 1.0, 1.5, 2.0]), length: length(slugs)),
                max_runs: 15 do
        viewer = onboarded_user_fixture()
        scope = Accounts.scope_for_user(viewer)
        creator = onboarded_user_fixture()
        for topics <- labels, do: text_post_fixture(creator, topics: topics)
        watch!(scope, ready_video_fixture(creator, topics: [hd(hd(labels))]))

        settings = %Settings{
          version: 1,
          topics:
            Map.new(Enum.zip(slugs, multipliers), fn {s, m} ->
              {s, %{multiplier: m, hard_off: false}}
            end)
        }

        for {scored, id} <- serve!(scope, Ranking.rank(viewer.id, settings), settings) do
          {:ok, imp} = Events.get_impression(scope, id)
          stored = Enum.map(imp.contributions, &%{contribution: &1["contribution"]})

          assert imp.final_score === scored.final_score
          assert TSpec.Feed.Ranker.sum(stored) === imp.final_score
        end
      end
    end

    test "lookups by id hit exactly one partition", %{scope: scope, viewer: viewer} do
      _ = text_post_fixture(onboarded_user_fixture())
      [{_, id} | _] = serve!(scope, Ranking.rank(viewer.id, %Settings{}))
      served_at = Impression.served_at_for(id) |> DateTime.to_iso8601()

      %{rows: rows} =
        Repo.query!(
          "EXPLAIN SELECT * FROM impressions WHERE id = '#{id}' AND served_at = '#{served_at}'"
        )

      partitions =
        for [line] <- rows,
            m = Regex.run(~r/on (impressions_\w+)/, line),
            uniq: true,
            do: Enum.at(m, 1)

      assert length(partitions) == 1
    end

    test "are private to their user, and junk ids are simply not found", %{
      scope: scope,
      viewer: viewer
    } do
      _ = text_post_fixture(onboarded_user_fixture())
      [{_, id} | _] = serve!(scope, Ranking.rank(viewer.id, %Settings{}))

      other = Accounts.scope_for_user(onboarded_user_fixture())
      assert {:error, :not_found} = Events.get_impression(other, id)
      assert {:error, :not_found} = Events.get_impression(scope, Ecto.UUID.generate())
      assert {:error, :not_found} = Events.get_impression(scope, "nope")
    end

    test "a view_start can mark its impression exposed; someone else's impression id is dropped",
         %{scope: scope, viewer: viewer} do
      item = text_post_fixture(onboarded_user_fixture())
      [{_, id} | _] = serve!(scope, Ranking.rank(viewer.id, %Settings{}))
      {:ok, imp} = Events.get_impression(scope, id)
      now = DateTime.utc_now()

      start = %{
        content_id: imp.content_id,
        type: "view_start",
        occurred_at: now,
        impression_id: id
      }

      {:ok, %{accepted: 1}} = Events.record(scope, [start])

      other = Accounts.scope_for_user(onboarded_user_fixture())
      {:ok, %{accepted: 2}} = Events.record(other, [start, %{start | content_id: item.id}])

      stored =
        from(e in Events.Event,
          where: e.type == "view_start",
          select: {e.user_id, e.impression_id}
        )
        |> Repo.all()

      assert {viewer.id, id} in stored
      assert Enum.count(stored, fn {u, i} -> u == other.user.id and is_nil(i) end) == 2
    end
  end

  test "unshown impressions are pruned after 30 days; shown and recent ones stay",
       %{scope: scope, viewer: viewer} do
    for _ <- 1..3, do: text_post_fixture(onboarded_user_fixture())

    [a, b, c] = Ranking.rank(viewer.id, %Settings{}) |> Enum.take(3)

    # Three impressions served 40 days ago (old UUIDv7 ids, so old
    # served_at), plus one served now. Only the old shown one survives.
    old_ms = System.system_time(:millisecond) - 40 * 86_400_000

    insert = fn scored, id ->
      Repo.insert_all(Impression, [
        %{
          id: id,
          served_at: Impression.served_at_for(id),
          user_id: viewer.id,
          content_id: scored.content_id,
          feed_session_id: Ecto.UUID.generate(),
          rev: 0,
          position: 0,
          ranker_version: "v1",
          candidate_source: scored.candidate_source,
          sources: scored.sources,
          final_score: scored.final_score,
          contributions: scored.contributions,
          settings_version: 0,
          settings_snapshot_id: Transparency.snapshot_settings(viewer.id, %Settings{}),
          consent_version: scope.consent_version
        }
      ])

      id
    end

    old_shown = insert.(a, UUIDv7.generate(old_ms))
    old_unshown = insert.(b, UUIDv7.generate(old_ms + 1))
    recent_unshown = insert.(c, UUIDv7.generate())

    Repo.insert_all(Events.Event, [
      %{
        id: UUIDv7.generate(),
        user_id: viewer.id,
        content_id: a.content_id,
        type: "view_start",
        occurred_at: DateTime.add(DateTime.utc_now(), -40, :day),
        received_at: DateTime.add(DateTime.utc_now(), -40, :day),
        impression_id: old_shown,
        consent_version: scope.consent_version
      }
    ])

    :ok = TSpec.Events.ImpressionPruneWorker.perform(%Oban.Job{})

    assert {:ok, _} = Events.get_impression(scope, old_shown)
    assert {:error, :not_found} = Events.get_impression(scope, old_unshown)
    assert {:ok, _} = Events.get_impression(scope, recent_unshown)
  end

  test "trending decays with age and counts only recent completions" do
    creator = onboarded_user_fixture()
    fresh = ready_video_fixture(creator)
    old = ready_video_fixture(creator)

    Repo.update_all(from(i in Content.Item, where: i.id == ^old.id),
      set: [published_at: DateTime.add(DateTime.utc_now(), -2, :day)]
    )

    for item <- [fresh, old], _ <- 1..2 do
      watch!(Accounts.scope_for_user(onboarded_user_fixture()), item)
    end

    :ok = TrendingWorker.perform(%Oban.Job{})

    scores =
      Repo.all(from t in "trending_scores", select: {t.content_id, t.score})
      |> Map.new(fn {k, v} -> {Ecto.UUID.cast!(k), v} end)

    assert_in_delta scores[fresh.id], 2.0, 0.01
    assert_in_delta scores[old.id], 1.0, 0.01
  end
end
