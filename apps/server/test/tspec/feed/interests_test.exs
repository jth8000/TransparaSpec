defmodule TSpec.Feed.InterestsTest do
  @moduledoc """
  The interest model through its real entry points: `Events.record/2` (which
  writes view state) and the affinity worker. Concurrency cases that need
  real, separately committed transactions are in
  `TSpec.Feed.InterestsConcurrencyTest`.
  """
  use TSpec.DataCase, async: true
  use ExUnitProperties
  use Oban.Testing, repo: TSpec.Repo

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Content, Events, Transparency}
  alias TSpec.Feed.{AffinityWorker, Interests, ViewEngagement}
  alias TSpec.Feed.Interests.Weights

  doctest TSpec.Feed.Interests

  @w Weights.defaults()

  setup do
    creator = onboarded_user_fixture()
    viewer = onboarded_user_fixture()

    # ready_video_fixture: duration 2_000 ms.
    fitness = ready_video_fixture(creator, topics: ["fitness-and-exercise"])

    %{creator: creator, viewer: viewer, scope: Accounts.scope_for_user(viewer), fitness: fitness}
  end

  defp ev(item, view_id, type, value \\ nil) do
    %{
      content_id: item.id,
      view_id: view_id,
      type: type,
      value: value,
      occurred_at: DateTime.utc_now()
    }
  end

  defp record!(scope, events) do
    {:ok, %{rejected: 0}} = Events.record(scope, events)
  end

  defp apply!(user, now), do: {:ok, _} = Interests.apply_dirty_views(user.id, now: now)

  # Raw stored scores (no decay applied), by topic slug.
  defp scores(user) do
    by_id = Content.topics_by_id()

    from(a in TSpec.Feed.TopicAffinity, where: a.user_id == ^user.id)
    |> Repo.all()
    |> Map.new(&{by_id[&1.topic_id].slug, &1.score})
  end

  defp view(view_id), do: Repo.get!(ViewEngagement, view_id)

  describe "target_delta/2" do
    test "a long and a short video watched to the same fraction are worth the same" do
      short = %{duration_ms: 10_000, watched_ms: 6_000, completed: false, early_skip: false}
      long = %{duration_ms: 180_000, watched_ms: 108_000, completed: false, early_skip: false}
      assert Interests.target_delta(short, @w) == Interests.target_delta(long, @w)
    end

    test "completion beats any partial watch; looping adds the bonus once" do
      done = %{duration_ms: 10_000, watched_ms: 10_000, completed: true, early_skip: false}
      assert Interests.target_delta(done, @w) == 1.0
      assert Interests.target_delta(%{done | watched_ms: 20_000}, @w) == 1.25
      assert Interests.target_delta(%{done | watched_ms: 90_000}, @w) == 1.25

      almost = %{done | completed: false, watched_ms: 9_999}
      assert Interests.target_delta(almost, @w) < 1.0
    end

    test "an early skip is negative only if they really left early" do
      skip = %{duration_ms: 10_000, watched_ms: 1_000, completed: false, early_skip: true}
      assert Interests.target_delta(skip, @w) == -0.5
      # A later batch showing more watching overrides the early-skip penalty.
      assert Interests.target_delta(%{skip | watched_ms: 5_000}, @w) == 0.4
    end

    test "content without a duration counts a view" do
      assert Interests.target_delta(
               %{duration_ms: nil, watched_ms: 0, completed: false, early_skip: false},
               @w
             ) ==
               0.1
    end
  end

  describe "decay" do
    test "matches the closed form, and decay-on-update composes" do
      t0 = ~U[2026-10-01 00:00:00.000000Z]
      t14 = DateTime.add(t0, 14, :day)
      t28 = DateTime.add(t0, 28, :day)

      assert_in_delta Interests.decay(4.0, t0, t14, @w), 2.0, 1.0e-12
      assert_in_delta Interests.decay(4.0, t0, t28, @w), 1.0, 1.0e-12
      # Clock skew never grows a score.
      assert Interests.decay(4.0, t14, t0, @w) == 4.0
    end

    property "never flips the sign and never grows" do
      check all(
              score <- float(min: -100.0, max: 100.0),
              days <- integer(0..400)
            ) do
        t0 = ~U[2026-01-01 00:00:00.000000Z]
        decayed = Interests.decay(score, t0, DateTime.add(t0, days, :day), @w)
        assert abs(decayed) <= abs(score)
        assert decayed == 0.0 or decayed * score > 0
      end
    end

    test "an update decays the old score forward before adding", %{
      viewer: viewer,
      scope: scope,
      fitness: fitness
    } do
      t0 = ~U[2026-10-01 00:00:00.000000Z]
      v1 = Ecto.UUID.generate()
      record!(scope, [ev(fitness, v1, "view_start"), ev(fitness, v1, "complete", 2.0)])
      apply!(viewer, t0)

      v2 = Ecto.UUID.generate()
      record!(scope, [ev(fitness, v2, "view_start"), ev(fitness, v2, "complete", 2.0)])
      apply!(viewer, DateTime.add(t0, 14, :day))

      # 1.0 decayed one half-life, plus the new 1.0 — not 2.0.
      assert_in_delta scores(viewer)["fitness-and-exercise"], 1.5, 1.0e-9
    end
  end

  describe "learning from views" do
    test "a completed view credits the topic, half its parent, and the creator",
         %{viewer: viewer, scope: scope, fitness: fitness, creator: creator} do
      v = Ecto.UUID.generate()
      record!(scope, [ev(fitness, v, "view_start"), ev(fitness, v, "complete", 2.0)])
      assert_enqueued(worker: AffinityWorker, args: %{user_id: viewer.id})

      assert :ok = perform_job(AffinityWorker, %{user_id: viewer.id})

      assert scores(viewer) == %{"fitness-and-exercise" => 1.0, "healthy-living" => 0.5}

      assert %{score: 1.0, evidence_count: 1} =
               Interests.creator_affinities(viewer.id, view(v).applied_at)[creator.id]

      assert %ViewEngagement{dirty: false, applied_delta: 1.0, learnable: true} = view(v)
    end

    test "one view contributes one delta, however many batches it spans",
         %{viewer: viewer, scope: scope, fitness: fitness} do
      now = DateTime.utc_now()
      v = Ecto.UUID.generate()

      record!(scope, [ev(fitness, v, "view_start"), ev(fitness, v, "watch_progress", 0.5)])
      apply!(viewer, now)
      assert_in_delta scores(viewer)["fitness-and-exercise"], 0.8 * 0.25, 1.0e-12

      record!(scope, [ev(fitness, v, "watch_progress", 1.0)])
      apply!(viewer, now)
      record!(scope, [ev(fitness, v, "watch_progress", 1.5)])
      apply!(viewer, now)
      record!(scope, [ev(fitness, v, "complete", 2.0)])
      apply!(viewer, now)

      # Exactly one completed view, not the sum of four partial deltas.
      assert_in_delta scores(viewer)["fitness-and-exercise"], 1.0, 1.0e-12
      assert view(v).applied_delta == 1.0

      fitness_topic = Content.topics_by_slug()["fitness-and-exercise"].id
      assert %{evidence_count: 1} = Interests.topic_affinities(viewer.id, now)[fitness_topic]
    end

    test "replaying a batch or re-running the worker changes nothing",
         %{viewer: viewer, scope: scope, fitness: fitness} do
      now = DateTime.utc_now()
      v = Ecto.UUID.generate()
      batch = [ev(fitness, v, "view_start"), ev(fitness, v, "watch_progress", 1.0)]

      record!(scope, batch)
      apply!(viewer, now)
      before = scores(viewer)

      # A client retry re-sends the same batch; the worker runs again.
      record!(scope, batch)
      apply!(viewer, now)
      apply!(viewer, now)

      assert scores(viewer) == before
      assert %{dirty: false} = view(v)
    end

    property "any interleaving of batches, retries and worker runs converges to Σ final targets" do
      check all(
              ops <-
                list_of(
                  one_of([
                    tuple(
                      {constant(:record), integer(0..2),
                       member_of(~w(watch_progress complete skip)), float(min: 0.0, max: 5.0)}
                    ),
                    constant(:apply)
                  ]),
                  max_length: 25
                ),
              max_runs: 25
            ) do
        creator = onboarded_user_fixture()
        viewer = onboarded_user_fixture()
        scope = Accounts.scope_for_user(viewer)
        item = ready_video_fixture(creator, topics: ["cooking"])
        view_ids = for _ <- 0..2, do: Ecto.UUID.generate()
        now = DateTime.utc_now()

        for op <- ops do
          case op do
            {:record, i, type, value} ->
              id = Enum.at(view_ids, i)
              record!(scope, [ev(item, id, "view_start"), ev(item, id, type, value)])

            :apply ->
              apply!(viewer, now)
          end
        end

        apply!(viewer, now)

        expected =
          0..2
          |> Enum.map(fn i -> for {:record, ^i, type, value} <- ops, do: {type, value} end)
          |> Enum.reject(&(&1 == []))
          |> Enum.map(&model_target/1)
          |> Enum.sum()

        actual = Map.get(scores(viewer), "cooking", 0.0)
        assert_in_delta actual, expected, 1.0e-9

        assert Repo.aggregate(
                 from(v in ViewEngagement, where: v.dirty and v.user_id == ^viewer.id),
                 :count
               ) == 0
      end
    end
  end

  # An independent model of a view's final target from all its events.
  defp model_target(events) do
    watched = events |> Enum.map(fn {_t, v} -> round(v * 1000) end) |> Enum.max()
    completed = Enum.any?(events, fn {t, _} -> t == "complete" end)
    early = Enum.any?(events, fn {t, v} -> t == "skip" and round(v * 1000) < 2_000 end)

    Interests.target_delta(
      %{duration_ms: 2_000, watched_ms: watched, completed: completed, early_skip: early},
      @w
    )
  end

  describe "frozen view state" do
    test "the first accepted event starts the view when view_start was rejected",
         %{viewer: viewer, scope: scope, fitness: fitness} do
      v = Ecto.UUID.generate()

      bad_start = %{
        ev(fitness, v, "view_start")
        | occurred_at: DateTime.add(DateTime.utc_now(), 30, :day)
      }

      assert {:ok, %{accepted: 1, rejected: 1}} =
               Events.record(scope, [bad_start, ev(fitness, v, "watch_progress", 1.0)])

      assert %{content_id: content_id, watched_ms: 1_000, topic_snapshot: snap} = view(v)
      assert content_id == fitness.id
      assert map_size(snap) == 2
      _ = viewer
    end

    test "a creator relabeling mid-view doesn't split the view across topics",
         %{viewer: viewer, scope: scope, fitness: fitness, creator: creator} do
      now = DateTime.utc_now()
      v = Ecto.UUID.generate()

      record!(scope, [ev(fitness, v, "view_start"), ev(fitness, v, "watch_progress", 1.0)])
      apply!(viewer, now)

      {:ok, _} =
        Content.update_item(Accounts.scope_for_user(creator), fitness.id, %{topics: ["cooking"]})

      record!(scope, [ev(fitness, v, "complete", 2.0)])
      apply!(viewer, now)

      assert %{"fitness-and-exercise" => fit, "healthy-living" => parent} = s = scores(viewer)
      assert_in_delta fit, 1.0, 1.0e-12
      assert_in_delta parent, 0.5, 1.0e-12
      refute Map.has_key?(s, "cooking")
      refute Map.has_key?(s, "food-and-drink")

      # A new view of the relabeled video learns the new label.
      v2 = Ecto.UUID.generate()
      record!(scope, [ev(fitness, v2, "view_start"), ev(fitness, v2, "complete", 2.0)])
      apply!(viewer, now)
      assert_in_delta scores(viewer)["cooking"], 1.0, 1.0e-12
    end

    test "a view_id reused for other content or by another user is ignored",
         %{viewer: viewer, scope: scope, fitness: fitness, creator: creator} do
      now = DateTime.utc_now()
      other = text_post_fixture(creator, topics: ["travel"])
      v = Ecto.UUID.generate()

      record!(scope, [ev(fitness, v, "view_start"), ev(other, v, "watch_progress", 99.0)])
      assert %{content_id: id, watched_ms: 0} = view(v)
      assert id == fitness.id

      intruder = Accounts.scope_for_user(onboarded_user_fixture())
      record!(intruder, [ev(fitness, v, "complete", 2.0)])
      assert %{completed: false, user_id: owner} = view(v)
      assert owner == viewer.id

      apply!(viewer, now)
      assert scores(viewer) == %{}
    end
  end

  describe "non-personalized mode" do
    test "views aren't learned, but events are still recorded",
         %{viewer: viewer, scope: scope, fitness: fitness} do
      {:ok, _} = Transparency.set_non_personalized(scope, true)
      v = Ecto.UUID.generate()

      record!(scope, [ev(fitness, v, "view_start"), ev(fitness, v, "complete", 2.0)])
      apply!(viewer, DateTime.utc_now())

      assert scores(viewer) == %{}
      assert Interests.creator_affinities(viewer.id) == %{}
      assert %{learnable: false, dirty: false, applied_delta: 1.0} = view(v)

      assert Repo.aggregate(
               from(e in TSpec.Events.Event, where: e.user_id == ^viewer.id and e.view_id == ^v),
               :count
             ) == 2
    end

    test "a worker delayed past turning personalization back on still doesn't learn",
         %{viewer: viewer, scope: scope, fitness: fitness} do
      {:ok, _} = Transparency.set_non_personalized(scope, true)
      v = Ecto.UUID.generate()
      record!(scope, [ev(fitness, v, "view_start"), ev(fitness, v, "complete", 2.0)])

      # Personalization comes back on before the worker gets to the view.
      {:ok, _} = Transparency.set_non_personalized(scope, false)
      assert :ok = perform_job(AffinityWorker, %{user_id: viewer.id})

      assert scores(viewer) == %{}
      assert view(v).learnable == false
    end

    test "turning it on mid-view keeps what was applied and learns nothing more",
         %{viewer: viewer, scope: scope, fitness: fitness} do
      now = DateTime.utc_now()
      v = Ecto.UUID.generate()

      record!(scope, [ev(fitness, v, "view_start"), ev(fitness, v, "watch_progress", 1.0)])
      apply!(viewer, now)
      assert_in_delta scores(viewer)["fitness-and-exercise"], 0.4, 1.0e-12

      {:ok, _} = Transparency.set_non_personalized(scope, true)
      record!(scope, [ev(fitness, v, "complete", 2.0)])
      apply!(viewer, now)

      assert_in_delta scores(viewer)["fitness-and-exercise"], 0.4, 1.0e-12
      assert %{learnable: false} = view(v)

      # And turning it off again doesn't resurrect the view.
      {:ok, _} = Transparency.set_non_personalized(scope, false)
      record!(scope, [ev(fitness, v, "complete", 4.0)])
      apply!(viewer, now)
      assert_in_delta scores(viewer)["fitness-and-exercise"], 0.4, 1.0e-12
    end

    test "after turning it back off, new views are learned again",
         %{viewer: viewer, scope: scope, fitness: fitness} do
      {:ok, _} = Transparency.set_non_personalized(scope, true)
      {:ok, _} = Transparency.set_non_personalized(scope, false)

      v = Ecto.UUID.generate()
      record!(scope, [ev(fitness, v, "view_start"), ev(fitness, v, "complete", 2.0)])
      apply!(viewer, DateTime.utc_now())
      assert_in_delta scores(viewer)["fitness-and-exercise"], 1.0, 1.0e-12
    end
  end

  describe "the atomic upsert" do
    test "is order-independent: an older write landing second is decayed, not the stored score",
         %{viewer: viewer} do
      topic = Content.topics_by_slug()["cooking"].id
      t0 = ~U[2026-10-01 00:00:00.000000Z]
      t14 = DateTime.add(t0, 14, :day)
      sql = Interests.upsert_sql(:topic, @w)

      params = fn delta, at ->
        [Ecto.UUID.dump!(viewer.id), [Ecto.UUID.dump!(topic)], [delta], [1], at]
      end

      # The later-stamped write commits first, then the earlier one.
      Repo.query!(sql, params.(1.0, t14))
      Repo.query!(sql, params.(1.0, t0))

      %{score: score, as_of: as_of, evidence_count: 2} =
        Repo.get_by!(TSpec.Feed.TopicAffinity, user_id: viewer.id, topic_id: topic)

      # Same as applying t0 then t14: 1.0 * 0.5 + 1.0.
      assert_in_delta score, 1.5, 1.0e-9
      assert as_of == t14
    end
  end
end
