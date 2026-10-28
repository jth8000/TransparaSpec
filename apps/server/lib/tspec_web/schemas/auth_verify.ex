defmodule TSpecWeb.Schemas.AuthVerify do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AuthVerify",
    description:
      "`email` plus either `code` (the 6-digit code from the email) or `token` (from the magic link).",
    type: :object,
    properties: %{
      email: %Schema{type: :string, format: :email},
      code: %Schema{type: :string, pattern: "^[0-9]{6}$"},
      token: %Schema{type: :string}
    }
  })
end
