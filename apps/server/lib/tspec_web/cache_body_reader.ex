defmodule TSpecWeb.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw request body for webhook
  routes, whose signatures are computed over the exact bytes received.
  Other routes are read normally (no extra memory).

  One `read_body/2` call reads up to the parser's `:length` (8 MB). A
  longer body comes back as `{:more, ...}`, which the parser turns into a
  413, so an unauthenticated webhook request can't make us buffer more.
  """

  def read_body(%Plug.Conn{request_path: "/api/webhooks/" <> _} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
      other -> other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
