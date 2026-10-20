defmodule TSpecWeb.Schemas.VideoUpload do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VideoUpload",
    description:
      "The new item (status `processing`) and where to send the file: an HTTP `method` request to `url` with the file in multipart field `form_field`. The file goes straight to the video provider.",
    type: :object,
    properties: %{
      content: TSpecWeb.Schemas.ContentItem,
      upload: %Schema{
        type: :object,
        properties: %{
          url: %Schema{type: :string},
          method: %Schema{type: :string, enum: ["POST"]},
          form_field: %Schema{type: :string}
        },
        required: [:url, :method, :form_field]
      }
    },
    required: [:content, :upload]
  })
end
