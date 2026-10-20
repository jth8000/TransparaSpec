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
        description: "Seconds watched, where relevant"
      },
      occurred_at: %Schema{type: :string, format: :"date-time"},
      session_id: %Schema{type: :string, maxLength: 64, nullable: true}
    },
    required: [:content_id, :type, :occurred_at]
  })
end
