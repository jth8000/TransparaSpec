defmodule TSpecWeb.Schemas.Me do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Me",
    description: "The signed-in user, including private fields.",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      email: %Schema{type: :string, format: :email},
      handle: %Schema{type: :string, nullable: true},
      display_name: %Schema{type: :string, nullable: true},
      bio: %Schema{type: :string, nullable: true},
      avatar_url: %Schema{type: :string, nullable: true},
      onboarded: %Schema{type: :boolean},
      consent_version: %Schema{type: :integer, nullable: true}
    },
    required: [
      :id,
      :email,
      :handle,
      :display_name,
      :bio,
      :avatar_url,
      :onboarded,
      :consent_version
    ]
  })
end
