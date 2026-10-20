defmodule TSpecWeb.Schemas.Health do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Health",
    type: :object,
    properties: %{status: %OpenApiSpex.Schema{type: :string, enum: ["ok"]}},
    required: [:status]
  })
end
