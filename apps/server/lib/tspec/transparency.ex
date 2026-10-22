defmodule TSpec.Transparency do
  @moduledoc """
  User-facing algorithm controls and explanations (ADR 0006/0011/0012).

  ## Settings

  Stored sparsely in `user_algorithm_settings` (only what differs from the
  default) and read as a `TSpec.Feed.Settings`. Every change, in one
  transaction under `FOR UPDATE` on the user row:

    * applies the changes and bumps `users.settings_version`
    * turning non-personalized mode **on** ratchets the user's open views to
      `learnable = false` (ADR 0012)

  and, after commit, broadcasts the new settings on `feed_settings:<user_id>`
  so every live feed session of that user re-ranks (ADR 0011). Sessions
  ignore broadcasts older than the version they already have.
  """
  import Ecto.Query, warn: false

  alias TSpec.{Content, Repo}
  alias TSpec.Accounts.{Scope, User}
  alias TSpec.Feed.{Settings, ViewEngagement}
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

  Takes `FOR UPDATE` on the user row, which `Events.record/2` reads under
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

  defp lock_user(user_id),
    do: from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE") |> Repo.one!()

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
end
