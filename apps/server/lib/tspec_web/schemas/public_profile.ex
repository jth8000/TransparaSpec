defmodule TSpecWeb.Schemas.PublicProfile do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PublicProfile",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      handle: %Schema{type: :string},
      display_name: %Schema{type: :string, nullable: true},
      bio: %Schema{type: :string, nullable: true},
      avatar_url: %Schema{type: :string, nullable: true},
      followers_count: %Schema{type: :integer},
      following_count: %Schema{type: :integer},
      followed_by_me: %Schema{type: :boolean}
    },
    required: [
      :id,
      :handle,
      :display_name,
      :bio,
      :avatar_url,
      :followers_count,
      :following_count,
      :followed_by_me
    ]
  })
end
