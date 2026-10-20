defmodule TSpecWeb.OnboardingController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Accounts
  alias TSpecWeb.{Schemas, UserJSON}

  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["me"]
  security [%{"bearer" => []}]

  operation :create,
    summary: "Complete onboarding (handle, 13+ check, consent)",
    description:
      "Users under 13 are rejected with `age_requirement` and their account is deleted. The birthdate is never stored.",
    request_body: {"Onboarding", "application/json", Schemas.OnboardingRequest},
    responses: [
      ok: {"Me", "application/json", Schemas.Me},
      forbidden: {"Under 13", "application/json", Schemas.Error},
      conflict: {"Already onboarded", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid handle or consent", "application/json", Schemas.Error}
    ]

  def create(conn, _params) do
    %Schemas.OnboardingRequest{} = body = conn.body_params
    user = conn.assigns.current_scope.user

    with {:ok, user} <- Accounts.onboard_user(user, Map.from_struct(body)) do
      json(conn, UserJSON.me(Accounts.scope_for_user(user)))
    end
  end
end
