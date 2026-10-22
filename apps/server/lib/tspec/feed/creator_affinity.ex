defmodule TSpec.Feed.CreatorAffinity do
  @moduledoc """
  A user's learned interest in a creator, inferred from views (distinct from
  following, which is an explicit choice). Same storage rules as
  `TSpec.Feed.TopicAffinity`.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "user_creator_affinity" do
    belongs_to :user, TSpec.Accounts.User, primary_key: true
    belongs_to :creator, TSpec.Accounts.User, primary_key: true
    field :score, :float
    field :evidence_count, :integer
    field :as_of, :utc_datetime_usec
  end
end
