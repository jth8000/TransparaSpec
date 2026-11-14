defmodule TSpec.Feed.Candidates do
  @moduledoc """
  Candidate generation, SQL v1 (ADR 0011): cheap queries that each nominate
  plausible items, labeled with the source that found them. The ranker then
  orders the union precisely.

  | Source          | Nominates                                                    |
  |-----------------|--------------------------------------------------------------|
  | `following`     | recent items from accounts the user follows                  |
  | `topic`         | recent items in the user's top affinity topics; and, with a  |
  |                 | budget per topic, every boosted topic and `:topic_slugs`     |
  |                 | (subtopics included)                                         |
  | `trending`      | the global trending pool (`TSpec.Feed.TrendingWorker`)       |
  | `co_engagement` | items completed by people who completed what you completed   |
  | `explore`       | random recent items whose topics are all new to you          |
  | `fresh`         | the newest public items                                      |

  Non-personalized mode uses only `following`, `trending` and `fresh`: no
  source that reads the user's inferred profile or viewing history
  (ADR 0012). With the Explore slider at 0, `explore` doesn't run either
  (ADR 0015).

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
  # The `topic` source's budget for topics asked for explicitly (boosted,
  # or targeted by a refill): each gets 150 / n but at least 50, and all of
  # them together about 300 at most. Nothing limits how many topics a user
  # can boost, so the total must be capped (threat-model.md).
  @explicit_per_topic_min 50
  @explicit_total_max 300
  # Bayesian smoothing for completion rate: pretend every item starts with
  # @prior_views views at the @prior_rate completion rate.
  @prior_views 10
  @prior_rate 0.3

  @doc "Which sources run for these settings."
  def sources_for(%Settings{non_personalized: true}), do: ~w(following trending fresh)

  def sources_for(%Settings{} = settings) do
    all = ~w(following topic trending co_engagement explore fresh)
    if Ranker.explore_every(settings), do: all, else: all -- ["explore"]
  end

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

  @doc """
  The user's top learned topics, which the `topic` source draws from: the
  #{@top_topics} with the highest positive value (ties by id).
  """
  def top_topic_ids(features) do
    features.topic_affinity
    |> Enum.filter(fn {_id, v} -> v > 0 end)
    |> Enum.sort_by(fn {id, v} -> {-v, id} end)
    |> Enum.take(@top_topics)
    |> Enum.map(&elem(&1, 0))
  end

  defp nominate("following", base, user_id, _settings, _features, _now, _opts) do
    from(i in base,
      where: i.author_id in subquery(Social.followee_ids_query(user_id)),
      order_by: [desc: i.published_at, desc: i.id],
      limit: ^@limits.following,
      select: i.id
    )
    |> Repo.all()
  end

  # The user's top learned topics, newest first; and, separately, the topics
  # asked for explicitly (boosted, or `:topic_slugs` from a targeted
  # refill), each with a budget of its own: a big topic, learned or
  # boosted, can't crowd out a small one a refill was for. Explicit topics
  # include their subtopics, as sliders do.
  defp nominate("topic", base, _user_id, settings, features, _now, opts) do
    taxonomy = Content.topics_by_id()
    by_slug = Content.topics_by_slug()

    requested =
      (Settings.boosted_slugs(settings) ++ Keyword.get(opts, :topic_slugs, []))
      |> Enum.flat_map(&List.wrap(by_slug[&1] && by_slug[&1].id))
      |> MapSet.new()

    # Label topic => the requested topic it counts for (itself, or its
    # parent). A subtopic requested along with its parent counts for itself.
    groups =
      for {id, t} <- taxonomy,
          MapSet.member?(requested, id) or MapSet.member?(requested, t.parent_id),
          into: %{},
          do: {id, if(MapSet.member?(requested, id), do: id, else: t.parent_id)}

    Enum.uniq(
      topic_query(base, top_topic_ids(features)) ++ per_topic_query(base, groups, requested)
    )
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

  # Collaborative: uses individual viewing histories, so only views whose
  # owner allowed personal use (`learnable`) count — on either side. A view
  # watched in non-personalized mode never recommends anything to anyone
  # (ADR 0012). Items rank by how many distinct peers completed them, so one
  # account can't push an item by itself.
  defp nominate("co_engagement", base, user_id, _settings, _features, now, _opts) do
    since = DateTime.add(now, -@co_window_days, :day)

    mine =
      from v in ViewEngagement,
        where: v.user_id == ^user_id and v.completed and v.learnable and v.inserted_at > ^since,
        order_by: [desc: v.inserted_at],
        limit: 50,
        select: v.content_id

    peers =
      from v in ViewEngagement,
        where: v.content_id in subquery(mine) and v.completed and v.learnable,
        where: v.user_id != ^user_id and v.inserted_at > ^since,
        distinct: true,
        limit: 200,
        select: v.user_id

    co =
      from v in ViewEngagement,
        where: v.user_id in subquery(peers) and v.completed and v.learnable,
        where: v.inserted_at > ^since,
        group_by: v.content_id,
        order_by: [desc: count(v.user_id, :distinct), asc: v.content_id],
        limit: ^@limits.co_engagement,
        select: v.content_id

    from(i in base, where: i.id in subquery(co), select: i.id) |> Repo.all()
  end

  # Items with at least one label and none on a topic the user knows (or
  # under one): the same rule as the ranker's explore slots
  # (`Ranker.explore_blocked_topic_ids/3`).
  defp nominate("explore", base, _user_id, settings, features, _now, _opts) do
    blocked =
      features
      |> Ranker.explore_blocked_topic_ids(settings, Content.topics_by_id())
      |> MapSet.to_list()

    from(i in base,
      where: exists(from ct in ContentTopic, where: ct.content_id == parent_as(:item).id),
      where:
        not exists(
          from ct in ContentTopic,
            where: ct.content_id == parent_as(:item).id and ct.topic_id in ^blocked
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

  defp topic_query(_base, []), do: []

  defp topic_query(base, topic_ids) do
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

  # The newest items for each requested topic, in one query: `row_number()`
  # over a window partitioned by requested topic numbers each topic's items
  # newest first, and the outer query keeps the first `explicit_per_topic/1`
  # of each.
  defp per_topic_query(_base, groups, _requested) when groups == %{}, do: []

  defp per_topic_query(base, groups, requested) do
    per_topic = explicit_per_topic(MapSet.size(requested))
    {label_ids, group_ids} = Enum.unzip(groups)

    ranked =
      from(i in base,
        join: ct in ContentTopic,
        on: ct.content_id == i.id,
        join:
          g in fragment(
            "SELECT * FROM unnest(?::uuid[], ?::uuid[]) AS g(label_id, group_id)",
            type(^label_ids, {:array, Ecto.UUID}),
            type(^group_ids, {:array, Ecto.UUID})
          ),
        on: g.label_id == ct.topic_id,
        windows: [
          per_topic: [partition_by: g.group_id, order_by: [desc: i.published_at, desc: i.id]]
        ],
        select: %{id: i.id, rank: over(row_number(), :per_topic)}
      )

    from(r in subquery(ranked), where: r.rank <= ^per_topic, distinct: true, select: r.id)
    |> Repo.all()
  end

  @doc """
  Items per explicitly requested topic, for `n` such topics: 150, 75 and 50
  for one to three, 50 each up to six, then shrinking so the total stays
  about #{@explicit_total_max} (never under one each).

      iex> Enum.map([1, 2, 3, 6, 7, 10, 400], &TSpec.Feed.Candidates.explicit_per_topic/1)
      [150, 75, 50, 50, 42, 30, 1]
  """
  def explicit_per_topic(n) when n > 0 do
    min(
      max(@explicit_per_topic_min, div(@limits.topic, n)),
      max(1, div(@explicit_total_max, n))
    )
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

  # Smoothed completion rate per item, over distinct viewers: replaying an
  # item (or fabricating views) from one account counts once. Aggregate, so
  # every view counts regardless of personalization mode (ADR 0012).
  #
  # Only views with a duration count. A text post has nothing to finish, so
  # its views would all count as non-completions and its quality would sink
  # toward 0 the more people read it; leaving them out keeps text posts at
  # the prior.
  defp quality(ids) do
    from(v in ViewEngagement,
      where: v.content_id in ^ids and v.duration_ms > 0,
      group_by: v.content_id,
      select:
        {v.content_id, count(v.user_id, :distinct),
         fragment("count(DISTINCT ?) FILTER (WHERE ?)", v.user_id, v.completed)}
    )
    |> Repo.all()
    |> Map.new(fn {id, viewers, completers} ->
      {id, (completers + @prior_views * @prior_rate) / (viewers + @prior_views)}
    end)
  end

  @doc false
  def prior_rate, do: @prior_rate

  @doc false
  def prior_views, do: @prior_views
end
