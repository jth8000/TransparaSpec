defmodule TSpecWeb.Schemas.InterestEvidence do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "InterestEvidence",
    description: "The views an interest was learned from, newest first.",
    type: :object,
    properties: %{
      views: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            item: %Schema{allOf: [TSpecWeb.Schemas.ContentItem], nullable: true},
            viewed_at: %Schema{type: :string, format: :"date-time"},
            watched_ms: %Schema{type: :integer},
            duration_ms: %Schema{type: :integer, nullable: true},
            completed: %Schema{type: :boolean},
            delta: %Schema{type: :number, description: "How much this view moved the topic"}
          },
          required: [:item, :viewed_at, :watched_ms, :duration_ms, :completed, :delta]
        }
      }
    },
    required: [:views]
  })
end
