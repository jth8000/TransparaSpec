defmodule TSpecWeb.ContentSecurityPolicy do
  @moduledoc """
  Sends a Content-Security-Policy on server-rendered HTML (the `:browser`
  pipeline). Scripts and styles may come only from this origin, or be
  inline tags carrying this request's nonce, so injected markup can't run
  script. The nonce is a fresh random value per request, assigned as
  `@csp_nonce` for templates: `<script nonce={@csp_nonce}>`.

  The JSON API and the Expo web client are outside this policy. The web
  client is served by its own host, which sets its own headers.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'nonce-#{nonce}'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        # 'self', not 'none': the dev mailbox frames its own HTML emails.
        "frame-ancestors 'self'"
      ],
      "; "
    )
  end
end
