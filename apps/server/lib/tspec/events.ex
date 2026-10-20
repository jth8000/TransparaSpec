defmodule TSpec.Events do
  @moduledoc """
  The append-only engagement log (ADR 0006/0007).

  `record/2` is the only way events get written. It stamps each event with the
  consent version from the caller's server-side scope — clients cannot set
  it — and refuses to record anything for a caller without consent.
  """
  import Ecto.Query, warn: false

  alias TSpec.Repo
  alias TSpec.Accounts.Scope
  alias TSpec.Content.Item
  alias TSpec.Events.Event

  @max_batch 100
  # Client timestamps are accepted within this window around server time.
  @max_age_seconds 7 * 24 * 60 * 60
  @max_skew_seconds 5 * 60

  def max_batch, do: @max_batch

  @doc """
  Records a batch of client events for the scope's user.

  Each event is a map with `:content_id`, `:type`, `:occurred_at` and optional
  `:value` / `:session_id`. Events with an unknown type, a content id that
  doesn't exist (or was removed), or a timestamp outside the accepted window
  are dropped.

  Returns `{:ok, %{accepted: n, rejected: m}}`, or `{:error, :consent_required}`
  when the caller has no consent on record.
  """
  def record(%Scope{consent_version: version} = scope, events)
      when is_integer(version) and is_list(events) and length(events) <= @max_batch do
    now = DateTime.utc_now()
    {valid, invalid} = Enum.split_with(events, &well_formed?(&1, now))
    known_ids = viewable_content_ids(valid)

    rows =
      for event <- valid, MapSet.member?(known_ids, event.content_id) do
        %{
          id: UUIDv7.generate(),
          user_id: scope.user.id,
          content_id: event.content_id,
          type: event.type,
          value: to_float(Map.get(event, :value)),
          occurred_at: usec(event.occurred_at),
          received_at: now,
          session_id: Map.get(event, :session_id),
          consent_version: version
        }
      end

    {inserted, _} = Repo.insert_all(Event, rows)
    {:ok, %{accepted: inserted, rejected: length(invalid) + length(valid) - inserted}}
  end

  def record(%Scope{}, events) when is_list(events) and length(events) > @max_batch,
    do: {:error, :batch_too_large}

  def record(_scope, _events), do: {:error, :consent_required}

  defp well_formed?(%{content_id: id, type: type, occurred_at: %DateTime{} = at}, now)
       when is_binary(id) and is_binary(type) do
    type in Event.types() and match?({:ok, _}, Ecto.UUID.cast(id)) and
      DateTime.diff(now, at) <= @max_age_seconds and
      DateTime.diff(at, now) <= @max_skew_seconds
  end

  defp well_formed?(_event, _now), do: false

  # Events may only reference content that exists and isn't removed.
  defp viewable_content_ids([]), do: MapSet.new()

  defp viewable_content_ids(events) do
    ids = events |> Enum.map(& &1.content_id) |> Enum.uniq()

    from(i in Item, where: i.id in ^ids and i.status != "removed", select: i.id)
    |> Repo.all()
    |> MapSet.new()
  end

  # utc_datetime_usec columns need microsecond precision.
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp to_float(nil), do: nil
  defp to_float(n) when is_number(n), do: n / 1
end
