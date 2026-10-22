defmodule TSpecWeb.Schemas.Contribution do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Contribution",
    description: """
    One line of a ranking trace: `contribution = weight × value`, where
    `weight = default_weight × user_multiplier` (for `topic_preference`,
    `weight = default_weight × (user_multiplier − 1)`). An item's score is
    the sum of its contributions, in order.
    """,
    type: :object,
    properties: %{
      feature: %Schema{
        type: :string,
        enum:
          ~w(topic_affinity topic_preference creator_affinity following source_prior freshness quality diversity)
      },
      topic: %Schema{type: :string, nullable: true, description: "Topic slug, for topic features"},
      label_sources: %Schema{
        type: :array,
        nullable: true,
        items: %Schema{type: :string},
        description: "Who labeled the item with this topic"
      },
      source: %Schema{
        type: :string,
        nullable: true,
        description: "Candidate source, for source_prior"
      },
      default_weight: %Schema{type: :number},
      user_multiplier: %Schema{type: :number},
      weight: %Schema{type: :number},
      value: %Schema{type: :number},
      contribution: %Schema{type: :number}
    },
    required: [:feature, :default_weight, :user_multiplier, :weight, :value, :contribution]
  })
end
