defmodule TSpec.Feed.SessionTest do
  @moduledoc """
  Feed sessions (ADR 0011): paging, live re-rank, revisions, refill and
  stale-work handling. Not async: sessions run under the application's
  supervisor, outside the test process, so they share the sandbox.
  """
  use TSpec.DataCase, async: false

  # Stopping sessions mid-query at test exit logs harmless disconnects.
  @moduletag :capture_log

  import TSpec.AccountsFixtures

  alias TSpec.{Accounts, Content, Events, Transparency}
  alias TSpec.Feed.{Candidates, Ranker, Session, Settings}

  setup do
    on_exit(&TSpec.DataCase.stop_feed_sessions/0)

    viewer = onboarded_user_fixture()
    creators = for _ <- 1..6, do: onboarded_user_fixture()

    items = %{
      fitness: bulk_items(creators, 30, "fitness-and-exercise"),
      cooking: bulk_items(creators, 30, "cooking"),
      travel: bulk_items(creators, 20, "travel")
    }

    %{viewer: viewer, scope: Accounts.scope_for_user(viewer), items: items}
  end

  # Ready text posts labeled with one topic, by rotating creators.
  defp bulk_items(creators, n, slug) do
    topic_id = Content.topics_by_slug()[slug].id
    now = DateTime.utc_now()

    rows =
      for i <- 1..n do
        %{
          id: UUIDv7.generate(),
          author_id: Enum.at(creators, rem(i, length(creators))).id,
          kind: "text_post",
          status: "ready",
          visibility: "public",
          published_at: DateTime.add(now, -i * 60, :second),
          inserted_at: DateTime.truncate(now, :second),
          updated_at: DateTime.truncate(now, :second)
        }
      end

    Repo.insert_all(Content.Item, rows)

    Repo.insert_all(
      Content.TextPost,
      for(r <- rows, do: %{content_id: r.id, body: "#{slug} #{r.id}"})
    )

    Repo.insert_all(
      Content.ContentTopic,
      for(
        r <- rows,
        do: %{content_id: r.id, topic_id: topic_id, source: "creator", confidence: 1.0}
      )
    )

    MapSet.new(rows, & &1.id)
  end

  defp ids(pairs), do: Enum.map(pairs, fn {s, _} -> s.content_id end)
  defp imps(pairs), do: Enum.map(pairs, fn {_, i} -> i end)

  defp sub(scope, sid),
    do: Phoenix.PubSub.subscribe(TSpec.PubSub, Session.topic(scope.user.id, sid))

  defp start!(scope, opts \\ []) do
    sid = Ecto.UUID.generate()
    {:ok, pid} = Session.ensure(scope, sid, opts)
    {sid, pid}
  end

  defp labeled?(content_id, items, topic), do: MapSet.member?(items[topic], content_id)

  test "pages continue without repeats, with an impression per served item", %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, %{rev: 0, items: p1}} = Session.next_page(pid, 10)
    {:ok, %{rev: 0, items: p2}} = Session.next_page(pid, 10)

    assert length(p1) == 10 and length(p2) == 10
    assert MapSet.disjoint?(MapSet.new(ids(p1)), MapSet.new(ids(p2)))

    for id <- imps(p1 ++ p2) do
      assert {:ok, %{feed_session_id: ^sid, rev: 0}} = Events.get_impression(scope, id)
    end

    assert Enum.map(Session.state(pid).served, & &1.impression_id) == imps(p1 ++ p2)
  end

  test "two sessions of one user keep their own positions, and both re-rank on a change",
       %{scope: scope, items: items} do
    {sid1, s1} = start!(scope)
    {sid2, s2} = start!(scope)
    {:ok, %{items: a}} = Session.next_page(s1, 10)
    {:ok, %{items: b}} = Session.next_page(s2, 10)

    Session.at(s1, Enum.at(imps(a), 2), 0)
    Session.at(s2, Enum.at(imps(b), 6), 0)
    sub(scope, sid1)
    sub(scope, sid2)

    {:ok, _} =
      Transparency.update_settings(scope, %{
        topics: %{"fitness-and-exercise" => %{hard_off: true}}
      })

    assert_receive {:feed_reranked, %{session_id: ^sid1, rev: 1} = r1}, 2_000
    assert_receive {:feed_reranked, %{session_id: ^sid2, rev: 1} = r2}, 2_000

    # Each kept exactly its own prefix, through its own current item.
    assert r1.after_impression_id == Enum.at(imps(a), 2)
    assert r2.after_impression_id == Enum.at(imps(b), 6)

    assert Enum.take(Session.state(s1).served, 3) |> Enum.map(& &1.impression_id) ==
             Enum.take(imps(a), 3)

    assert Enum.take(Session.state(s2).served, 7) |> Enum.map(& &1.impression_id) ==
             Enum.take(imps(b), 7)

    # New tails: no fitness, written to their own session.
    for {r, sid} <- [{r1, sid1}, {r2, sid2}], {s, imp} <- r.items do
      refute labeled?(s.content_id, items, :fitness)

      assert {:ok, %{feed_session_id: ^sid, rev: 1, settings_version: 1}} =
               Events.get_impression(scope, imp)
    end
  end

  test "a stale `at` (older rev) doesn't move the position", %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, %{items: page}} = Session.next_page(pid, 10)
    Session.at(pid, Enum.at(imps(page), 1), 0)
    sub(scope, sid)

    {:ok, _} = Transparency.update_settings(scope, %{sources: %{"fresh" => 2.0}})
    assert_receive {:feed_reranked, %{rev: 1, items: new}}, 2_000

    Session.at(pid, List.last(imps(page)), 0)
    assert Session.state(pid).position == 1

    Session.at(pid, hd(imps(new)), 1)
    assert Session.state(pid).position == 2
  end

  test "a settings broadcast older than the session's version is ignored", %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, _} = Session.next_page(pid, 10)
    sub(scope, sid)
    {:ok, s} = Transparency.update_settings(scope, %{sources: %{"fresh" => 2.0}})
    assert_receive {:feed_reranked, %{rev: 1}}, 2_000

    send(
      pid,
      {:settings_changed,
       %{s | version: 0, topics: %{"cooking" => %{multiplier: 0.0, hard_off: true}}}}
    )

    refute_receive {:feed_reranked, _}, 200
    assert Session.state(pid).settings.version == 1
  end

  test "when hard-off drains the cache, a refill tops the tail back up",
       %{scope: scope, viewer: viewer, items: items} do
    # Start with a cache that's mostly fitness: 30 fitness + 8 cooking.
    some_cooking = items.cooking |> Enum.take(8) |> MapSet.new()

    gather = fn user_id, settings, features, opts ->
      all = Candidates.gather(user_id, settings, features, opts)

      if opts[:refill],
        do: all,
        else:
          Enum.filter(
            all,
            &(labeled?(&1.content_id, items, :fitness) or
                MapSet.member?(some_cooking, &1.content_id))
          )
    end

    {sid, pid} = start!(scope, gather: gather)
    {:ok, _} = Session.next_page(pid, 5)
    sub(scope, sid)

    {:ok, _} =
      Transparency.update_settings(scope, %{
        topics: %{"fitness-and-exercise" => %{hard_off: true}}
      })

    # First push: what the cache had left. Then the refill's, at rev 2.
    assert_receive {:feed_reranked, %{rev: 1}}, 2_000
    assert_receive {:feed_reranked, %{rev: 2, items: refilled}}, 2_000
    assert length(refilled) == 10
    refute Enum.any?(ids(refilled), &labeled?(&1, items, :fitness))
    _ = viewer
  end

  test "boosting a topic missing from the cache brings it in", %{scope: scope, items: items} do
    gather = fn user_id, settings, features, opts ->
      all = Candidates.gather(user_id, settings, features, opts)
      if opts[:refill], do: all, else: Enum.reject(all, &labeled?(&1.content_id, items, :travel))
    end

    {sid, pid} = start!(scope, gather: gather)
    {:ok, _} = Session.next_page(pid, 5)
    sub(scope, sid)

    {:ok, _} = Transparency.update_settings(scope, %{topics: %{"travel" => %{multiplier: 2.0}}})

    assert_receive {:feed_reranked, %{rev: 1, items: first}}, 2_000
    refute Enum.any?(ids(first), &labeled?(&1, items, :travel))

    assert_receive {:feed_reranked, %{rev: 2, items: second}}, 2_000
    assert ids(second) |> Enum.take(5) |> Enum.all?(&labeled?(&1, items, :travel))
  end

  test "a refill that finishes after newer settings is discarded; the newer one wins",
       %{scope: scope, items: items} do
    test = self()
    # A fitness item that only the stale v1 refill would bring in.
    marker = items.fitness |> Enum.sort() |> hd()

    gather = fn user_id, settings, features, opts ->
      all = Candidates.gather(user_id, settings, features, opts)

      cond do
        !opts[:refill] ->
          Enum.reject(all, &(labeled?(&1.content_id, items, :travel) or &1.content_id == marker))

        settings.version == 1 ->
          send(test, {:v1_refill_waiting, self()})
          receive do: (:release -> :ok)
          stale = Candidates.gather(user_id, %Settings{}, features, sources: ["fresh"])
          Enum.filter(stale, &(&1.content_id == marker)) ++ all

        true ->
          all
      end
    end

    {sid, pid} = start!(scope, gather: gather)
    {:ok, _} = Session.next_page(pid, 5)
    sub(scope, sid)

    # v1: boost travel (missing from the cache) -> its refill is held back.
    {:ok, _} = Transparency.update_settings(scope, %{topics: %{"travel" => %{multiplier: 2.0}}})
    assert_receive {:v1_refill_waiting, v1_task}, 2_000
    assert_receive {:feed_reranked, %{rev: 1}}, 2_000

    # v2: fitness off. It starts its own refill for the still-missing travel.
    {:ok, %{version: 2}} =
      Transparency.update_settings(scope, %{
        topics: %{"fitness-and-exercise" => %{hard_off: true}}
      })

    assert_receive {:feed_reranked, %{rev: 2}}, 2_000
    assert_receive {:feed_reranked, %{rev: 3, items: v2_refill}}, 2_000
    assert Enum.any?(ids(v2_refill), &labeled?(&1, items, :travel))

    # The stale v1 result arrives last and is dropped: no push, no merge.
    send(v1_task, :release)
    refute_receive {:feed_reranked, _}, 300

    state = Session.state(pid)
    refute Map.has_key?(state.cache, marker)
    refute Enum.any?(Enum.drop(state.served, 1), &labeled?(&1.content_id, items, :fitness))
  end

  test "a crashed session restarts clean and doesn't repeat what the user watched",
       %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, %{items: page}} = Session.next_page(pid, 10)

    # The user actually watched the first three.
    now = DateTime.utc_now()

    events =
      for {s, imp} <- Enum.take(page, 3) do
        %{
          content_id: s.content_id,
          type: "view_start",
          occurred_at: now,
          view_id: Ecto.UUID.generate(),
          impression_id: imp
        }
      end

    {:ok, %{accepted: 3}} = Events.record(scope, events)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Even right after the crash (the Registry may not have caught up yet),
    # ensure hands out a live process.
    {:ok, pid2} = Session.ensure(scope, sid)
    refute pid2 == pid
    assert Process.alive?(pid2)

    {:ok, %{items: again}} = Session.next_page(pid2, 50)
    assert MapSet.disjoint?(MapSet.new(ids(again)), MapSet.new(ids(Enum.take(page, 3))))
  end

  test "re-ranking 500 candidates is fast", %{scope: scope, viewer: viewer} do
    creators = for _ <- 1..10, do: onboarded_user_fixture()

    more =
      for slug <- ~w(music video-gaming travel cooking fitness-and-exercise),
          reduce: MapSet.new() do
        acc -> MapSet.union(acc, bulk_items(creators, 100, slug))
      end

    settings = %Settings{version: 1, topics: %{"cooking" => %{multiplier: 2.0, hard_off: false}}}
    features = TSpec.Feed.Ranking.features(viewer.id, settings)

    # Source limits keep a normal pool smaller; build exactly 500 directly.
    candidates =
      more
      |> Enum.take(500)
      |> Map.new(&{&1, ["fresh", "topic"]})
      |> Candidates.hydrate(viewer.id)

    assert length(candidates) == 500

    taxonomy = Content.topics_by_id()
    {micros, ranked} = :timer.tc(fn -> Ranker.rank(candidates, features, settings, taxonomy) end)
    assert length(ranked) == length(candidates)
    IO.puts("\n    ranker: #{length(candidates)} candidates in #{div(micros, 1000)} ms")
    assert micros < 100_000

    # End to end through a live session: settings change → push received.
    {sid, pid} = start!(scope)
    {:ok, _} = Session.next_page(pid, 10)
    sub(scope, sid)

    {micros, _} =
      :timer.tc(fn ->
        {:ok, _} = Transparency.update_settings(scope, %{topics: %{"music" => %{hard_off: true}}})
        assert_receive {:feed_reranked, %{rev: 1}}, 2_000
      end)

    IO.puts(
      "    settings change → re-ranked page pushed: #{div(micros, 1000)} ms (#{map_size(Session.state(pid).cache)} cached)"
    )

    assert micros < 500_000
  end
end
