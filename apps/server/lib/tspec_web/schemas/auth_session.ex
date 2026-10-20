defmodule TSpecWeb.Schemas.AuthSession do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AuthSession",
    description: "A new API session. Send `token` as `Authorization: Bearer <token>`.",
    type: :object,
    properties: %{
      token: %Schema{type: :string},
      user: TSpecWeb.Schemas.Me
    },
    required: [:token, :user]
  })
end
