defmodule TSpecWeb.Schemas.Author do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Author",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      handle: %Schema{type: :string},
      display_name: %Schema{type: :string, nullable: true},
      avatar_url: %Schema{type: :string, nullable: true}
    },
    required: [:id, :handle, :display_name, :avatar_url]
  })
end
