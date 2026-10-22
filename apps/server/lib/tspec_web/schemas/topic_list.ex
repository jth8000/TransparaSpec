defmodule TSpecWeb.Schemas.TopicList do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TopicList",
    type: :object,
    properties: %{
      topics: %Schema{type: :array, items: TSpecWeb.Schemas.Topic},
      max_creator_topics: %Schema{
        type: :integer,
        description: "How many topics a creator may pick"
      }
    },
    required: [:topics, :max_creator_topics]
  })
end
