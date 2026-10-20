defmodule TSpecWeb.Schemas.OnboardingRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OnboardingRequest",
    description:
      "Choose a handle, confirm age (the birthdate is checked and discarded, never stored) and accept the current consent document.",
    type: :object,
    properties: %{
      handle: %Schema{type: :string, pattern: "^[a-zA-Z0-9_]{3,30}$"},
      birthdate: %Schema{type: :string, format: :date},
      accept_consent_version: %Schema{type: :integer},
      display_name: %Schema{type: :string, maxLength: 50}
    },
    required: [:handle, :birthdate, :accept_consent_version]
  })
end
