defmodule TSpecWeb.UserSocket do
  @moduledoc """
  Real-time connection for API clients. Connect with `?token=<bearer token>`
  (the same token as the REST API).

  Each socket's id is derived from its token, so signing out (which revokes
  one token) can disconnect exactly that device's sockets: see `id_for_token/1`.
  """
  use Phoenix.Socket

  alias TSpec.Accounts

  channel "user:*", TSpecWeb.UserChannel
  channel "feed_session:*", TSpecWeb.FeedChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Accounts.get_user_by_api_token(token) do
      nil ->
        :error

      user ->
        {:ok,
         socket
         |> assign(:current_scope, Accounts.scope_for_user(user))
         |> assign(:socket_id, id_for_token(token))}
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: socket.assigns.socket_id

  @doc """
  The socket id for connections made with `token`. Broadcasting
  `"disconnect"` to it closes them on every node. It's a hash, so the token
  itself never travels over PubSub.
  """
  def id_for_token(token) do
    "api_token_socket:" <> Base.url_encode64(:crypto.hash(:sha256, token), padding: false)
  end
end
