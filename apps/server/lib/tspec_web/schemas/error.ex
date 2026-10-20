defmodule TSpecWeb.Schemas.Error do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Error",
    description: "Error response. `fields` maps a field name to its validation messages.",
    type: :object,
    properties: %{
      error: %OpenApiSpex.Schema{type: :string, description: "Machine-readable error code"},
      message: %OpenApiSpex.Schema{type: :string},
      fields: %OpenApiSpex.Schema{
        type: :object,
        additionalProperties: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :string}
        }
      }
    },
    required: [:error]
  })
end
