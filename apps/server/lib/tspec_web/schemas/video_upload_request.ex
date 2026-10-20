defmodule TSpecWeb.Schemas.VideoUploadRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VideoUploadRequest",
    type: :object,
    properties: %{caption: %Schema{type: :string, maxLength: 2200}}
  })
end
