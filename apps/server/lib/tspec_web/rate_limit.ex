defmodule TSpecWeb.RateLimit do
  @moduledoc """
  Per-client-address rate limiting for API actions, as a function plug:

      import TSpecWeb.RateLimit
      plug :rate_limit, :auth_request when action == :request

  A bucket's limit is `{requests, window_ms}` from `config :tspec,
  :rate_limits`. Past it, the request halts with 429 and `Retry-After`.

  The address is `conn.remote_ip`, which `TSpecWeb.ClientIP` sets from the
  proxy's header in production. IPv6 clients are keyed by their /64, since
  a single host is routinely given a whole /64 to pick addresses from.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def rate_limit(conn, bucket) do
    {limit, window_ms} = Application.fetch_env!(:tspec, :rate_limits) |> Keyword.fetch!(bucket)

    case TSpec.RateLimit.hit({bucket, client_key(conn.remote_ip)}, window_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, retry_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_ms, 1000) + 1))
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limited", message: "Too many requests. Try again later."})
        |> halt()
    end
  end

  @doc false
  # IPv4, and IPv4-mapped IPv6 (::ffff:a.b.c.d): the whole address.
  def client_key({_, _, _, _} = ip), do: ip
  def client_key({0, 0, 0, 0, 0, 0xFFFF, _, _} = ip), do: ip
  # Other IPv6: the /64 prefix.
  def client_key({a, b, c, d, _, _, _, _}), do: {a, b, c, d}
end
