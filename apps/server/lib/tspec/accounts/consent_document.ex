defmodule TSpec.Accounts.ConsentDocument do
  @moduledoc "A published, versioned terms/privacy document users consent to."
  use TSpec.Schema

  @primary_key {:version, :integer, autogenerate: false}
  schema "consent_documents" do
    field :kind, :string
    field :body_hash, :string
    field :published_at, :utc_datetime
  end
end
