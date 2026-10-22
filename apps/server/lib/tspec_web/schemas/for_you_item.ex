defmodule TSpecWeb.Schemas.ForYouItem do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ForYouItem",
    description: """
    A ranked item. `impression_id` identifies this serving of it: "Why am I
    seeing this?" is `GET /api/impressions/{impression_id}`, and the client
    sends it with `view_start` when the item is actually shown.
    """,
    allOf: [
      TSpecWeb.Schemas.ContentItem,
      %Schema{
        type: :object,
        properties: %{
          impression_id: %Schema{type: :string, format: :uuid},
          candidate_source: %Schema{
            type: :string,
            enum: TSpec.Feed.Settings.sources(),
            description: "The candidate source that ranked it highest"
          }
        },
        required: [:impression_id, :candidate_source]
      }
    ]
  })
end
