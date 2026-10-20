defmodule TSpecWeb.Schemas.ContentItem do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ContentItem",
    description: "Any piece of content. Exactly one of `video` / `text` is set, per `kind`.",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      kind: %Schema{type: :string, enum: ["short_video", "text_post"]},
      status: %Schema{type: :string, enum: ["processing", "ready", "failed", "removed"]},
      caption: %Schema{type: :string, nullable: true},
      published_at: %Schema{type: :string, format: :"date-time", nullable: true},
      created_at: %Schema{type: :string, format: :"date-time"},
      author: TSpecWeb.Schemas.Author,
      video: %Schema{allOf: [TSpecWeb.Schemas.VideoPayload], nullable: true},
      text: %Schema{allOf: [TSpecWeb.Schemas.TextPayload], nullable: true}
    },
    required: [:id, :kind, :status, :caption, :published_at, :created_at, :author, :video, :text]
  })
end
