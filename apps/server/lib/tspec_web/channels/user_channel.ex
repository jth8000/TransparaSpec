defmodule TSpecWeb.UserChannel do
  @moduledoc """
  A user's private channel, `user:<id>`. Pushes:

    * `content_status` — `%{content_id, status}` when one of the user's
      uploads finishes processing (`ready` / `failed`).
  """
  use TSpecWeb, :channel

  alias TSpec.Content

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    scope = socket.assigns.current_scope

    if scope.user.id == user_id do
      :ok = Content.subscribe_content_status(scope)
      {:ok, socket}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_info({:content_status, payload}, socket) do
    push(socket, "content_status", payload)
    {:noreply, socket}
  end
end
