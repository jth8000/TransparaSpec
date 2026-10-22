defmodule TSpec.Feed.ViewEngagement do
  @moduledoc """
  Aggregate state of one view (playback episode). Derived from engagement
  events and mutable, unlike the event log itself. See ADR 0012:

    * `topic_snapshot` / `creator_id` / `duration_ms` are frozen when the
      server accepts the view's first event
    * `learnable` is set then too, and only ever goes true -> false
    * `watched_ms` / `completed` / `early_skip` only ever grow (merges are
      monotonic, so replays and out-of-order batches converge)
    * the affinity worker applies `target_delta - applied_delta`
  """
  use Ecto.Schema

  @primary_key {:view_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "view_engagements" do
    field :user_id, :binary_id
    field :content_id, :binary_id
    field :creator_id, :binary_id
    field :duration_ms, :integer
    field :watched_ms, :integer, default: 0
    field :completed, :boolean, default: false
    field :early_skip, :boolean, default: false
    field :learnable, :boolean
    field :topic_snapshot, :map
    field :target_delta, :float, default: 0.0
    field :applied_delta, :float, default: 0.0
    field :applied_at, :utc_datetime_usec
    field :dirty, :boolean, default: true

    timestamps()
  end
end
