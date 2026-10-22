defmodule TSpec.Feed.Candidates do
  @moduledoc """
  Candidate generation, SQL v1 (ADR 0011): cheap queries that each nominate
  plausible items, labeled with the source that found them. The ranker then
  orders the union precisely.

  | Source          | Nominates                                                    |
  |-----------------|--------------------------------------------------------------|
  | `following`     | recent items from accounts the user follows                  |
  | `topic`         | recent items in the user's top affinity topics, plus every   |
  |                 | topic they've explicitly boosted                             |
  | `trending`      | the global trending pool (`TSpec.Feed.TrendingWorker`)       |
  | `co_engagement` | items completed by people who completed what you completed   |
  | `explore`       | random recent items in topics you have no history with       |
  | `fresh`         | the newest public items                                      |

  Non-personalized mode uses only `following`, `trending` and `fresh`: no
  source that reads the user's inferred profile or viewing history
  (ADR 0012).

  Every source shares the same eligibility filter: ready and public, not
  the user's own, published within 30 days, not viewed by the user in the
  last 48 hours, not in `exclude`, and not hard-off at confidence ≥ 0.5.
  """
  import Ecto.Query, warn: false

  alias TSpec.{Content, Repo, Social}
  alias TSpec.Content.{ContentTopic, Item}
  alias TSpec.Feed.{Settings, ViewEngagement}
  alias TSpec.Feed.Ranker
  alias TSpec.Feed.Ranker.Candidate

  @window_days 30
  @seen_hours 48
  @co_window_days 14
  @top_topics 5
  @limits %{
    following: 150,
    topic: 150,
    trending: 150,
    co_engagement: 100,
    explore: 50,
    fresh: 100
  }
  # Bayesian smoothing for completion rate: pretend every item starts with
  # @prior_views views at the @prior_rate completion rate.
  @prior_views 10
  @prior_rate 0.3

  @doc "Which sources run for these settings."
  def sources_for(%Settings{non_personalized: true}), do: ~w(following trending fresh)
  def sources_for(%Settings{}), do: ~w(following topic trending co_engagement explore fresh)

  @doc """
  Gathers candidates for `user_id`. `features.topic_affinity` (topic id =>
  value) steers the `topic` and `explore` sources. Options: `:exclude`
  (content ids, e.g. already served this session), `:now`, `:sources` (to
  run only some, e.g. a targeted refill), `:topic_slugs` (extra topics for
  the `topic` source).
  """
  def gather(user_id, %Settings{} = settings, features, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    sources = Keyword.get(opts, :sources, sources_for(settings))
    base = eligible(user_id, settings, Keyword.get(opts, :exclude, []), now)

    nominations =
      for source <- sources,
          source in sources_for(settings),
          id <- nominate(source, base, user_id, settings, features, now, opts) do
        {id, source}
      end

    nominations
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> hydrate(user_id)
  end

  ## Eligibility

  defp eligible(user_id, settings, exclude, now) do
    since = DateTime.add(now, -@window_days, :day)
    seen_since = DateTime.add(now, -@seen_hours, :hour)
    off_ids = hard_off_topic_ids(settings)

    query =
      from i in Item,
        as: :item,
        where: i.status == "ready" and i.visibility == "public",
        where: i.author_id != ^user_id and i.published_at > ^since,
        where: i.id not in ^exclude,
        where:
          i.id not in subquery(
            from v in ViewEngagement,
              where: v.user_id == ^user_id and v.inserted_at > ^seen_since,
              select: v.content_id
          )

    if off_ids == [] do
      query
    else
      threshold = Ranker.hard_off_threshold()

      where(
        query,
        [item: i],
        not exists(
          from ct in ContentTopic,
            where:
              ct.content_id == parent_as(:item).id and ct.topic_id in ^off_ids and
                ct.confidence >= ^threshold
        )
      )
    end
  end

  # Hard-off slugs and all their children, as topic ids.
  defp hard_off_topic_ids(settings) do
    off = MapSet.new(Settings.hard_off_slugs(settings))

    if off == MapSet.new() do
      []
    else
      taxonomy = Content.topics_by_id()

      for {id, t} <- taxonomy,
          MapSet.member?(off, t.slug) or
            (t.parent_id != nil and MapSet.member?(off, taxonomy[t.parent_id].slug)),
          do: id
    end
  end

  ## Sources

  defp nominate("following", base, user_id, _settings, _features, _now, _opts) do
    from(i in base,
      where: i.author_id in subquery(Social.followee_ids_query(user_id)),
      order_by: [desc: i.published_at, desc: i.id],
      limit: ^@limits.following,
      select: i.id
    )
    |> Repo.all()
  end

  defp nominate("topic", base, _user_id, settings, features, _now, opts) do
    by_slug = Content.topics_by_slug()

    top =
      features.topic_affinity
      |> Enum.filter(fn {_id, v} -> v > 0 end)
      |> Enum.sort_by(fn {id, v} -> {-v, id} end)
      |> Enum.take(@top_topics)
      |> Enum.map(&elem(&1, 0))

    boosted =
      (Settings.boosted_slugs(settings) ++ Keyword.get(opts, :topic_slugs, []))
      |> Enum.flat_map(&List.wrap(by_slug[&1] && by_slug[&1].id))

    case Enum.uniq(top ++ boosted) do
      [] ->
        []

      topic_ids ->
        from(i in base,
          where:
            exists(
              from ct in ContentTopic,
                where: ct.content_id == parent_as(:item).id and ct.topic_id in ^topic_ids
            ),
          order_by: [desc: i.published_at, desc: i.id],
          limit: ^@limits.topic,
          select: i.id
        )
        |> Repo.all()
    end
  end

  defp nominate("trending", base, _user_id, _settings, _features, _now, _opts) do
    from(i in base,
      join: t in "trending_scores",
      on: t.content_id == i.id,
      order_by: [desc: t.score, desc: i.id],
      limit: ^@limits.trending,
      select: i.id
    )
    |> Repo.all()
  end

  defp nominate("co_engagement", base, user_id, _settings, _features, now, _opts) do
    since = DateTime.add(now, -@co_window_days, :day)

    mine =
      from v in ViewEngagement,
        where: v.user_id == ^user_id and v.completed and v.inserted_at > ^since,
        order_by: [desc: v.inserted_at],
        limit: 50,
        select: v.content_id

    peers =
      from v in ViewEngagement,
        where: v.content_id in subquery(mine) and v.completed and v.user_id != ^user_id,
        where: v.inserted_at > ^since,
        distinct: true,
        limit: 200,
        select: v.user_id

    co =
      from v in ViewEngagement,
        where: v.user_id in subquery(peers) and v.completed and v.inserted_at > ^since,
        group_by: v.content_id,
        order_by: [desc: count(v.view_id), asc: v.content_id],
        limit: ^@limits.co_engagement,
        select: v.content_id

    from(i in base, where: i.id in subquery(co), select: i.id) |> Repo.all()
  end

  defp nominate("explore", base, _user_id, _settings, features, _now, _opts) do
    known = Map.keys(features.topic_affinity)

    from(i in base,
      where:
        exists(
          from ct in ContentTopic,
            where: ct.content_id == parent_as(:item).id and ct.topic_id not in ^known
        ),
      order_by: fragment("random()"),
      limit: ^@limits.explore,
      select: i.id
    )
    |> Repo.all()
  end

  defp nominate("fresh", base, _user_id, _settings, _features, _now, _opts) do
    from(i in base,
      order_by: [desc: i.published_at, desc: i.id],
      limit: ^@limits.fresh,
      select: i.id
    )
    |> Repo.all()
  end

  ## Hydration

  @doc false
  # %{content_id => [source]} -> [%Candidate{}]. Public for tests.
  def hydrate(sources_by_id, _user_id) when sources_by_id == %{}, do: []

  def hydrate(sources_by_id, user_id) do
    ids = Map.keys(sources_by_id)
    labels = labels(ids)
    quality = quality(ids)

    following = user_id |> Social.followee_ids_query() |> Repo.all() |> MapSet.new()

    from(i in Item, where: i.id in ^ids, select: {i.id, i.author_id, i.published_at})
    |> Repo.all()
    |> Enum.map(fn {id, author_id, published_at} ->
      %Candidate{
        content_id: id,
        author_id: author_id,
        published_at: published_at,
        sources: sources_by_id[id] |> Enum.uniq() |> Enum.sort(),
        labels: Map.get(labels, id, []),
        quality: Map.get(quality, id, @prior_rate),
        following: MapSet.member?(following, author_id)
      }
    end)
  end

  @doc false
  def labels(ids) do
    from(ct in ContentTopic,
      where: ct.content_id in ^ids,
      group_by: [ct.content_id, ct.topic_id],
      select:
        {ct.content_id,
         %{
           topic_id: ct.topic_id,
           confidence: max(ct.confidence),
           sources: fragment("array_agg(? ORDER BY ?)", ct.source, ct.source)
         }}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # Smoothed completion rate per item.
  defp quality(ids) do
    from(v in ViewEngagement,
      where: v.content_id in ^ids,
      group_by: v.content_id,
      select: {v.content_id, count(v.view_id), filter(count(v.view_id), v.completed)}
    )
    |> Repo.all()
    |> Map.new(fn {id, views, completed} ->
      {id, (completed + @prior_views * @prior_rate) / (views + @prior_views)}
    end)
  end

  @doc false
  def prior_rate, do: @prior_rate
end
