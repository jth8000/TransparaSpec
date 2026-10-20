defmodule TSpecWeb.Schemas.ConsentDocument do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ConsentDocument",
    type: :object,
    properties: %{
      version: %Schema{type: :integer},
      kind: %Schema{type: :string},
      published_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:version, :kind, :published_at]
  })
end
