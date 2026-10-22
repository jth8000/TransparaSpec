defmodule TSpecWeb.FeedChannel do
  @moduledoc """
  Live control of one For You feed, `feed_session:<session_id>` (ADR 0011).

  Client → server:

    * `at` `{impression_id, rev}` — the visible item changed
    * `update_settings` `{topics?, sources?, non_personalized?}` — the fast
      path for sliders: saves the change (bumping `settings_version`) and
      replies; every session of the user, this one included, then re-ranks
      and pushes

  Server → client:

    * `feed_reranked` `{session_id, rev, after_impression_id, items}` — keep
      everything up to and including `after_impression_id` and replace the
      rest with `items` (a null `after_impression_id` means nothing had been
      served yet: replace everything); drop pushes with a `rev` older than
      the one you hold
  """
  use TSpecWeb, :channel

  alias TSpec.Feed.Session
  alias TSpec.{Feed, Transparency}
  alias TSpecWeb.FeedJSON

  @impl true
  def join("feed_session:" <> session_id, _payload, socket) do
    scope = socket.assigns.current_scope

    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         {:ok, pid} <- Session.ensure(scope, session_id) do
      :ok = Phoenix.PubSub.subscribe(TSpec.PubSub, Session.topic(scope.user.id, session_id))
      {:ok, assign(socket, session_id: session_id, session: pid)}
    else
      _ -> {:error, %{reason: "invalid_session"}}
    end
  end

  @impl true
  def handle_in("at", %{"impression_id" => id, "rev" => rev}, socket)
      when is_binary(id) and is_integer(rev) do
    Session.at(session(socket), id, rev)
    {:noreply, socket}
  end

  def handle_in("update_settings", payload, socket) when is_map(payload) do
    case Transparency.update_settings(socket.assigns.current_scope, parse_changes(payload)) do
      {:ok, settings} -> {:reply, {:ok, %{settings_version: settings.version}}, socket}
      {:error, reason, message} -> {:reply, {:error, %{error: reason, message: message}}, socket}
    end
  end

  def handle_in(_event, _payload, socket), do: {:reply, {:error, %{error: "bad_request"}}, socket}

  @impl true
  def handle_info({:feed_reranked, payload}, socket) do
    push(socket, "feed_reranked", %{
      session_id: payload.session_id,
      rev: payload.rev,
      after_impression_id: payload.after_impression_id,
      items: payload.items |> Feed.load_served() |> Enum.map(&FeedJSON.for_you_item/1)
    })

    {:noreply, socket}
  end

  # The session may have idled out and restarted since the join.
  defp session(socket) do
    {:ok, pid} = Session.ensure(socket.assigns.current_scope, socket.assigns.session_id)
    pid
  end

  @doc false
  # String-keyed JSON to the change map `Transparency.update_settings/2` takes.
  # Only known keys become atoms; values are validated there.
  def parse_changes(payload) do
    topics =
      for {slug, change} <- Map.get(payload, "topics", %{}), is_map(change), into: %{} do
        {slug,
         Map.new(Map.take(change, ["multiplier", "hard_off"]), fn {k, v} ->
           {String.to_existing_atom(k), v}
         end)}
      end

    %{}
    |> put_if(:topics, topics, topics != %{})
    |> put_if(:sources, Map.get(payload, "sources", %{}), Map.has_key?(payload, "sources"))
    |> put_if(
      :non_personalized,
      payload["non_personalized"],
      Map.has_key?(payload, "non_personalized")
    )
  end

  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp put_if(map, _key, _value, false), do: map
end
