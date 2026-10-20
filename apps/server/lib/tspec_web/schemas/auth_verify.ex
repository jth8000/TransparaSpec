defmodule TSpecWeb.Schemas.AuthVerify do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AuthVerify",
    description: "Either `email` + `code` (6-digit code from the email) or `token` (magic link).",
    type: :object,
    properties: %{
      email: %Schema{type: :string, format: :email},
      code: %Schema{type: :string, pattern: "^[0-9]{6}$"},
      token: %Schema{type: :string}
    }
  })
end
