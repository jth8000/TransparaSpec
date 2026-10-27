defmodule TSpec.Transparency.UserSetting do
  @moduledoc """
  One non-default algorithm control: `key` is `"topic:<slug>"` or
  `"source:<name>"`. Read through `TSpec.Transparency.get_settings/1`.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "user_algorithm_settings" do
    belongs_to :user, TSpec.Accounts.User, primary_key: true
    field :key, :string, primary_key: true
    field :multiplier, :float, default: 1.0
    field :hard_off, :boolean, default: false
  end
end
