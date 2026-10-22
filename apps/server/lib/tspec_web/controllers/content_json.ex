defmodule TSpecWeb.ContentJSON do
  @moduledoc "JSON shape for `Schemas.ContentItem`. Expects `Content.preload_for_render/1`."

  alias TSpec.Content.{Item, ShortVideo, TextPost}
  alias TSpec.Video

  def item(%Item{} = item) do
    %{
      id: item.id,
      kind: item.kind,
      status: item.status,
      caption: item.caption,
      published_at: item.published_at,
      created_at: item.inserted_at,
      author: author(item.author),
      video: video(item.short_video, item.status),
      text: text(item.text_post),
      topics: topics(item.content_topics)
    }
  end

  @doc """
  One entry per topic: its effective confidence (max over label sources) and
  which sources labeled it. Highest confidence first, then by name.
  """
  def topics(content_topics) do
    content_topics
    |> Enum.group_by(& &1.topic_id)
    |> Enum.map(fn {_id, [%{topic: topic} | _] = labels} ->
      %{
        slug: topic.slug,
        name: topic.name,
        tier: topic.tier,
        confidence: labels |> Enum.map(& &1.confidence) |> Enum.max(),
        sources: labels |> Enum.map(& &1.source) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{-&1.confidence, &1.name})
  end

  defp author(user) do
    profile = user.profile

    %{
      id: user.id,
      handle: user.handle,
      display_name: profile && profile.display_name,
      avatar_url: profile && profile.avatar_url
    }
  end

  defp video(nil, _status), do: nil

  defp video(%ShortVideo{} = v, status) do
    {playback_url, thumbnail_url} =
      if status == "ready" and v.playback_id do
        provider = Video.provider!(v.provider)
        {provider.playback_url(v.playback_id), provider.thumbnail_url(v.playback_id, [])}
      else
        {nil, nil}
      end

    %{
      playback_url: playback_url,
      thumbnail_url: thumbnail_url,
      duration_ms: v.duration_ms,
      width: v.width,
      height: v.height,
      failure_reason: v.failure_reason
    }
  end

  defp text(nil), do: nil
  defp text(%TextPost{body: body}), do: %{body: body}
end
