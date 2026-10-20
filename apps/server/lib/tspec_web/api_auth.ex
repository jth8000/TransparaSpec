defmodule TSpecWeb.ApiAuth do
  @moduledoc """
  Bearer-token authentication for the JSON API.

  `fetch_api_scope/2` reads `Authorization: Bearer <token>` and assigns
  `:current_scope` (or nil). `require_api_user/2` and `require_onboarded/2`
  halt with a JSON error when the caller isn't signed in / hasn't finished
  onboarding (handle, 13+ attestation, consent).
  """
  import Plug.Conn
  import Phoenix.Controller

  alias TSpec.Accounts
  alias TSpec.Accounts.Scope

  def fetch_api_scope(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         %Accounts.User{} = user <- Accounts.get_user_by_api_token(token) do
      conn
      |> assign(:current_scope, Accounts.scope_for_user(user))
      |> assign(:api_token, token)
    else
      _ -> assign(conn, :current_scope, nil)
    end
  end

  def require_api_user(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{} -> conn
      _ -> halt_with(conn, :unauthorized, "unauthorized", "Authentication required")
    end
  end

  def require_onboarded(conn, _opts) do
    if Scope.onboarded?(conn.assigns[:current_scope]) do
      conn
    else
      halt_with(conn, :forbidden, "onboarding_required", "Finish onboarding first")
    end
  end

  @doc "Extracts the bearer token from a header value or connection."
  def bearer_token(%Plug.Conn{} = conn) do
    conn |> get_req_header("authorization") |> List.first() |> bearer_token()
  end

  def bearer_token("Bearer " <> token) when byte_size(token) > 0, do: {:ok, String.trim(token)}
  def bearer_token(_), do: :error

  defp halt_with(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: code, message: message})
    |> halt()
  end
end
