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

  test "position reports are matched by impression id, whatever rev they carry",
       %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, %{items: page}} = Session.next_page(pid, 10)
    Session.at(pid, Enum.at(imps(page), 1), 0)
    sub(scope, sid)

    {:ok, _} = Transparency.update_settings(scope, %{sources: %{"fresh" => 2.0}})
    assert_receive {:feed_reranked, %{rev: 1, items: new}}, 2_000

    # A kept item reported with the old rev still sets the position.
    Session.at(pid, Enum.at(imps(page), 0), 0)
    assert Session.state(pid).position == 0

    Session.at(pid, hd(imps(new)), 1)
    assert Session.state(pid).position == 2
  end

  test "an item the client kept on screen through a re-rank is never served again",
       %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, %{items: page}} = Session.next_page(pid, 10)
    Session.at(pid, Enum.at(imps(page), 0), 0)
    sub(scope, sid)

    # The server re-ranks after item 0, but the client had already moved on
    # (its `at` crossed the push) and keeps that item on screen. Pick one the
    # re-rank removed and didn't push again (boosting travel pushes travel).
    {:ok, _} = Transparency.update_settings(scope, %{topics: %{"travel" => %{multiplier: 2.0}}})
    assert_receive {:feed_reranked, %{rev: 1, items: tail}}, 2_000

    {kept_content, kept_imp} =
      page
      |> Enum.drop(1)
      |> Enum.map(fn {s, i} -> {s.content_id, i} end)
      |> Enum.find(fn {c, _} -> c not in ids(tail) end)

    refute Enum.any?(Session.state(pid).served, &(&1.content_id == kept_content))

    Session.at(pid, kept_imp, 0)
    assert MapSet.member?(Session.state(pid).client_kept, kept_content)

    {:ok, %{items: more}} = Session.next_page(pid, 100)
    refute kept_content in ids(more)
  end

  test "settings changed while the session was down: it re-ranks the client's tail on start",
       %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, %{items: page}} = Session.next_page(pid, 10)

    # The client showed the first three items (exposures are recorded).
    now = DateTime.utc_now()

    {:ok, _} =
      Events.record(
        scope,
        for {s, imp} <- Enum.take(page, 3) do
          %{content_id: s.content_id, type: "view_start", occurred_at: now, impression_id: imp}
        end
      )

    # The process idles out; meanwhile a change is saved (e.g. from the
    # Algorithm tab), with nothing listening.
    :ok = GenServer.stop(pid)
    {:ok, %{version: 1}} = Transparency.update_settings(scope, %{sources: %{"fresh" => 2.0}})

    # The client comes back: subscribe (as the channel join does), then start.
    sub(scope, sid)
    {:ok, pid2} = Session.ensure(scope, sid)

    assert_receive {:feed_reranked, %{rev: 1, after_impression_id: anchor, items: tail}}, 2_000
    assert anchor == Enum.at(imps(page), 2)

    for {_s, imp} <- tail,
        do: assert({:ok, %{settings_version: 1}} = Events.get_impression(scope, imp))

    assert Session.state(pid2).settings.version == 1
  end

  test "a refill that finishes instantly isn't mistaken for a crash", %{
    scope: scope,
    items: items
  } do
    # Refills that return at once (here: a canned, non-empty list) can finish
    # before the session would get to monitor them. That must not look like
    # a failure and trigger the 60 s back-off.
    canned =
      Candidates.gather(
        scope.user.id,
        %Settings{},
        TSpec.Feed.Ranking.features(scope.user.id, %Settings{})
      )

    for round <- 1..30 do
      extra = Enum.at(canned, 3 + round)

      gather = fn _user_id, _settings, _features, opts ->
        if opts[:refill], do: [extra], else: Enum.take(canned, 3)
      end

      {_sid, pid} = start!(scope, gather: gather)
      {:ok, _} = Session.next_page(pid, 1)
      settle(pid)
      _ = Session.state(pid)
      assert Session.state(pid).empty_refill_at == nil, "round #{round}: spurious back-off"
      GenServer.stop(pid)
    end
  end

  test "a refill task that crashes doesn't stall future refills", %{scope: scope} do
    test = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    # The first refill blows up (say, a database timeout); later ones work.
    gather = fn user_id, settings, features, opts ->
      if opts[:refill] && Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0 do
        send(test, :refill_crashed)
        raise "simulated database timeout"
      end

      found = Candidates.gather(user_id, settings, features, opts)
      if opts[:refill], do: found, else: Enum.take(found, 12)
    end

    {sid, pid} = start!(scope, gather: gather)
    {:ok, _} = Session.next_page(pid, 5)
    assert_receive :refill_crashed, 2_000
    settle(pid)

    state = Session.state(pid)
    assert state.refilling == nil
    assert is_integer(state.empty_refill_at)

    # The next refill (here, from a settings change) runs and lands.
    sub(scope, sid)
    {:ok, _} = Transparency.update_settings(scope, %{topics: %{"travel" => %{multiplier: 2.0}}})
    settle(pid)
    assert map_size(Session.state(pid).cache) > 12
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

  defp pushed_ids(acc \\ []) do
    receive do
      {:feed_reranked, %{items: items}} -> pushed_ids(acc ++ ids(items))
    after
      0 -> acc
    end
  end

  # Polls until the session has no refill in flight.
  defp settle(pid, tries \\ 100) do
    if Session.state(pid).refilling == nil or tries == 0 do
      :ok
    else
      Process.sleep(20)
      settle(pid, tries - 1)
    end
  end

  test "refills keep coming under the same settings: a long scroll never runs dry",
       %{scope: scope, items: items} do
    all = items |> Map.values() |> Enum.reduce(&MapSet.union/2)

    # Start with 35 candidates; each refill brings at most 15 more. Draining
    # all 80 items takes several refill cycles under settings version 0.
    gather = fn user_id, settings, features, opts ->
      found =
        Candidates.gather(user_id, settings, features, opts) |> Enum.sort_by(& &1.content_id)

      if opts[:refill], do: Enum.take(found, 15), else: Enum.take(found, 35)
    end

    {sid, pid} = start!(scope, gather: gather)
    sub(scope, sid)

    # Like a client: take each page, report the last item as current, and
    # also take whatever the session pushes (a refill tops up the tail).
    served =
      Enum.reduce_while(1..30, MapSet.new(), fn _, acc ->
        {:ok, %{rev: rev, items: page}} = Session.next_page(pid, 10)
        if page != [], do: Session.at(pid, List.last(imps(page)), rev)
        settle(pid)
        acc = MapSet.union(acc, MapSet.new(ids(page)))
        acc = MapSet.union(acc, MapSet.new(pushed_ids()))

        if page == [] and Session.state(pid).refilling == nil,
          do: {:halt, acc},
          else: {:cont, acc}
      end)

    assert MapSet.equal?(served, all), "served #{MapSet.size(served)} of #{MapSet.size(all)}"
    assert Session.state(pid).settings.version == 0
  end

  test "a restarted session rebuilds the client's list, revision and position",
       %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, %{items: page}} = Session.next_page(pid, 10)

    # The client showed the first four items, then re-ranked (rev 1).
    now = DateTime.utc_now()

    {:ok, _} =
      Events.record(
        scope,
        for {s, imp} <- Enum.take(page, 4) do
          %{content_id: s.content_id, type: "view_start", occurred_at: now, impression_id: imp}
        end
      )

    Session.at(pid, Enum.at(imps(page), 3), 0)
    sub(scope, sid)
    {:ok, _} = Transparency.update_settings(scope, %{sources: %{"fresh" => 2.0}})
    assert_receive {:feed_reranked, %{rev: 1, items: tail}}, 2_000
    before = Session.state(pid)

    # The process goes away (idle timeout, crash, deploy) and comes back.
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    {:ok, pid2} = Session.ensure(scope, sid)
    after_restart = Session.state(pid2)

    assert after_restart.rev == 1

    assert Enum.map(after_restart.served, & &1.impression_id) ==
             Enum.map(before.served, & &1.impression_id)

    assert Enum.map(after_restart.served, & &1.impression_id) ==
             Enum.take(imps(page), 4) ++ imps(tail)

    assert after_restart.position == 3

    # The client's rev-1 messages still count, and the next push continues
    # the numbering from the same anchor.
    Session.at(pid2, hd(imps(tail)), 1)
    assert Session.state(pid2).position == 4
    {:ok, _} = Transparency.update_settings(scope, %{sources: %{"fresh" => 1.5}})
    assert_receive {:feed_reranked, %{rev: 2, after_impression_id: anchor}}, 2_000
    assert anchor == hd(imps(tail))

    # And it doesn't re-serve what the client already holds.
    {:ok, %{items: more}} = Session.next_page(pid2, 50)

    assert MapSet.disjoint?(
             MapSet.new(ids(more)),
             MapSet.new(Enum.map(before.served, & &1.content_id))
           )
  end

  test "a client ahead of the session (empty re-ranks leave no impressions) is adopted",
       %{scope: scope} do
    {sid, pid} = start!(scope)
    {:ok, _} = Session.next_page(pid, 5)
    Session.sync_rev(pid, 7)
    assert Session.state(pid).rev == 7

    # A lower rev never moves it back.
    Session.sync_rev(pid, 3)
    assert Session.state(pid).rev == 7

    sub(scope, sid)
    {:ok, _} = Transparency.update_settings(scope, %{sources: %{"fresh" => 2.0}})
    assert_receive {:feed_reranked, %{rev: 8}}, 2_000
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
