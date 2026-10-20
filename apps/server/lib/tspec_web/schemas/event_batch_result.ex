defmodule TSpecWeb.Schemas.EventBatchResult do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "EventBatchResult",
    type: :object,
    properties: %{
      accepted: %Schema{type: :integer},
      rejected: %Schema{type: :integer}
    },
    required: [:accepted, :rejected]
  })
end
