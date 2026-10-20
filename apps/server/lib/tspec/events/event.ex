defmodule TSpec.Events.Event do
  @moduledoc "One engagement event. Rows are only ever inserted (append-only)."
  use TSpec.Schema

  @types ~w(view_start watch_progress complete skip)

  schema "engagement_events" do
    field :type, :string
    field :value, :float
    field :occurred_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :session_id, :string
    field :consent_version, :integer
    belongs_to :user, TSpec.Accounts.User
    belongs_to :content, TSpec.Content.Item
  end

  @doc """
  Event types accepted from clients in Phase 0:

    * `view_start` — the item became the visible, playing item
    * `watch_progress` — `value` = seconds watched so far
    * `complete` — watched to the end (first loop)
    * `skip` — swiped away; `value` = seconds watched before skipping

  `like` etc. arrive with the social features in Phase 2.
  """
  def types, do: @types
end
