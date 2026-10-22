defmodule TSpecWeb.Schemas.Interests do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Interests",
    description: """
    What the algorithm has learned about you from what you watched. `score`
    fades with a 14-day half-life unless renewed; `value` is the score as
    the ranker uses it, between -1 and 1.
    """,
    type: :object,
    properties: %{
      topics: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            slug: %Schema{type: :string},
            name: %Schema{type: :string},
            tier: %Schema{type: :integer},
            parent: %Schema{type: :string, nullable: true},
            score: %Schema{type: :number},
            value: %Schema{type: :number},
            evidence_count: %Schema{type: :integer}
          },
          required: [:slug, :name, :tier, :parent, :score, :value, :evidence_count]
        }
      },
      creators: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            creator_id: %Schema{type: :string, format: :uuid},
            handle: %Schema{type: :string, nullable: true},
            score: %Schema{type: :number},
            value: %Schema{type: :number},
            evidence_count: %Schema{type: :integer}
          },
          required: [:creator_id, :handle, :score, :value, :evidence_count]
        }
      }
    },
    required: [:topics, :creators]
  })
end
