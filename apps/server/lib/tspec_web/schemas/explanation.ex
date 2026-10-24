defmodule TSpecWeb.Schemas.Explanation do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Explanation",
    description: """
    Why an item was shown: the exact trace stored when it was served, with
    the settings as they were then (not your current ones). `final_score`
    is the sum of `contributions`.
    """,
    type: :object,
    properties: %{
      impression_id: %Schema{type: :string, format: :uuid},
      content_id: %Schema{type: :string, format: :uuid},
      served_at: %Schema{type: :string, format: :"date-time"},
      ranker_version: %Schema{type: :string},
      candidate_source: %Schema{type: :string},
      sources: %Schema{type: :array, items: %Schema{type: :string}},
      position: %Schema{type: :integer},
      final_score: %Schema{type: :number},
      contributions: %Schema{type: :array, items: TSpecWeb.Schemas.Contribution},
      settings_version: %Schema{type: :integer},
      settings: TSpecWeb.Schemas.AlgorithmSettings,
      topic_names: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string},
        description: "Display names for the topic slugs in the trace"
      }
    },
    required: [
      :impression_id,
      :content_id,
      :served_at,
      :ranker_version,
      :candidate_source,
      :sources,
      :position,
      :final_score,
      :contributions,
      :settings_version,
      :settings,
      :topic_names
    ]
  })
end
