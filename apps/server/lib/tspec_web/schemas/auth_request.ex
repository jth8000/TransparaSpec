defmodule TSpecWeb.Schemas.AuthRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AuthRequest",
    description: "Start email sign-in (also creates the account on first use).",
    type: :object,
    properties: %{email: %Schema{type: :string, format: :email, maxLength: 160}},
    required: [:email]
  })
end
