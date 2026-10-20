defmodule TSpec.Accounts.Consent do
  @moduledoc """
  A user's acceptance of a consent document version. The latest unrevoked
  consent is the `consent_version` stamped on every engagement event (ADR 0007).
  """
  use TSpec.Schema

  schema "consents" do
    field :version, :integer
    field :scopes, {:array, :string}, default: []
    field :granted_at, :utc_datetime
    field :revoked_at, :utc_datetime
    belongs_to :user, TSpec.Accounts.User
  end
end
