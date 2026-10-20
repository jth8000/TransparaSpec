defmodule TSpecWeb.Schemas.ProfileUpdate do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ProfileUpdate",
    type: :object,
    properties: %{
      display_name: %Schema{type: :string, maxLength: 50, nullable: true},
      bio: %Schema{type: :string, maxLength: 300, nullable: true}
    }
  })
end
