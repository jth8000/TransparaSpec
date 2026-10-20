defmodule TSpecWeb.Schemas.CaptionUpdate do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CaptionUpdate",
    type: :object,
    properties: %{caption: %Schema{type: :string, maxLength: 2200, nullable: true}},
    required: [:caption]
  })
end
