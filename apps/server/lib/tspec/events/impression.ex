defmodule TSpec.Events.Impression do
  @moduledoc """
  A *served* impression: an item sent to a client, with the exact trace that
  ranked it (ADR 0006/0011). Append-only. "Why am I seeing this?" reads this
  row and never recomputes.

  `served_at` is the timestamp embedded in the UUIDv7 `id` (the partition
  key; see `served_at_for/1`). Exposure — the item actually becoming
  visible — is a `view_start` event carrying this impression's id.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "impressions" do
    field :id, :binary_id, primary_key: true
    field :served_at, :utc_datetime_usec, primary_key: true
    field :feed_session_id, :binary_id
    field :rev, :integer
    field :position, :integer
    field :ranker_version, :string
    field :candidate_source, :string
    field :sources, {:array, :string}
    field :final_score, :float
    field :contributions, {:array, :map}
    field :settings_version, :integer
    field :settings_snapshot_id, :binary_id
    field :consent_version, :integer
    belongs_to :user, TSpec.Accounts.User
    belongs_to :content, TSpec.Content.Item
  end

  @doc "The partition timestamp encoded in an impression's UUIDv7 id."
  def served_at_for(id) do
    id |> UUIDv7.timestamp() |> DateTime.from_unix!(:millisecond) |> DateTime.add(0, :microsecond)
  end
end
