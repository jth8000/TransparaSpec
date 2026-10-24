defmodule TSpecWeb.Schemas.TopicLabel do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TopicLabel",
    description: """
    A topic on a content item. `confidence` is the max over label sources;
    `sources` says who labeled it. A creator label has confidence 1.0 because
    it is a deliberate declaration, not because it is certainly right.
    """,
    type: :object,
    properties: %{
      slug: %Schema{type: :string},
      name: %Schema{type: :string},
      tier: %Schema{type: :integer, enum: [1, 2]},
      confidence: %Schema{type: :number, minimum: 0, maximum: 1},
      sources: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: ["creator", "model", "moderator"]}
      }
    },
    required: [:slug, :name, :tier, :confidence, :sources]
  })
end
