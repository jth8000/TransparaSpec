defmodule TSpecWeb.Schemas.CreatorTopics do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CreatorTopics",
    description: "Topic slugs picked by the creator (see `GET /api/topics`), at most 3.",
    type: :array,
    items: %Schema{type: :string},
    maxItems: 3
  })
end
