defmodule TSpec.Transparency do
  @moduledoc """
  User-facing algorithm controls and explanations (ADR 0006/0011/0012).

  ## Settings

  Stored sparsely in `user_algorithm_settings` (only what differs from the
  default) and read as a `TSpec.Feed.Settings`. Every change, in one
  transaction under `FOR NO KEY UPDATE` on the user row:

    * applies the changes and bumps `users.settings_version`
    * turning non-personalized mode **on** ratchets the user's open views to
      `learnable = false` (ADR 0012)

  and, after commit, broadcasts the new settings on `feed_settings:<user_id>`
  so every live feed session of that user re-ranks (ADR 0011). Sessions
  ignore broadcasts older than the version they already have.
  """
  import Ecto.Query, warn: false

  alias TSpec.{Content, Events, Repo}
  alias TSpec.Accounts.{Scope, User}
  alias TSpec.Feed.{Interests, Settings, TopicAffinity, ViewEngagement}
  alias TSpec.Transparency.{SettingsSnapshot, UserSetting}

  # Events up to 7 days old are accepted (Events.record/2), so a view can
  # still change for about that long. Views older than this can't.
  @open_view_window_days 8

  ## Reading

  @doc "The user's current settings."
  def get_settings(%Scope{user: %User{id: id}}), do: get_settings(id)

  def get_settings(user_id) when is_binary(user_id) do
    %{settings_version: version, non_personalized: np} =
      Repo.one!(
        from u in User,
          where: u.id == ^user_id,
          select: map(u, [:settings_version, :non_personalized])
      )

    rows = Repo.all(from s in UserSetting, where: s.user_id == ^user_id)
    from_rows(version, np, rows)
  end

  defp from_rows(version, np, rows) do
    Enum.reduce(rows, %Settings{version: version, non_personalized: np}, fn
      %{key: "topic:" <> slug} = row, acc ->
        put_in(acc.topics[slug], %{multiplier: row.multiplier, hard_off: row.hard_off})

      %{key: "source:" <> source} = row, acc ->
        put_in(acc.sources[source], row.multiplier)
    end)
  end

  ## Changing

  @doc """
  Applies a change set and returns `{:ok, %Settings{}}` with the new version.

  `changes` may contain:

    * `:topics` — `%{slug => %{optional(:multiplier) => 0..2, optional(:hard_off) => bool}}`
    * `:sources` — `%{source => multiplier}`
    * `:non_personalized` — boolean

  Invalid slugs, sources or multipliers return
  `{:error, :invalid_settings, message}` and change nothing.
  """
  def update_settings(%Scope{user: %User{id: user_id}}, changes) when is_map(changes) do
    with :ok <- validate(changes) do
      Repo.transact(fn ->
        user = lock_user(user_id)

        for {slug, change} <- Map.get(changes, :topics, %{}),
            do: put_setting(user_id, "topic:" <> slug, change)

        for {source, m} <- Map.get(changes, :sources, %{}),
            do: put_setting(user_id, "source:" <> source, %{multiplier: m})

        np = Map.get(changes, :non_personalized, user.non_personalized)
        if np and not user.non_personalized, do: ratchet_open_views(user_id)

        user
        |> Ecto.Changeset.change(
          non_personalized: np,
          settings_version: user.settings_version + 1
        )
        |> Repo.update!()

        {:ok, get_settings(user_id)}
      end)
      |> broadcast(user_id)
    end
  end

  @doc """
  Resets topic sliders, hard-offs and source weights to the defaults. The
  non-personalized mode is a separate choice and is left as it is.
  """
  def reset_settings(%Scope{user: %User{id: user_id}}) do
    Repo.transact(fn ->
      user = lock_user(user_id)
      Repo.delete_all(from s in UserSetting, where: s.user_id == ^user_id)

      user
      |> Ecto.Changeset.change(settings_version: user.settings_version + 1)
      |> Repo.update!()

      {:ok, get_settings(user_id)}
    end)
    |> broadcast(user_id)
  end

  @doc """
  Turns non-personalized mode on or off (an `update_settings/2` shorthand).

  Turning it **on** clears `learnable` on the user's views that could still
  receive events, in the same transaction, so nothing watched from here on
  is learned — even by a worker that runs after the mode is turned back off
  (ADR 0012). `learnable` never goes back to true.

  Takes `FOR NO KEY UPDATE` on the user row, which `Events.record/2` reads under
  `FOR SHARE`: a recording transaction either finishes first (and its views
  are then ratcheted here) or starts after and sees the new mode.
  """
  def set_non_personalized(%Scope{} = scope, enabled?) when is_boolean(enabled?) do
    with {:ok, _settings} <- update_settings(scope, %{non_personalized: enabled?}) do
      {:ok, Repo.get!(User, scope.user.id)}
    end
  end

  @doc "Subscribes the caller to `{:settings_changed, %Settings{}}` for a user."
  def subscribe_settings(user_id),
    do: Phoenix.PubSub.subscribe(TSpec.PubSub, settings_topic(user_id))

  defp broadcast({:ok, settings} = result, user_id) do
    Phoenix.PubSub.broadcast(TSpec.PubSub, settings_topic(user_id), {:settings_changed, settings})
    result
  end

  defp broadcast(error, _user_id), do: error

  defp settings_topic(user_id), do: "feed_settings:#{user_id}"

  # FOR NO KEY UPDATE, not FOR UPDATE: it still conflicts with FOR SHARE
  # (Events.record/2) and with itself, but not with the FOR KEY SHARE that
  # foreign-key checks take. With FOR UPDATE, the affinity worker inserting
  # a new affinity row (an FK check on this user) while holding a claimed
  # view, and this transaction's ratchet waiting for that view, deadlocked.
  defp lock_user(user_id),
    do: from(u in User, where: u.id == ^user_id, lock: "FOR NO KEY UPDATE") |> Repo.one!()

  defp ratchet_open_views(user_id) do
    since = DateTime.add(DateTime.utc_now(), -@open_view_window_days, :day)

    from(v in ViewEngagement,
      where: v.user_id == ^user_id and v.learnable and v.inserted_at > ^since
    )
    |> Repo.update_all(set: [learnable: false])
  end

  # Upserts one setting, deleting the row once it's back to the default.
  defp put_setting(user_id, key, change) do
    current =
      Repo.get_by(UserSetting, user_id: user_id, key: key) ||
        %UserSetting{user_id: user_id, key: key}

    multiplier = Map.get(change, :multiplier, current.multiplier) / 1
    hard_off = Map.get(change, :hard_off, current.hard_off)

    if multiplier == 1.0 and not hard_off do
      Repo.delete_all(from s in UserSetting, where: s.user_id == ^user_id and s.key == ^key)
    else
      Repo.insert!(
        %UserSetting{user_id: user_id, key: key, multiplier: multiplier, hard_off: hard_off},
        on_conflict: [set: [multiplier: multiplier, hard_off: hard_off]],
        conflict_target: [:user_id, :key]
      )
    end
  end

  defp validate(changes) do
    slugs = Content.topics_by_slug()

    errors =
      for(
        {slug, change} <- Map.get(changes, :topics, %{}),
        msg <- topic_errors(slug, change, slugs),
        do: msg
      ) ++
        for(
          {source, m} <- Map.get(changes, :sources, %{}),
          msg <- source_errors(source, m),
          do: msg
        ) ++
        if(is_boolean(Map.get(changes, :non_personalized, false)),
          do: [],
          else: ["non_personalized must be true or false"]
        )

    if errors == [], do: :ok, else: {:error, :invalid_settings, Enum.join(errors, "; ")}
  end

  defp topic_errors(slug, change, slugs) do
    cond do
      not Map.has_key?(slugs, slug) ->
        ["unknown topic: #{slug}"]

      not is_map(change) ->
        ["topic #{slug}: expected multiplier and/or hard_off"]

      not valid_multiplier?(Map.get(change, :multiplier, 1.0)) ->
        ["topic #{slug}: multiplier must be 0..2"]

      not is_boolean(Map.get(change, :hard_off, false)) ->
        ["topic #{slug}: hard_off must be true or false"]

      true ->
        []
    end
  end

  defp source_errors(source, m) do
    cond do
      source not in Settings.sources() -> ["unknown source: #{source}"]
      not valid_multiplier?(m) -> ["source #{source}: multiplier must be 0..2"]
      true -> []
    end
  end

  defp valid_multiplier?(m), do: is_number(m) and m >= 0 and m <= 2

  ## Snapshots

  @doc """
  The id of a snapshot of `settings` for `user_id`, creating it if this
  exact combination (settings + version) hasn't been stored before.
  """
  def snapshot_settings(user_id, %Settings{} = settings) do
    hash = :crypto.hash(:sha256, [Settings.hash(settings), <<settings.version::64>>])

    Repo.insert_all(
      SettingsSnapshot,
      [
        %{
          id: UUIDv7.generate(),
          user_id: user_id,
          settings_version: settings.version,
          settings: Settings.to_snapshot(settings),
          hash: hash,
          inserted_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:user_id, :hash]
    )

    Repo.one!(
      from s in SettingsSnapshot, where: s.user_id == ^user_id and s.hash == ^hash, select: s.id
    )
  end

  @doc "A stored settings snapshot by id."
  def get_snapshot!(id), do: Repo.get!(SettingsSnapshot, id)

  ## Explanations

  @doc """
  "Why am I seeing this?": the stored impression — trace, sources, ranker
  version and the settings snapshot it was ranked under. Read back exactly
  as served; nothing is recomputed (ADR 0006).
  """
  def explain(%Scope{} = scope, impression_id) do
    with {:ok, impression} <- Events.get_impression(scope, impression_id) do
      {:ok, %{impression: impression, settings: get_snapshot!(impression.settings_snapshot_id)}}
    end
  end

  ## Interests

  @doc """
  The user's learned interests, decayed to now, strongest first:
  `%{topics: [...], creators: [...]}`. Each has the raw `score`, the ranking
  feature `value` in (-1, 1) and how many views it was learned from.
  """
  def interests(%Scope{user: %User{id: user_id}}, now \\ DateTime.utc_now()) do
    topics_by_id = Content.topics_by_id()
    w = Interests.Weights.get()

    topics =
      for {id, a} <- Interests.topic_affinities(user_id, now), t = topics_by_id[id] do
        %{
          topic: t,
          score: a.score,
          value: Interests.feature_value(a.score, w),
          evidence_count: a.evidence_count
        }
      end

    creators =
      for {id, a} <- Interests.creator_affinities(user_id, now) do
        %{
          creator_id: id,
          score: a.score,
          value: Interests.feature_value(a.score, w),
          evidence_count: a.evidence_count
        }
      end

    handles =
      Repo.all(
        from u in User,
          where: u.id in ^Enum.map(creators, & &1.creator_id),
          select: {u.id, u.handle}
      )
      |> Map.new()

    %{
      topics: Enum.sort_by(topics, &{-abs(&1.score), &1.topic.slug}),
      creators:
        creators
        |> Enum.map(&Map.put(&1, :handle, handles[&1.creator_id]))
        |> Enum.sort_by(&{-abs(&1.score), &1.creator_id})
    }
  end

  @doc """
  The views a topic interest was learned from, newest first: the item, how
  it was watched, and how much it moved this topic (`delta`).
  """
  def interest_evidence(%Scope{user: %User{id: user_id}}, slug, limit \\ 20) do
    with %{id: topic_id} <- Content.topics_by_slug()[slug] do
      # Only views since the interest was last forgotten.
      since =
        Repo.one(
          from a in TopicAffinity,
            where: a.user_id == ^user_id and a.topic_id == ^topic_id,
            select: a.reset_at
        ) || ~U[1970-01-01 00:00:00Z]

      views =
        from(v in ViewEngagement,
          where: v.user_id == ^user_id and v.learnable and not is_nil(v.applied_at),
          where: v.inserted_at > ^since,
          where: fragment("? \\? ?", v.topic_snapshot, ^topic_id),
          order_by: [desc: v.inserted_at],
          limit: ^limit
        )
        |> Repo.all()

      items =
        from(i in Content.Item, where: i.id in ^Enum.map(views, & &1.content_id))
        |> Repo.all()
        |> Content.preload_for_render()
        |> Map.new(&{&1.id, &1})

      {:ok,
       for v <- views do
         %{
           item: items[v.content_id],
           viewed_at: v.inserted_at,
           watched_ms: v.watched_ms,
           duration_ms: v.duration_ms,
           completed: v.completed,
           delta: v.applied_delta * v.topic_snapshot[topic_id]
         }
       end}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Forgets a learned topic interest: zeroes it and sets a reset boundary, so
  views from before now — even ones still waiting to be applied — can't
  bring it back. New views of the topic are learned again (turn the topic
  down or off to stop that). See `TSpec.Feed.Interests.forget/4`.
  """
  def forget_interest(%Scope{user: %User{id: user_id}}, slug) do
    with %{id: topic_id} <- Content.topics_by_slug()[slug] do
      Interests.forget(user_id, :topic, topic_id)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Forgets a learned creator interest (following is separate)."
  def forget_creator_interest(%Scope{user: %User{id: user_id}}, creator_id) do
    with {:ok, creator_id} <- Ecto.UUID.cast(creator_id) do
      Interests.forget(user_id, :creator, creator_id)
    else
      :error -> {:error, :not_found}
    end
  end

  ## Dashboard

  @doc """
  Algorithm Dashboard aggregates over the last `days` days, from impressions
  the user was actually *shown* (a `view_start` carried the impression id):

    * `topic_mix` — per day, how many shown items had each tier-1 topic
    * `top_drivers` — the features (per topic, for topic features) that
      contributed most to what was shown, summed from the stored traces
  """
  # `exposed` is a constant subquery; the user and date are bound parameters.
  # sobelow_skip ["SQL.Query"]
  def dashboard(%Scope{user: %User{id: user_id}}, days) when days in [7, 30] do
    since = DateTime.add(DateTime.utc_now(), -days, :day)
    uid = Ecto.UUID.dump!(user_id)

    exposed = """
    SELECT DISTINCT ON (i.id) i.id, i.served_at, i.content_id, i.contributions, e.received_at AS shown_at
    FROM engagement_events e
    JOIN impressions i
      ON i.id = e.impression_id AND i.user_id = e.user_id
     AND i.served_at >= $2::timestamptz - interval '1 day'
    WHERE e.user_id = $1 AND e.type = 'view_start' AND e.impression_id IS NOT NULL
      AND e.received_at >= $2
    """

    %{rows: mix} =
      Repo.query!(
        """
        WITH shown AS (#{exposed})
        SELECT (s.shown_at AT TIME ZONE 'UTC')::date AS day,
               COALESCE(p.slug, t.slug) AS topic,
               count(DISTINCT s.id)::int
        FROM shown s
        JOIN content_topics ct ON ct.content_id = s.content_id AND ct.confidence >= 0.5
        JOIN topics t ON t.id = ct.topic_id
        LEFT JOIN topics p ON p.id = t.parent_id
        GROUP BY 1, 2
        ORDER BY 1, 3 DESC, 2
        """,
        [uid, since]
      )

    %{rows: drivers} =
      Repo.query!(
        """
        WITH shown AS (#{exposed})
        SELECT c->>'feature' AS feature,
               COALESCE(c->>'topic', c->>'source') AS detail,
               sum((c->>'contribution')::float8) AS total,
               count(*)::int AS items
        FROM shown s, jsonb_array_elements(s.contributions) c
        GROUP BY 1, 2
        ORDER BY abs(sum((c->>'contribution')::float8)) DESC, 1, 2
        LIMIT 12
        """,
        [uid, since]
      )

    %{
      days: days,
      shown: shown_count(uid, since, exposed),
      topic_mix:
        mix
        |> Enum.group_by(fn [day, _, _] -> day end, fn [_, topic, n] ->
          %{topic: topic, count: n}
        end)
        |> Enum.sort_by(fn {day, _} -> day end, Date)
        |> Enum.map(fn {day, topics} -> %{date: day, topics: topics} end),
      top_drivers:
        for [feature, detail, total, items] <- drivers do
          %{feature: feature, detail: detail, total: total, items: items}
        end
    }
  end

  # sobelow_skip ["SQL.Query"]
  defp shown_count(uid, since, exposed) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*)::int FROM (#{exposed}) s", [uid, since])
    n
  end
end
