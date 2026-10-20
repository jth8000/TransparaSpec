defmodule TSpec.Content do
  @moduledoc """
  Content items and their payloads (ADR 0008): short videos and text posts in
  Phase 0. Video uploads go to the configured `TSpec.Video.Provider`; its
  webhooks move items from `processing` to `ready` or `failed`.
  """
  import Ecto.Query, warn: false

  alias TSpec.Repo
  alias TSpec.Accounts.Scope
  alias TSpec.Content.{DeleteAssetWorker, Item, ShortVideo, TextPost, VideoEventWorker}
  alias TSpec.Video

  @render_preloads [:short_video, :text_post, author: :profile]

  ## Creating content

  @doc """
  Creates a short-video item in `processing` and a direct-upload slot at the
  video provider. Returns `{:ok, {item, upload}}`; the client uploads the file
  to `upload.url` itself.
  """
  def create_video_upload(%Scope{user: user}, attrs) do
    provider_name = Video.default_provider_name()
    provider = Video.provider!(provider_name)

    with {:ok, upload} <-
           provider.create_direct_upload(%{max_duration_seconds: Video.max_duration_seconds()}) do
      Repo.transact(fn ->
        with {:ok, item} <-
               %Item{author_id: user.id, kind: "short_video", status: "processing"}
               |> Item.caption_changeset(attrs)
               |> Repo.insert() do
          Repo.insert!(%ShortVideo{
            content_id: item.id,
            provider: provider_name,
            asset_id: upload.asset_id
          })

          {:ok, {preload_for_render(item), upload}}
        end
      end)
    end
  end

  @doc "Creates a text post, published immediately."
  def create_text_post(%Scope{user: user}, attrs) do
    Repo.transact(fn ->
      with {:ok, item} <-
             %Item{
               author_id: user.id,
               kind: "text_post",
               status: "ready",
               published_at: DateTime.utc_now()
             }
             |> Item.caption_changeset(attrs)
             |> Repo.insert(),
           {:ok, _post} <-
             %TextPost{content_id: item.id} |> TextPost.changeset(attrs) |> Repo.insert() do
        {:ok, preload_for_render(item)}
      end
    end)
  end

  ## Reading

  @doc """
  Gets an item the scope may see: any ready public item, or any non-removed
  item the caller authored (so creators can watch their uploads process).
  """
  def get_item(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Item{} = item <- Repo.get(Item, id),
         true <- visible?(scope, item) do
      {:ok, preload_for_render(item)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp visible?(_scope, %Item{status: "ready", visibility: "public"}), do: true

  defp visible?(%Scope{user: %{id: user_id}}, %Item{author_id: user_id, status: status}),
    do: status != "removed"

  defp visible?(_scope, _item), do: false

  def preload_for_render(item_or_items), do: Repo.preload(item_or_items, @render_preloads)

  ## Editing

  def update_caption(%Scope{} = scope, id, attrs) do
    with {:ok, item} <- get_own_item(scope, id),
         {:ok, item} <- item |> Item.caption_changeset(attrs) |> Repo.update() do
      {:ok, preload_for_render(item)}
    end
  end

  @doc "Removes an item (soft delete) and schedules deletion of any video asset."
  def remove_item(%Scope{} = scope, id) do
    with {:ok, item} <- get_own_item(scope, id) do
      item = Repo.preload(item, :short_video)

      Repo.transact(fn ->
        Repo.update!(Ecto.Changeset.change(item, status: "removed"))

        if video = item.short_video do
          Oban.insert!(
            DeleteAssetWorker.new(%{provider: video.provider, asset_id: video.asset_id})
          )
        end

        {:ok, :removed}
      end)
      |> case do
        {:ok, :removed} -> :ok
        error -> error
      end
    end
  end

  defp get_own_item(%Scope{user: %{id: user_id}}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Item{author_id: ^user_id, status: status} = item when status != "removed" <-
           Repo.get(Item, id) do
      {:ok, item}
    else
      # Own but already removed: behave as if it no longer exists.
      %Item{author_id: ^user_id} -> {:error, :not_found}
      %Item{} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  ## Provider events

  @doc "Queues a verified provider event for processing (webhooks return fast)."
  def enqueue_video_event(provider_name, event) do
    {:ok, _job} =
      %{provider: provider_name, event: event}
      |> VideoEventWorker.new()
      |> Oban.insert()

    :ok
  end

  @doc """
  Applies a provider event (string-keyed, as stored in the job). Idempotent:
  replays and events for removed or unknown assets are no-ops.
  """
  def apply_video_event(_provider_name, %{"type" => "ignored"}), do: :ok

  def apply_video_event(provider_name, %{"type" => type, "asset_id" => asset_id} = event) do
    query =
      from v in ShortVideo,
        join: i in Item,
        on: i.id == v.content_id,
        where: v.provider == ^provider_name and v.asset_id == ^asset_id,
        select: {v, i}

    case Repo.one(query) do
      {video, %Item{status: "processing"} = item} -> apply_event(type, event, video, item)
      _ -> :ok
    end
  end

  defp apply_event("ready", event, video, item) do
    {:ok, item} =
      Repo.transact(fn ->
        Repo.update!(
          Ecto.Changeset.change(video,
            playback_id: event["playback_id"],
            duration_ms: event["duration_ms"],
            width: event["width"],
            height: event["height"]
          )
        )

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(item, status: "ready", published_at: DateTime.utc_now())
         )}
      end)

    broadcast_status(item)
  end

  defp apply_event("failed", event, video, item) do
    {:ok, item} =
      Repo.transact(fn ->
        Repo.update!(Ecto.Changeset.change(video, failure_reason: event["reason"]))
        {:ok, Repo.update!(Ecto.Changeset.change(item, status: "failed"))}
      end)

    broadcast_status(item)
  end

  ## Status notifications

  @doc "Subscribes the caller to status changes of the scope user's uploads."
  def subscribe_content_status(%Scope{user: user}) do
    Phoenix.PubSub.subscribe(TSpec.PubSub, status_topic(user.id))
  end

  defp broadcast_status(%Item{} = item) do
    Phoenix.PubSub.broadcast(
      TSpec.PubSub,
      status_topic(item.author_id),
      {:content_status, %{content_id: item.id, status: item.status}}
    )

    :ok
  end

  defp status_topic(user_id), do: "content_status:#{user_id}"
end
