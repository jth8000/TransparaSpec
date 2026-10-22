defmodule TSpec.Feed.InterestsConcurrencyTest do
  @moduledoc """
  Interest-model guarantees that only show up with real concurrent
  transactions (ADR 0012). The SQL sandbox runs a test inside one
  transaction on one connection, where locks never block and nothing
  commits, so these tests run unboxed: each process gets its own connection
  and its writes really commit. Everything created is deleted afterwards.

  Not async: ExUnit runs these after the async suites, so committed rows
  never leak into tests that count things.
  """
  use TSpec.DataCase, async: false

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias TSpec.{Accounts, Content, Events, Repo, Transparency}
  alias TSpec.Feed.{Interests, TopicAffinity, ViewEngagement}

  setup do
    %{creator: creator, viewer: viewer} =
      ctx =
      unboxed(fn ->
        creator = onboarded_user_fixture()
        viewer = onboarded_user_fixture()
        cooking = ready_video_fixture(creator, topics: ["cooking"])
        %{creator: creator, viewer: viewer, cooking: cooking}
      end)

    ids = [creator.id, viewer.id]

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from j in Oban.Job, where: fragment("?->>'user_id'", j.args) in ^ids)
        Repo.delete_all(from u in Accounts.User, where: u.id in ^ids)
      end)
    end)

    ctx
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Runs `fun` unboxed in its own process.
  defp spawn_unboxed(fun), do: Task.async(fn -> unboxed(fun) end)

  defp completed_view(item, view_id) do
    now = DateTime.utc_now()

    [
      %{content_id: item.id, view_id: view_id, type: "view_start", occurred_at: now},
      %{content_id: item.id, view_id: view_id, type: "complete", value: 2.0, occurred_at: now}
    ]
  end

  defp cooking_score(user) do
    topic = Content.topics_by_slug()["cooking"].id

    unboxed(fn ->
      case Repo.get_by(TopicAffinity, user_id: user.id, topic_id: topic) do
        nil -> 0.0
        a -> a.score
      end
    end)
  end

  defp blocked?(task), do: Task.yield(task, 200) == nil

  test "a view committed late, after newer views were applied, is still applied",
       %{viewer: viewer, cooking: cooking} do
    scope = Accounts.scope_for_user(viewer)
    {v1, v2} = {Ecto.UUID.generate(), Ecto.UUID.generate()}
    parent = self()
    now = DateTime.utc_now()

    # A records V1 first but holds its transaction open.
    a =
      spawn_unboxed(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Events.record(scope, completed_view(cooking, v1))
          send(parent, :a_recorded)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :a_recorded, 5_000

    # B records V2 and commits; the worker runs and sees only V2.
    unboxed(fn ->
      {:ok, _} = Events.record(scope, completed_view(cooking, v2))
      {:ok, %{applied: 1}} = Interests.apply_dirty_views(viewer.id, now: now)
    end)

    assert_in_delta cooking_score(viewer), 1.0, 1.0e-12

    # A commits long "after" the worker moved on. There is no cursor for it to
    # have fallen behind: it's simply a dirty row now.
    send(a.pid, :commit)
    Task.await(a)

    unboxed(fn -> {:ok, %{applied: 1}} = Interests.apply_dirty_views(viewer.id, now: now) end)
    assert_in_delta cooking_score(viewer), 2.0, 1.0e-12
  end

  test "two workers applying different views of the same topic don't lose an update",
       %{viewer: viewer, cooking: cooking} do
    scope = Accounts.scope_for_user(viewer)
    now = DateTime.utc_now()

    unboxed(fn ->
      {:ok, _} = Events.record(scope, completed_view(cooking, Ecto.UUID.generate()))
      {:ok, _} = Events.record(scope, completed_view(cooking, Ecto.UUID.generate()))
    end)

    # Both start together; each takes at most one view.
    parent = self()

    workers =
      for _ <- 1..2 do
        spawn_unboxed(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          Interests.apply_dirty_views(viewer.id, now: now, limit: 1)
        end)
      end

    pids =
      for _ <- workers do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(workers, &Task.await/1)

    assert Enum.sort(for {:ok, %{applied: n}} <- results, do: n) == [1, 1]
    assert_in_delta cooking_score(viewer), 2.0, 1.0e-12
  end

  test "the upsert alone is safe under a real race, even with out-of-order timestamps",
       %{viewer: viewer} do
    # No advisory lock here: two transactions write the same affinity row.
    # The second blocks on the row lock until the first commits, then folds
    # in its own delta. The later-stamped write commits first on purpose.
    topic = Content.topics_by_slug()["travel"].id
    t0 = ~U[2026-10-01 00:00:00.000000Z]
    t14 = DateTime.add(t0, 14, :day)
    sql = Interests.upsert_sql(:topic)
    params = fn at -> [Ecto.UUID.dump!(viewer.id), [Ecto.UUID.dump!(topic)], [1.0], [1], at] end
    parent = self()

    first =
      spawn_unboxed(fn ->
        Repo.transaction(fn ->
          Repo.query!(sql, params.(t14))
          send(parent, :first_wrote)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :first_wrote, 5_000
    second = spawn_unboxed(fn -> Repo.transaction(fn -> Repo.query!(sql, params.(t0)) end) end)
    assert blocked?(second), "the second upsert should wait for the first's row lock"

    send(first.pid, :commit)
    Task.await(first)
    Task.await(second)

    %{score: score, evidence_count: 2} =
      unboxed(fn -> Repo.get_by!(TopicAffinity, user_id: viewer.id, topic_id: topic) end)

    # The t0 delta decayed to t14 (0.5) plus the t14 delta (1.0).
    assert_in_delta score, 1.5, 1.0e-9
  end

  test "switching to non-personalized waits for an in-flight record, then ratchets its view",
       %{viewer: viewer, cooking: cooking} do
    scope = Accounts.scope_for_user(viewer)
    v = Ecto.UUID.generate()
    parent = self()

    # The record transaction reads the mode (personalized) under FOR SHARE and
    # creates a learnable view, then stalls before committing.
    recording =
      spawn_unboxed(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Events.record(scope, completed_view(cooking, v))
          send(parent, :recorded)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :recorded, 5_000

    switching = spawn_unboxed(fn -> Transparency.set_non_personalized(scope, true) end)
    assert blocked?(switching), "the mode switch should wait for the recording transaction"

    send(recording.pid, :commit)
    Task.await(recording)
    assert {:ok, %{non_personalized: true}} = Task.await(switching)

    # The view was created learnable, then ratcheted once the switch ran.
    assert %{learnable: false} = unboxed(fn -> Repo.get!(ViewEngagement, v) end)

    unboxed(fn -> {:ok, _} = Interests.apply_dirty_views(viewer.id) end)
    assert cooking_score(viewer) == 0.0
  end

  test "a record that starts during an uncommitted mode switch waits for it and sees the new mode",
       %{viewer: viewer, cooking: cooking} do
    # The other ordering. Without the FOR SHARE read, the record would read
    # the old mode (personalized) right away, then create a learnable view
    # after the switch's ratchet had already run.
    scope = Accounts.scope_for_user(viewer)
    v = Ecto.UUID.generate()
    parent = self()

    switching =
      spawn_unboxed(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Transparency.set_non_personalized(scope, true)
          send(parent, :switched)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :switched, 5_000

    recording = spawn_unboxed(fn -> Events.record(scope, completed_view(cooking, v)) end)
    assert blocked?(recording), "the record should wait for the mode switch"

    send(switching.pid, :commit)
    Task.await(switching)
    assert {:ok, %{accepted: 2}} = Task.await(recording)

    assert %{learnable: false} = unboxed(fn -> Repo.get!(ViewEngagement, v) end)
  end
end
