defmodule TSpec.Events do
  @moduledoc """
  The append-only engagement log (ADR 0006/0007).

  `record/2` is the only way events get written. It stamps each event with the
  consent version from the caller's server-side scope — clients cannot set
  it — and refuses to record anything for a caller without consent.

  Events that carry a `view_id` also update that view's aggregate state for
  the interest model, in the same transaction (`TSpec.Feed.Interests`,
  ADR 0012).
  """
  import Ecto.Query, warn: false

  alias TSpec.Repo
  alias TSpec.Accounts.{Scope, User}
  alias TSpec.Content.Item
  alias TSpec.Events.{Event, Impression}
  alias TSpec.Feed.Interests

  @max_batch 100
  # Client timestamps are accepted within this window around server time.
  @max_age_seconds 7 * 24 * 60 * 60
  @max_skew_seconds 5 * 60

  def max_batch, do: @max_batch

  @doc """
  Records a batch of client events for the scope's user.

  Each event is a map with `:content_id`, `:type`, `:occurred_at` and optional
  `:value` / `:session_id` / `:view_id`. Events with an unknown type, a timestamp outside
  the accepted window, or a content id the caller can't see (same rule as
  `Content.get_item/2`: public and ready, or their own non-removed item) are
  dropped.

  Returns `{:ok, %{accepted: n, rejected: m}}`, or `{:error, :consent_required}`
  when the caller has no consent on record.
  """
  def record(%Scope{consent_version: version} = scope, events)
      when is_integer(version) and is_list(events) and length(events) <= @max_batch do
    now = DateTime.utc_now()
    {valid, invalid} = Enum.split_with(events, &well_formed?(&1, now))
    known_ids = viewable_content_ids(scope, valid)

    accepted =
      valid
      |> Enum.filter(&MapSet.member?(known_ids, &1.content_id))
      |> verify_impressions(scope)

    rows =
      for event <- accepted do
        %{
          id: UUIDv7.generate(),
          user_id: scope.user.id,
          content_id: event.content_id,
          type: event.type,
          value: to_float(Map.get(event, :value)),
          occurred_at: usec(event.occurred_at),
          received_at: now,
          session_id: Map.get(event, :session_id),
          view_id: Map.get(event, :view_id),
          impression_id: Map.get(event, :impression_id),
          consent_version: version
        }
      end

    Repo.transact(fn ->
      # FOR SHARE on the user row: switching personalization takes FOR NO
      # KEY UPDATE on it, so a view can't be created as learnable from a mode
      # read that the switch has already made stale (ADR 0012).
      personalized? = not lock_mode(scope.user.id)

      {inserted, _} = Repo.insert_all(Event, rows)

      if Interests.track_views(scope.user.id, accepted, personalized?, now) > 0 do
        # Queued in this transaction: a job exists iff the view state committed.
        Interests.enqueue_apply(scope.user.id)
      end

      {:ok, %{accepted: inserted, rejected: length(invalid) + length(valid) - inserted}}
    end)
  end

  def record(%Scope{}, events) when is_list(events) and length(events) > @max_batch,
    do: {:error, :batch_too_large}

  def record(_scope, _events), do: {:error, :consent_required}

  ## Impressions

  @doc """
  Records served impressions for the scope's user, stamped with the consent
  version from the server-side scope (pillar 2). Each entry needs
  `:content_id`, `:feed_session_id`, `:rev`, `:position`, `:ranker_version`,
  `:candidate_source`, `:sources`, `:final_score`, `:contributions`,
  `:settings_version` and `:settings_snapshot_id`.

  Returns `{:ok, ids}` in entry order. Each id is a UUIDv7 whose embedded
  timestamp is the row's `served_at` (the partition key), so
  `get_impression/2` can find a row from its id alone.
  """
  def record_impressions(%Scope{consent_version: version, user: user}, entries)
      when is_integer(version) and is_list(entries) do
    rows =
      for entry <- entries do
        id = UUIDv7.generate()

        entry
        |> Map.take(~w(content_id feed_session_id rev position ranker_version candidate_source
                       sources final_score contributions settings_version settings_snapshot_id)a)
        |> Map.merge(%{
          id: id,
          served_at: Impression.served_at_for(id),
          user_id: user.id,
          consent_version: version
        })
      end

    {_, _} = Repo.insert_all(Impression, rows)
    {:ok, Enum.map(rows, & &1.id)}
  end

  def record_impressions(_scope, _entries), do: {:error, :consent_required}

  @doc """
  The scope user's impression by id, or `{:error, :not_found}` (also for
  someone else's). Hits exactly one partition.
  """
  def get_impression(%Scope{user: user}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, served_at} <- served_at(id),
         %Impression{} = impression <-
           Repo.one(
             from i in Impression,
               where: i.id == ^id and i.served_at == ^served_at and i.user_id == ^user.id
           ) do
      {:ok, impression}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Deletes impressions served before `before` that were never shown (no
  `view_start` event names them). Returns `{:ok, count}`.
  """
  def prune_unexposed_impressions(%DateTime{} = before) do
    %{num_rows: n} =
      Repo.query!(
        """
        DELETE FROM impressions i
        WHERE i.served_at < $1
          AND NOT EXISTS (
            SELECT 1 FROM engagement_events e
            WHERE e.impression_id = i.id AND e.user_id = i.user_id AND e.type = 'view_start'
          )
        """,
        [before]
      )

    {:ok, n}
  end

  defp served_at(id) do
    case safe_served_at(id) do
      nil -> :error
      served_at -> {:ok, served_at}
    end
  end

  defp lock_mode(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.non_personalized, lock: "FOR SHARE")
    |> Repo.one!()
  end

  defp well_formed?(%{content_id: id, type: type, occurred_at: %DateTime{} = at} = event, now)
       when is_binary(id) and is_binary(type) do
    type in Event.types() and uuid?(id) and optional_uuid?(Map.get(event, :view_id)) and
      optional_uuid?(Map.get(event, :impression_id)) and
      DateTime.diff(now, at) <= @max_age_seconds and
      DateTime.diff(at, now) <= @max_skew_seconds
  end

  defp well_formed?(_event, _now), do: false

  defp uuid?(id), do: is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id))
  defp optional_uuid?(nil), do: true
  defp optional_uuid?(id), do: uuid?(id)

  # Events may only reference content the caller could have been shown.
  defp viewable_content_ids(_scope, []), do: MapSet.new()

  defp viewable_content_ids(%Scope{user: user}, events) do
    ids = events |> Enum.map(& &1.content_id) |> Enum.uniq()

    from(i in Item,
      where: i.id in ^ids,
      where:
        (i.status == "ready" and i.visibility == "public") or
          (i.author_id == ^user.id and i.status != "removed"),
      select: i.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # An event's impression_id must be the caller's impression of that same
  # content; otherwise it's dropped (the event itself is still valid).
  defp verify_impressions(events, %Scope{user: user}) do
    ids = for %{impression_id: id} <- events, is_binary(id), uniq: true, do: id

    owned =
      if ids == [] do
        %{}
      else
        served_ats = Enum.flat_map(ids, &List.wrap(safe_served_at(&1)))

        from(i in Impression,
          where: i.id in ^ids and i.served_at in ^served_ats and i.user_id == ^user.id,
          select: {i.id, i.content_id}
        )
        |> Repo.all()
        |> Map.new()
      end

    for event <- events do
      case Map.get(event, :impression_id) do
        nil ->
          event

        id ->
          if owned[id] == event.content_id, do: event, else: Map.put(event, :impression_id, nil)
      end
    end
  end

  defp safe_served_at(id) do
    Impression.served_at_for(id)
  rescue
    _ -> nil
  end

  # utc_datetime_usec columns need microsecond precision.
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp to_float(nil), do: nil
  defp to_float(n) when is_number(n), do: n / 1
end
