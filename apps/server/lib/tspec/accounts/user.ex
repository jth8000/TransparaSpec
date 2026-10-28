defmodule TSpec.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :handle, :string
    field :age_attested_at, :utc_datetime
    field :onboarded_at, :utc_datetime
    # Non-personalized mode (ADR 0012): no inferred signals used or learned.
    field :non_personalized, :boolean, default: false
    # Bumped on every algorithm settings change (ADR 0011).
    field :settings_version, :integer, default: 0

    has_one :profile, TSpec.Accounts.Profile

    timestamps(type: :utc_datetime)
  end

  @doc "A user changeset for registering with an email address."
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, TSpec.Repo)
    |> unique_constraint(:email)
  end

  @handle_format ~r/^[a-z0-9_]{3,30}$/

  @doc """
  Completes onboarding: sets the public handle and records the 13+ attestation.
  The age check itself happens in `TSpec.Accounts.onboard_user/2`; only its
  timestamp is stored here.
  """
  def onboarding_changeset(user, attrs) do
    now = DateTime.utc_now(:second)

    user
    |> cast(attrs, [:handle])
    |> update_change(:handle, &String.downcase/1)
    |> validate_required([:handle])
    |> validate_format(:handle, @handle_format,
      message: "must be 3-30 characters: lowercase letters, digits or underscores"
    )
    |> unsafe_validate_unique(:handle, TSpec.Repo)
    |> unique_constraint(:handle)
    |> put_change(:age_attested_at, now)
    |> put_change(:onboarded_at, now)
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end
end
