defmodule TSpecWeb.Schemas.StatusResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StatusResponse",
    type: :object,
    properties: %{status: %Schema{type: :string}},
    required: [:status]
  })
end
