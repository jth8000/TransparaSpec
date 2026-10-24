defmodule TSpecWeb.Schemas.ContentUpdate do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ContentUpdate",
    description: """
    Fields to change; omitted or null fields stay as they are. An empty
    `caption` ("") clears it. `topics` replaces the creator's topic labels
    (`[]` removes them).
    """,
    type: :object,
    properties: %{
      caption: %Schema{type: :string, maxLength: 2200, nullable: true},
      topics: TSpecWeb.Schemas.CreatorTopics
    }
  })
end
