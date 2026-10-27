defmodule TSpecWeb.Schemas.SettingsChange do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SettingsChange",
    description: "Changes to apply; anything omitted stays as it is.",
    type: :object,
    properties: %{
      topics: %Schema{
        type: :object,
        description: "By topic slug",
        additionalProperties: %Schema{
          type: :object,
          properties: %{
            multiplier: %Schema{type: :number, minimum: 0, maximum: 2},
            hard_off: %Schema{type: :boolean}
          }
        }
      },
      sources: %Schema{
        type: :object,
        description: "By candidate source",
        additionalProperties: %Schema{type: :number, minimum: 0, maximum: 2}
      },
      non_personalized: %Schema{type: :boolean}
    }
  })
end
