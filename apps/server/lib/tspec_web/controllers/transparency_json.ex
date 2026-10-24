defmodule TSpecWeb.TransparencyJSON do
  @moduledoc "JSON shapes for explanations, settings, interests and the dashboard."

  alias TSpec.Content
  alias TSpec.Feed.{Ranker, Settings}
  alias TSpecWeb.ContentJSON

  @doc "Settings, from a live `%Settings{}` or a stored snapshot map."
  def settings(%Settings{} = s), do: settings(Settings.to_snapshot(s))

  def settings(%{
        "version" => version,
        "non_personalized" => np,
        "topics" => topics,
        "sources" => sources
      }) do
    %{
      version: version,
      non_personalized: np,
      topics:
        topics
        |> Enum.sort()
        |> Enum.map(fn {slug, t} ->
          %{slug: slug, multiplier: t["multiplier"], hard_off: t["hard_off"]}
        end),
      sources:
        sources |> Enum.sort() |> Enum.map(fn {source, m} -> %{source: source, multiplier: m} end),
      available_sources: Settings.sources(),
      hard_off_threshold: Ranker.hard_off_threshold()
    }
  end

  def explanation(%{impression: i, settings: snapshot}) do
    names = Content.topics_by_slug()
    slugs = for c <- i.contributions, slug = c["topic"], uniq: true, do: slug

    %{
      impression_id: i.id,
      content_id: i.content_id,
      served_at: i.served_at,
      ranker_version: i.ranker_version,
      candidate_source: i.candidate_source,
      sources: i.sources,
      position: i.position,
      final_score: i.final_score,
      contributions: i.contributions,
      settings_version: i.settings_version,
      settings: settings(snapshot.settings),
      topic_names: Map.new(slugs, &{&1, (names[&1] && names[&1].name) || &1})
    }
  end

  def interests(%{topics: topics, creators: creators}) do
    by_id = Content.topics_by_id()

    %{
      topics:
        for t <- topics do
          %{
            slug: t.topic.slug,
            name: t.topic.name,
            tier: t.topic.tier,
            parent: t.topic.parent_id && by_id[t.topic.parent_id].slug,
            score: t.score,
            value: t.value,
            evidence_count: t.evidence_count
          }
        end,
      creators:
        Enum.map(creators, &Map.take(&1, [:creator_id, :handle, :score, :value, :evidence_count]))
    }
  end

  def evidence(views) do
    %{
      views:
        for v <- views do
          %{
            item: v.item && ContentJSON.item(v.item),
            viewed_at: v.viewed_at,
            watched_ms: v.watched_ms,
            duration_ms: v.duration_ms,
            completed: v.completed,
            delta: v.delta
          }
        end
    }
  end
end
