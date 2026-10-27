defmodule TSpecWeb.AuthController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import TSpecWeb.RateLimit

  alias TSpec.Accounts
  alias TSpecWeb.{Schemas, UserJSON}

  plug :rate_limit, :auth_request when action == :request
  plug :rate_limit, :auth_verify when action == :verify
  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["auth"]

  operation :request,
    summary: "Start email sign-in",
    description:
      "Emails a 6-digit code and a magic link. Creates the account on first use. Always 202 for a well-formed email, unless rate limited: per client address, and per email address (5 an hour, 10 a day).",
    request_body: {"Email", "application/json", Schemas.AuthRequest},
    responses: [
      accepted: {"Email sent", "application/json", Schemas.StatusResponse},
      unprocessable_entity: {"Invalid email", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error}
    ]

  def request(conn, _params) do
    %Schemas.AuthRequest{email: email} = conn.body_params

    with :ok <- Accounts.request_login(email, &magic_link_url/1) do
      conn |> put_status(:accepted) |> json(%{status: "sent"})
    end
  end

  operation :verify,
    summary: "Finish sign-in with an emailed code or magic-link token",
    request_body: {"Code or token", "application/json", Schemas.AuthVerify},
    responses: [
      ok: {"Signed in", "application/json", Schemas.AuthSession},
      unauthorized: {"Invalid or expired code", "application/json", Schemas.Error},
      unprocessable_entity: {"Malformed request", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error}
    ]

  def verify(conn, _params) do
    result =
      case conn.body_params do
        %{token: token} when is_binary(token) ->
          Accounts.verify_login_token(token)

        %{email: email, code: code} when is_binary(email) and is_binary(code) ->
          Accounts.verify_login_code(email, code)

        _ ->
          {:error, :invalid_request, "Provide email and code, or token"}
      end

    with {:ok, user} <- result do
      token = Accounts.create_api_token(user)
      json(conn, %{token: token, user: UserJSON.me(Accounts.scope_for_user(user))})
    end
  end

  operation :delete,
    summary: "Sign out (revokes this bearer token)",
    security: [%{"bearer" => []}],
    responses: [no_content: "Signed out"]

  def delete(conn, _params) do
    :ok = Accounts.delete_api_token(conn.assigns.api_token)
    send_resp(conn, :no_content, "")
  end

  defp magic_link_url(token) do
    Application.fetch_env!(:tspec, :client_url) <> "/verify?token=" <> URI.encode_www_form(token)
  end
end
