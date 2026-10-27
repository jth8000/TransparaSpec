defmodule TSpecWeb.CORS do
  @moduledoc """
  Which browser origins may call the JSON API (used by `CORSPlug` in the
  endpoint), decided per request from runtime config:

    * `:cors_origins` — exact origins, e.g. the deployed web client
      (`CLIENT_URL` in production)
    * `:cors_allow_localhost` — dev/test only: any `localhost` /
      `127.0.0.1` port, since Expo web moves off 8081 whenever another
      bundler (e.g. `make android`'s) already has it
  """

  @localhost ~r{\Ahttps?://(localhost|127\.0\.0\.1)(:\d+)?\z}

  @doc "The allowed origins for this request (CORSPlug matches the request's against them)."
  def allowed_origins(conn) do
    configured = Application.get_env(:tspec, :cors_origins, [])

    case Plug.Conn.get_req_header(conn, "origin") do
      [origin | _] ->
        if Application.get_env(:tspec, :cors_allow_localhost, false) and origin =~ @localhost,
          do: [origin | configured],
          else: configured

      [] ->
        configured
    end
  end
end
