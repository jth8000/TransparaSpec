defmodule TSpecWeb.Schemas.EventInput do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "EventInput",
    description:
      "One engagement event. The consent version is added by the server and is not accepted from clients.",
    type: :object,
    properties: %{
      content_id: %Schema{type: :string, format: :uuid},
      type: %Schema{type: :string, enum: TSpec.Events.Event.types()},
      value: %Schema{
        type: :number,
        nullable: true,
        description:
          "Seconds played so far in this view (cumulative across loops), where relevant"
      },
      occurred_at: %Schema{type: :string, format: :"date-time"},
      session_id: %Schema{type: :string, maxLength: 64, nullable: true},
      view_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description:
          "Playback episode: minted by the client each time an item becomes the active item. Interests are learned per view."
      },
      impression_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description:
          "The served impression this item came from (For You), marking it as actually shown. Ignored unless it's the caller's impression of this content."
      }
    },
    required: [:content_id, :type, :occurred_at]
  })
end
