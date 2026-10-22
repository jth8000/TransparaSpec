defmodule TSpecWeb.Schemas.Topic do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Topic",
    description: "A taxonomy topic (IAB Content Taxonomy 3.1, tiers 1–2).",
    type: :object,
    properties: %{
      slug: %Schema{type: :string, example: "fitness-and-exercise"},
      name: %Schema{type: :string, example: "Fitness and Exercise"},
      tier: %Schema{type: :integer, enum: [1, 2]},
      parent: %Schema{type: :string, nullable: true, description: "Parent slug (tier 2 only)"}
    },
    required: [:slug, :name, :tier, :parent]
  })
end
