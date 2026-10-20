defmodule TSpecWeb.Schemas.EventBatch do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "EventBatch",
    type: :object,
    properties: %{
      events: %Schema{
        type: :array,
        items: TSpecWeb.Schemas.EventInput,
        minItems: 1,
        maxItems: TSpec.Events.max_batch()
      }
    },
    required: [:events]
  })
end
