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
    field :view_id, :binary_id
    field :impression_id, :binary_id
    field :consent_version, :integer
    belongs_to :user, TSpec.Accounts.User
    belongs_to :content, TSpec.Content.Item
  end

  @doc """
  Event types accepted from clients in Phase 0:

    * `view_start` — the item became the visible, playing item
    * `watch_progress` — `value` = seconds played so far in this view,
      cumulative across loops
    * `complete` — reached the end (sent on every loop); `value` = seconds
      played so far in this view
    * `skip` — swiped away before finishing; `value` = seconds played

  Events of one playback episode share a client-minted `view_id`; the
  interest model learns per view (ADR 0012). `session_id` is the app-level
  session and is unrelated. A `view_start` may carry the `impression_id` it
  came from: that's what makes a served impression *exposed* (ADR 0011).

  `like` etc. arrive with the social features in Phase 2.
  """
  def types, do: @types
end
