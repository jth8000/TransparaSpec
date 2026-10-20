defmodule TSpecWeb.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw request body for webhook
  routes, whose signatures are computed over the exact bytes received.
  Other routes are read normally (no extra memory).
  """

  def read_body(%Plug.Conn{request_path: "/api/webhooks/" <> _} = conn, opts) do
    with {:ok, body, conn} <- read_all(conn, opts, []) do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp read_all(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary([acc, chunk]), conn}
      {:more, chunk, conn} -> read_all(conn, opts, [acc, chunk])
      {:error, _} = error -> error
    end
  end
end
