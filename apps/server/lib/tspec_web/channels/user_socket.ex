defmodule TSpecWeb.UserSocket do
  @moduledoc """
  Real-time connection for API clients. Connect with `?token=<bearer token>`
  (the same token as the REST API).
  """
  use Phoenix.Socket

  alias TSpec.Accounts

  channel "user:*", TSpecWeb.UserChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Accounts.get_user_by_api_token(token) do
      nil -> :error
      user -> {:ok, assign(socket, :current_scope, Accounts.scope_for_user(user))}
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_scope.user.id}"
end
