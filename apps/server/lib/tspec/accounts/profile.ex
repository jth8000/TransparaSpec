defmodule TSpec.Accounts.Profile do
  use TSpec.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "profiles" do
    field :display_name, :string
    field :bio, :string
    field :avatar_url, :string

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:display_name, :bio])
    |> validate_length(:display_name, max: 50)
    |> validate_length(:bio, max: 300)
  end
end
