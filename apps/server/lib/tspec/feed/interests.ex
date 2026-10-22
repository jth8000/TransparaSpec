defmodule TSpec.Feed.Interests do
  @moduledoc """
  The interest model (ADR 0012): per-user topic and creator affinities,
  learned from views.

  ## How learning works

  A *view* is one playback episode, identified by a client-minted `view_id`.
  Every view contributes exactly one `target_delta` (see `target_delta/2`),
  however many events or batches it spans:

    1. `track_views/4` runs inside `Events.record/2`'s transaction. It creates
       the `view_engagements` row on the view's first accepted event — freezing
       its topic snapshot, creator and `learnable` flag — and merges the
       batch into it monotonically, recomputing `target_delta` and marking it
       dirty. Events and view state commit together, or not at all.
    2. `apply_dirty_views/2` (from `TSpec.Feed.AffinityWorker`) applies
       `target_delta - applied_delta` to the affinities and records the new
       `applied_delta`, in one transaction. Re-running it applies nothing;
       a view that grows adds only the difference; a late commit is just a
       dirty row that shows up later. No cursor, so no commit-order or
       timing assumptions.

  ## Decay

  Scores fade with a half-life (14 days by default): the effective score at
  time `t` is `score * 0.5^((t - as_of) / half_life)`. Updates decay the
  stored score forward before adding (see `upsert_sql/2`), so adding to an
  old score never makes the whole score fresh again. For ranking, scores
  are squashed into (-1, 1) with `feature_value/2`.
  """
  import Ecto.Query, warn: false

  alias TSpec.Repo
  alias TSpec.Content
  alias TSpec.Content.{ContentTopic, Item}
  alias TSpec.Feed.{AffinityWorker, CreatorAffinity, TopicAffinity, ViewEngagement}
  alias TSpec.Feed.Interests.Weights

  # Client-reported seconds are clamped to a day (also keeps watched_ms well
  # inside a Postgres integer).
  @max_value_seconds 86_400

  ## Pure functions

  @doc """
  The single affinity delta a view contributes, from its merged aggregate.

      iex> w = TSpec.Feed.Interests.Weights.defaults()
      iex> TSpec.Feed.Interests.target_delta(%{duration_ms: 10_000, watched_ms: 10_000, completed: true, early_skip: false}, w)
      1.0
      iex> TSpec.Feed.Interests.target_delta(%{duration_ms: 10_000, watched_ms: 1_000, completed: false, early_skip: true}, w)
      -0.5
      iex> TSpec.Feed.Interests.target_delta(%{duration_ms: 10_000, watched_ms: 5_000, completed: false, early_skip: false}, w)
      0.4
  """
  def target_delta(view, w \\ Weights.get())

  # Content without a duration (text posts): being shown is the signal.
  def target_delta(%{duration_ms: d}, w) when d in [nil, 0], do: w.text_view / 1

  def target_delta(%{duration_ms: d, watched_ms: watched, completed: true}, w) do
    if watched >= 2 * d, do: w.complete + w.loop_bonus, else: w.complete / 1
  end

  def target_delta(%{duration_ms: d, watched_ms: watched, early_skip: early?}, w) do
    if early? and watched < w.early_skip_ms,
      do: w.early_skip / 1,
      else: w.partial * min(watched / d, 1.0)
  end

  @doc "Decays a stored score from `as_of` to `now` (never grows it)."
  def decay(score, %DateTime{} = as_of, %DateTime{} = now, w \\ Weights.get()) do
    elapsed = max(DateTime.diff(now, as_of, :microsecond), 0) / 1_000_000
    score * :math.pow(0.5, elapsed / half_life_seconds(w))
  end

  @doc "A score as a ranking feature value in (-1, 1)."
  def feature_value(score, w \\ Weights.get()), do: :math.tanh(score / w.squash)

  @doc """
  The topic weights a view will credit: each label's confidence, and half of
  it (`parent_share`) to a tier-2 topic's tier-1 parent. A topic reached
  twice keeps the larger weight. Keys are topic id strings (stored as JSON).
  """
  def topic_snapshot(labels, topics_by_id, w \\ Weights.get()) do
    Enum.reduce(labels, %{}, fn {topic_id, confidence}, acc ->
      acc = Map.update(acc, topic_id, confidence, &max(&1, confidence))

      case topics_by_id[topic_id] do
        %{parent_id: nil} ->
          acc

        %{parent_id: parent} ->
          Map.update(
            acc,
            parent,
            confidence * w.parent_share,
            &max(&1, confidence * w.parent_share)
          )

        nil ->
          acc
      end
    end)
  end

  defp half_life_seconds(w), do: w.half_life_days * 86_400

  ## Recording views (inside Events.record/2's transaction)

  @doc """
  Creates or updates the `view_engagements` rows for the batch's events that
  carry a `view_id`. Must run in the same transaction as the event insert.

  `learnable?` is the caller's personalization mode, read under a row lock
  on the user (see `Events.record/2`); it only matters for views this batch
  creates. Returns how many of the batch's views now need applying.
  """
  def track_views(user_id, events, learnable?, %DateTime{} = now) do
    by_view = events |> Enum.filter(& &1[:view_id]) |> Enum.group_by(& &1.view_id)

    if by_view == %{} do
      0
    else
      view_ids = Map.keys(by_view)
      insert_new_views(user_id, by_view, learnable?, now)

      # Lock this user's rows for these views. Rows owned by someone else
      # (a reused view_id) are never touched.
      from(v in ViewEngagement,
        where: v.view_id in ^view_ids and v.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Enum.count(&merge_view(&1, by_view[&1.view_id], now))
    end
  end

  defp insert_new_views(user_id, by_view, learnable?, now) do
    existing =
      from(v in ViewEngagement, where: v.view_id in ^Map.keys(by_view), select: v.view_id)
      |> Repo.all()
      |> MapSet.new()

    # A view belongs to the content of its first event.
    new =
      for {id, [first | _]} <- by_view,
          not MapSet.member?(existing, id),
          do: {id, first.content_id}

    if new != [] do
      content_ids = new |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      info = content_info(content_ids)
      topics_by_id = Content.topics_by_id()
      w = Weights.get()

      rows =
        for {view_id, content_id} <- new, %{} = c <- [info[content_id]] do
          %{
            view_id: view_id,
            user_id: user_id,
            content_id: content_id,
            creator_id: c.author_id,
            duration_ms: c.duration_ms,
            learnable: learnable?,
            topic_snapshot: topic_snapshot(c.labels, topics_by_id, w),
            inserted_at: now,
            updated_at: now
          }
        end

      # A concurrent batch may create the same view first; its frozen
      # snapshot wins and ours is discarded.
      Repo.insert_all(ViewEngagement, rows, on_conflict: :nothing, conflict_target: :view_id)
    end
  end

  # %{content_id => %{author_id, duration_ms, labels: [{topic_id, confidence}]}}
  defp content_info(content_ids) do
    labels =
      from(ct in ContentTopic,
        where: ct.content_id in ^content_ids,
        group_by: [ct.content_id, ct.topic_id],
        select: {ct.content_id, {ct.topic_id, max(ct.confidence)}}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    from(i in Item,
      where: i.id in ^content_ids,
      left_join: v in assoc(i, :short_video),
      select: {i.id, %{author_id: i.author_id, duration_ms: v.duration_ms}}
    )
    |> Repo.all()
    |> Map.new(fn {id, c} -> {id, Map.put(c, :labels, Map.get(labels, id, []))} end)
  end

  # Folds the batch into the locked row. Returns whether it needs applying.
  defp merge_view(%ViewEngagement{} = view, events, now) do
    w = Weights.get()
    events = Enum.filter(events, &(&1.content_id == view.content_id))

    watched =
      for(%{type: t} = e <- events, t in ~w(watch_progress complete skip), do: ms(e[:value]))
      |> Enum.max(fn -> 0 end)
      |> max(view.watched_ms)

    completed = view.completed or Enum.any?(events, &(&1.type == "complete"))

    early_skip =
      view.early_skip or
        Enum.any?(events, &(&1.type == "skip" and ms(&1[:value]) < w.early_skip_ms))

    merged = %{view | watched_ms: watched, completed: completed, early_skip: early_skip}
    target = target_delta(merged, w)
    dirty = view.dirty or target != view.applied_delta

    from(v in ViewEngagement, where: v.view_id == ^view.view_id)
    |> Repo.update_all(
      set: [
        watched_ms: watched,
        completed: completed,
        early_skip: early_skip,
        target_delta: target,
        dirty: dirty,
        updated_at: now
      ]
    )

    dirty
  end

  defp ms(seconds) when is_number(seconds),
    do: round(min(max(seconds, 0), @max_value_seconds) * 1000)

  defp ms(_), do: 0

  @doc "Queues the affinity worker for a user (deduplicated while queued)."
  def enqueue_apply(user_id) do
    {:ok, _job} = user_id |> AffinityWorker.new_for_user() |> Oban.insert()
    :ok
  end

  ## Applying views (AffinityWorker)

  @doc """
  Applies a user's dirty views to their affinities, at most `limit` per call.

  One transaction: a per-user advisory lock serializes all of a user's
  affinity writes; dirty views are locked `FOR UPDATE SKIP LOCKED` (rows a
  recording transaction still holds are left for the next run, which that
  transaction has queued); each learnable view adds
  `target_delta - applied_delta` to its snapshot topics and creator via an
  atomic upsert; then `applied_delta` catches up and `dirty` clears.
  Views that aren't learnable are marked applied without touching any
  affinity — that's how non-personalized viewing stays unlearned.
  """
  def apply_dirty_views(user_id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    limit = Keyword.get(opts, :limit, 500)
    w = Weights.get()

    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "affinity:" <> user_id
      ])

      views =
        from(v in ViewEngagement,
          where: v.user_id == ^user_id and v.dirty,
          order_by: v.view_id,
          limit: ^limit,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.all()

      {topics, creators} = accumulate(views)
      upsert_affinities(:topic, user_id, topics, now, w)
      upsert_affinities(:creator, user_id, creators, now, w)

      for v <- views do
        moved? = v.learnable and v.target_delta != v.applied_delta

        from(x in ViewEngagement, where: x.view_id == ^v.view_id)
        |> Repo.update_all(
          set: [
            applied_delta: v.target_delta,
            dirty: false,
            applied_at: if(moved? and is_nil(v.applied_at), do: now, else: v.applied_at)
          ]
        )
      end

      {:ok, %{applied: length(views), more?: length(views) == limit}}
    end)
  end

  # Sums each learnable view's outstanding delta per topic and per creator.
  # Evidence counts a view the first time it moves an affinity.
  defp accumulate(views) do
    Enum.reduce(views, {%{}, %{}}, fn v, {topics, creators} ->
      delta = v.target_delta - v.applied_delta

      if v.learnable and delta != 0.0 do
        evidence = if is_nil(v.applied_at), do: 1, else: 0

        topics =
          Enum.reduce(v.topic_snapshot, topics, fn {topic_id, weight}, acc ->
            add(acc, topic_id, delta * weight, evidence)
          end)

        {topics, add(creators, v.creator_id, delta, evidence)}
      else
        {topics, creators}
      end
    end)
  end

  defp add(acc, key, delta, evidence) do
    Map.update(acc, key, {delta, evidence}, fn {d, e} -> {d + delta, e + evidence} end)
  end

  defp upsert_affinities(_kind, _user_id, deltas, _now, _w) when deltas == %{}, do: :ok

  defp upsert_affinities(kind, user_id, deltas, now, w) do
    # Sorted, so concurrent writers (if the advisory lock were ever bypassed)
    # lock rows in the same order.
    {keys, values} = deltas |> Enum.sort() |> Enum.unzip()
    {scores, evidence} = Enum.unzip(values)

    Repo.query!(upsert_sql(kind, w), [
      Ecto.UUID.dump!(user_id),
      Enum.map(keys, &Ecto.UUID.dump!/1),
      scores,
      evidence,
      now
    ])

    :ok
  end

  @doc """
  The atomic affinity upsert. Each row adds a delta stamped `as_of`; the
  older side is decayed to the newer timestamp before adding, so the result
  is the same whichever write commits first. Public for tests.
  """
  def upsert_sql(kind, w \\ Weights.get()) do
    {table, key} =
      case kind do
        :topic -> {"user_topic_affinity", "topic_id"}
        :creator -> {"user_creator_affinity", "creator_id"}
      end

    half_life = half_life_seconds(w)

    """
    INSERT INTO #{table} AS a (user_id, #{key}, score, evidence_count, as_of)
    SELECT $1, k, s, e, $5 FROM unnest($2::uuid[], $3::float8[], $4::int[]) AS x(k, s, e)
    ON CONFLICT (user_id, #{key}) DO UPDATE SET
      score = CASE
        WHEN EXCLUDED.as_of >= a.as_of THEN
          a.score * power(0.5, extract(epoch FROM EXCLUDED.as_of - a.as_of) / #{half_life})
            + EXCLUDED.score
        ELSE
          a.score
            + EXCLUDED.score * power(0.5, extract(epoch FROM a.as_of - EXCLUDED.as_of) / #{half_life})
      END,
      as_of = GREATEST(a.as_of, EXCLUDED.as_of),
      evidence_count = a.evidence_count + EXCLUDED.evidence_count
    """
  end

  ## Reading

  @doc "Decayed topic affinities: `%{topic_id => %{score, evidence_count}}`."
  def topic_affinities(user_id, now \\ DateTime.utc_now()) do
    w = Weights.get()

    from(a in TopicAffinity, where: a.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(
      &{&1.topic_id,
       %{score: decay(&1.score, &1.as_of, now, w), evidence_count: &1.evidence_count}}
    )
  end

  @doc "Decayed creator affinities: `%{creator_id => %{score, evidence_count}}`."
  def creator_affinities(user_id, now \\ DateTime.utc_now()) do
    w = Weights.get()

    from(a in CreatorAffinity, where: a.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(
      &{&1.creator_id,
       %{score: decay(&1.score, &1.as_of, now, w), evidence_count: &1.evidence_count}}
    )
  end

  @doc "User ids with views still waiting to be applied (for the sweep)."
  def users_with_dirty_views(limit \\ 1_000) do
    from(v in ViewEngagement, where: v.dirty, distinct: true, select: v.user_id, limit: ^limit)
    |> Repo.all()
  end
end
