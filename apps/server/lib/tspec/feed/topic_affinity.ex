defmodule TSpec.Feed.TopicAffinity do
  @moduledoc """
  A user's learned interest in a topic. `score` is stored as of `as_of` and
  decayed lazily (see `TSpec.Feed.Interests.decay/3`). Written only through
  the atomic upsert in `TSpec.Feed.Interests`.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "user_topic_affinity" do
    belongs_to :user, TSpec.Accounts.User, primary_key: true
    belongs_to :topic, TSpec.Content.Topic, primary_key: true
    field :score, :float
    field :evidence_count, :integer
    field :as_of, :utc_datetime_usec
    # Set by "forget": views that started before it never credit this again.
    field :reset_at, :utc_datetime_usec
  end
end
