defmodule TSpec.Social.Follow do
  use TSpec.Schema

  @primary_key false
  schema "follows" do
    belongs_to :follower, TSpec.Accounts.User, primary_key: true
    belongs_to :followee, TSpec.Accounts.User, primary_key: true

    timestamps(updated_at: false)
  end
end
