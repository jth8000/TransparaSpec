defmodule TSpecWeb.Schemas.VideoPayload do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VideoPayload",
    description: "Playback details. URLs are null until the video is ready.",
    type: :object,
    properties: %{
      playback_url: %Schema{type: :string, nullable: true, description: "HLS (.m3u8)"},
      thumbnail_url: %Schema{type: :string, nullable: true},
      duration_ms: %Schema{type: :integer, nullable: true},
      width: %Schema{type: :integer, nullable: true},
      height: %Schema{type: :integer, nullable: true},
      failure_reason: %Schema{type: :string, nullable: true}
    },
    required: [:playback_url, :thumbnail_url, :duration_ms, :width, :height, :failure_reason]
  })
end
