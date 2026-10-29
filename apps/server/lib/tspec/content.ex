defmodule TSpec.Content do
  @moduledoc """
  Content items and their payloads (ADR 0008): short videos and text posts.
  Video uploads go to the configured `TSpec.Video.Provider`; its webhooks move
  items from `processing` to `ready` or `failed`.

  Items carry topic labels (`content_topics`) from the IAB-based taxonomy.
  Creators pick up to three topics by slug; the ML service adds `model` labels
  in Phase 1b.
  """
  import Ecto.Query, warn: false

  alias TSpec.Repo
  alias TSpec.Accounts.Scope

  alias TSpec.Content.{
    ContentTopic,
    DeleteAssetWorker,
    Item,
    ShortVideo,
    TextPost,
    Topic,
    VideoEventWorker
  }

  alias TSpec.Video

  @render_preloads [:short_video, :text_post, author: :profile, content_topics: :topic]
  @max_creator_topics 3

  def max_creator_topics, do: @max_creator_topics

  ## Topics

  @doc """
  All topics, tier 1 first, each tier by name. The taxonomy is reference data
  seeded by migration, so it's cached for the life of the node.
  """
  def list_topics do
    case :persistent_term.get({__MODULE__, :topics}, nil) do
      nil ->
        topics = Repo.all(from t in Topic, order_by: [asc: t.tier, asc: t.name])
        :persistent_term.put({__MODULE__, :topics}, topics)
        topics

      topics ->
        topics
    end
  end

  @doc "Topics keyed by slug."
  def topics_by_slug, do: Map.new(list_topics(), &{&1.slug, &1})

  @doc "Topics keyed by id."
  def topics_by_id, do: Map.new(list_topics(), &{&1.id, &1})

  # Resolves the `:topics` slugs in creator attrs. `:keep` when absent (an
  # edit that doesn't touch topics).
  defp resolve_creator_topics(attrs) do
    case Map.fetch(attrs, :topics) do
      :error ->
        {:ok, :keep}

      {:ok, slugs} when is_list(slugs) ->
        slugs = Enum.uniq(slugs)
        by_slug = topics_by_slug()

        case Enum.reject(slugs, &Map.has_key?(by_slug, &1)) do
          [] when length(slugs) <= @max_creator_topics ->
            {:ok, Enum.map(slugs, &by_slug[&1].id)}

          [] ->
            topics_error("pick at most #{@max_creator_topics} topics")

          unknown ->
            topics_error("unknown topics: #{Enum.join(unknown, ", ")}")
        end
    end
  end

  defp topics_error(message) do
    {:error, %Item{} |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(:topics, message)}
  end

  # Replaces the item's creator labels. Model/moderator labels are untouched.
  defp put_creator_topics(_item, :keep), do: :ok

  defp put_creator_topics(%Item{id: id}, topic_ids) do
    Repo.delete_all(
      from ct in ContentTopic, where: ct.content_id == ^id and ct.source == "creator"
    )

    Repo.insert_all(
      ContentTopic,
      for(
        tid <- topic_ids,
        do: %{content_id: id, topic_id: tid, source: "creator", confidence: 1.0}
      )
    )

    :ok
  end

  ## Creating content

  @doc """
  Creates a short-video item in `processing` and a direct-upload slot at the
  video provider. Returns `{:ok, {item, upload}}`; the client uploads the file
  to `upload.url` itself.
  """
  def create_video_upload(%Scope{user: user}, attrs) do
    provider_name = Video.default_provider_name()
    provider = Video.provider!(provider_name)

    # Validate topics before asking the provider for an upload slot.
    with {:ok, topic_ids} <- resolve_creator_topics(attrs),
         {:ok, upload} <-
           provider.create_direct_upload(%{max_duration_seconds: Video.max_duration_seconds()}) do
      Repo.transact(fn ->
        with {:ok, item} <-
               %Item{author_id: user.id, kind: "short_video", status: "processing"}
               |> Item.caption_changeset(attrs)
               |> Repo.insert(),
             :ok <- put_creator_topics(item, topic_ids) do
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
      with {:ok, topic_ids} <- resolve_creator_topics(attrs),
           {:ok, item} <-
             %Item{
               author_id: user.id,
               kind: "text_post",
               status: "ready",
               published_at: DateTime.utc_now()
             }
             |> Item.caption_changeset(attrs)
             |> Repo.insert(),
           {:ok, _post} <-
             %TextPost{content_id: item.id} |> TextPost.changeset(attrs) |> Repo.insert(),
           :ok <- put_creator_topics(item, topic_ids) do
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

  @doc """
  Edits an item the scope owns. `attrs` may carry `:caption` and/or `:topics`
  (creator topic slugs, replacing the previous creator labels).
  """
  def update_item(%Scope{} = scope, id, attrs) do
    with {:ok, item} <- get_own_item(scope, id),
         {:ok, topic_ids} <- resolve_creator_topics(attrs) do
      Repo.transact(fn ->
        with {:ok, item} <- item |> Item.caption_changeset(attrs) |> Repo.update(),
             :ok <- put_creator_topics(item, topic_ids) do
          {:ok, item |> Repo.preload(@render_preloads, force: true)}
        end
      end)
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
  def apply_video_event(provider_name, event, opts \\ [])

  def apply_video_event(_provider_name, %{"type" => "ignored"}, _opts), do: :ok

  def apply_video_event(provider_name, %{"type" => type, "asset_id" => asset_id} = event, opts) do
    query =
      from v in ShortVideo,
        join: i in Item,
        on: i.id == v.content_id,
        where: v.provider == ^provider_name and v.asset_id == ^asset_id,
        select: {v, i}

    case Repo.one(query) do
      {video, %Item{status: "processing"} = item} ->
        # Test seam: pause between the read above and the write.
        if hook = Keyword.get(opts, :before_update), do: hook.()
        apply_event(type, event, video, item)

      _ ->
        :ok
    end
  end

  defp apply_event("ready", event, video, item) do
    finish(item, [status: "ready", published_at: DateTime.utc_now(:second)], fn ->
      Repo.update!(
        Ecto.Changeset.change(video,
          playback_id: event["playback_id"],
          duration_ms: event["duration_ms"],
          width: event["width"],
          height: event["height"]
        )
      )
    end)
  end

  defp apply_event("failed", event, video, item) do
    finish(item, [status: "failed"], fn ->
      Repo.update!(Ecto.Changeset.change(video, failure_reason: event["reason"]))
    end)
  end

  # Moves the item out of `processing` and runs `update_video`, in one
  # transaction. The status change is conditional, like the one in
  # `expire_stale_uploads/1`: if expiry (or another event) got there first,
  # the item isn't processing anymore, so nothing changes and nothing is
  # broadcast. The item was read before this, without a lock.
  defp finish(%Item{id: id}, changes, update_video) do
    result =
      Repo.transact(fn ->
        from(i in Item, where: i.id == ^id and i.status == "processing", select: i)
        |> Repo.update_all(set: [{:updated_at, DateTime.utc_now(:second)} | changes])
        |> case do
          {1, [item]} ->
            update_video.()
            {:ok, item}

          {0, _} ->
            {:error, :not_processing}
        end
      end)

    with {:ok, item} <- result, do: broadcast_status(item)
    :ok
  end

  ## Abandoned uploads

  @doc """
  Fails video items still `processing` that were created before `cutoff`:
  upload slots whose bytes never arrived (the client gave up, or retried
  with a fresh slot) or that the provider never finished. Marks them
  `failed` with reason `upload_expired`, schedules deletion of their
  provider assets and notifies their authors. Returns `{:ok, count}`.

  The status change is one conditional UPDATE, so it can't race a provider
  event: whichever commits first wins, and a later `ready` finds the item
  no longer processing and is ignored.
  """
  def expire_stale_uploads(%DateTime{} = cutoff) do
    {:ok, items} =
      Repo.transact(fn ->
        {_, items} =
          from(i in Item,
            where:
              i.kind == "short_video" and i.status == "processing" and i.inserted_at < ^cutoff,
            select: i
          )
          |> Repo.update_all(set: [status: "failed", updated_at: DateTime.utc_now(:second)])

        {_, videos} =
          from(v in ShortVideo,
            where: v.content_id in ^Enum.map(items, & &1.id),
            select: %{provider: v.provider, asset_id: v.asset_id}
          )
          |> Repo.update_all(set: [failure_reason: "upload_expired"])

        Oban.insert_all(Enum.map(videos, &DeleteAssetWorker.new/1))
        {:ok, items}
      end)

    Enum.each(items, &broadcast_status/1)
    {:ok, length(items)}
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
