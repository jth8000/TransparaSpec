defmodule TSpecWeb.Schemas.AlgorithmSettings do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AlgorithmSettings",
    description: """
    Your algorithm controls. Only non-default entries are listed (multiplier
    1 and not hard-off is the default). A tier-2 topic without its own entry
    follows its tier-1 parent.
    """,
    type: :object,
    properties: %{
      version: %Schema{type: :integer, minimum: 0},
      non_personalized: %Schema{type: :boolean},
      topics: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            slug: %Schema{type: :string},
            multiplier: %Schema{type: :number, minimum: 0, maximum: 2},
            hard_off: %Schema{type: :boolean}
          },
          required: [:slug, :multiplier, :hard_off]
        }
      },
      sources: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            source: %Schema{type: :string, enum: TSpec.Feed.Settings.sources()},
            multiplier: %Schema{type: :number, minimum: 0, maximum: 2}
          },
          required: [:source, :multiplier]
        }
      },
      available_sources: %Schema{type: :array, items: %Schema{type: :string}},
      hard_off_threshold: %Schema{
        type: :number,
        description: "Hard-off hides items labeled with the topic at this confidence or more"
      }
    },
    required: [
      :version,
      :non_personalized,
      :topics,
      :sources,
      :available_sources,
      :hard_off_threshold
    ]
  })
end
