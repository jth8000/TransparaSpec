defmodule TSpecWeb.Schemas.TextPayload do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TextPayload",
    type: :object,
    properties: %{body: %Schema{type: :string}},
    required: [:body]
  })
end
