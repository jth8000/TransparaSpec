defmodule TSpecWeb.Schemas.ForYouPage do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ForYouPage",
    description: """
    A page of the For You feed. Pass `session_id` back for the next page and
    join channel `feed_session:{session_id}` for live re-ranks. `rev`
    increases with every re-rank of this feed.
    """,
    type: :object,
    properties: %{
      session_id: %Schema{type: :string, format: :uuid},
      rev: %Schema{type: :integer, minimum: 0},
      items: %Schema{type: :array, items: TSpecWeb.Schemas.ForYouItem}
    },
    required: [:session_id, :rev, :items]
  })
end
