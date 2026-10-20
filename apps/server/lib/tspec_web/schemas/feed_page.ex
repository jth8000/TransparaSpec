defmodule TSpecWeb.Schemas.FeedPage do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "FeedPage",
    type: :object,
    properties: %{
      items: %Schema{type: :array, items: TSpecWeb.Schemas.ContentItem},
      next_cursor: %Schema{
        type: :string,
        nullable: true,
        description: "Pass as `cursor` to get the next page; null at the end"
      }
    },
    required: [:items, :next_cursor]
  })
end
