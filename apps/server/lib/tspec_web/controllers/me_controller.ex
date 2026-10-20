defmodule TSpecWeb.MeController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Accounts
  alias TSpecWeb.{Schemas, UserJSON}

  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["me"]
  security [%{"bearer" => []}]

  operation :show,
    summary: "The signed-in user",
    responses: [ok: {"Me", "application/json", Schemas.Me}]

  def show(conn, _params), do: json(conn, UserJSON.me(conn.assigns.current_scope))

  operation :update,
    summary: "Update profile fields",
    request_body: {"Profile fields", "application/json", Schemas.ProfileUpdate},
    responses: [
      ok: {"Me", "application/json", Schemas.Me},
      unprocessable_entity: {"Invalid", "application/json", Schemas.Error}
    ]

  def update(conn, _params) do
    scope = conn.assigns.current_scope
    attrs = conn.body_params |> Map.from_struct() |> Map.take([:display_name, :bio])
    attrs = for {k, v} <- attrs, v != nil, into: %{}, do: {k, v}

    with {:ok, _profile} <- Accounts.update_profile(scope, attrs) do
      json(conn, UserJSON.me(scope))
    end
  end
end
