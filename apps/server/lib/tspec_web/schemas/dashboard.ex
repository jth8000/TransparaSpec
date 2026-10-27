defmodule TSpecWeb.Schemas.Dashboard do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Dashboard",
    description: "Aggregates over items you were actually shown in your For You feed.",
    type: :object,
    properties: %{
      days: %Schema{type: :integer, enum: [7, 30]},
      shown: %Schema{type: :integer},
      topic_mix: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            date: %Schema{type: :string, format: :date},
            topics: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{topic: %Schema{type: :string}, count: %Schema{type: :integer}},
                required: [:topic, :count]
              }
            }
          },
          required: [:date, :topics]
        }
      },
      top_drivers: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            feature: %Schema{type: :string},
            detail: %Schema{type: :string, nullable: true, description: "Topic or source"},
            total: %Schema{type: :number},
            items: %Schema{type: :integer}
          },
          required: [:feature, :detail, :total, :items]
        }
      }
    },
    required: [:days, :shown, :topic_mix, :top_drivers]
  })
end
