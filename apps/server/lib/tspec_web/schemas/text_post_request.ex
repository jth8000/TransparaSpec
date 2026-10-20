defmodule TSpecWeb.Schemas.TextPostRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TextPostRequest",
    type: :object,
    properties: %{
      body: %Schema{type: :string, minLength: 1, maxLength: 2000},
      caption: %Schema{type: :string, maxLength: 2200}
    },
    required: [:body]
  })
end
