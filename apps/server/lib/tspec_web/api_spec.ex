defmodule TSpecWeb.ApiSpec do
  @moduledoc """
  OpenAPI description of the JSON API. Exported to `packages/api-schema` and
  used to generate the TypeScript client (`make api-gen`).
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{title: "T-Spec API", version: "0.1.0"},
      paths: Paths.from_router(TSpecWeb.Router),
      components: %Components{
        securitySchemes: %{
          "bearer" => %SecurityScheme{type: "http", scheme: "bearer"}
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
