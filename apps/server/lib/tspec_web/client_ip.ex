defmodule TSpecWeb.ClientIP do
  @moduledoc """
  Sets `conn.remote_ip` to the client's address reported by the proxy in
  front of the app, read from the header named by `config :tspec,
  :client_ip_header` (production: `fly-client-ip`). With no header
  configured, or a missing or malformed value, `remote_ip` stays the
  socket's peer address.

  Only configure a header that the proxy always sets and that clients can't
  reach the app without: otherwise a client could pick its own address and
  slip past per-address rate limits (`TSpecWeb.RateLimit`).
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with header when is_binary(header) <- Application.get_env(:tspec, :client_ip_header),
         [value | _] <- Plug.Conn.get_req_header(conn, header),
         {:ok, ip} <-
           value |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end
end
