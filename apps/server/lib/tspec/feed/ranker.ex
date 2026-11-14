defmodule TSpec.Feed.Ranker do
  @moduledoc """
  Ranker v1.2: a decomposable, explainable scorer (ADR 0006).

      final_score = Σ contribution,   contribution = weight × value

  Every scored item carries its `contributions` — the trace — and
  `final_score` is *defined* as their sum in list order, so a persisted trace
  sums back to the persisted score exactly. Pure: no database, no clock
  (`features.now` is passed in), deterministic for equal inputs.

  ## Features

    * `topic_affinity` (per topic label) — learned interest. Value is the
      squashed affinity at the label's topic (or half its parent's, if the
      user has no history with the topic itself) × the label's share of the
      item (`TSpec.Feed.LabelShares`: confidence / max(1, Σ confidences)).
      Weight `w × m`, where `m` is the user's slider for the topic.
    * `topic_preference` (per topic label, only when `m ≠ 1`) — the explicit
      part of the slider: value = the label's share, weight `w × (m − 1)`.
      Moving a slider up always raises the topic's score (see `Defaults`).
    * `creator_affinity` — learned interest in the creator.
    * `following` — 1 if the viewer follows the creator (an explicit choice).
    * `source_prior` — 1, weighted by the best candidate source the item came
      from, times the user's source multiplier.
    * `freshness` — `0.5^(age_hours / 24)`.
    * `quality` — the item's smoothed completion rate.
    * `diversity` — added while ordering: −1 per same-creator item among the
      previous 5 picks, −0.5 per same-primary-topic item among the previous 3.

  In non-personalized mode `topic_affinity` and `creator_affinity` are left
  out entirely; explicit settings still apply (ADR 0012).

  ## Explore slots (ADR 0015)

  Every `explore_every/1`-th position of the feed (counted across the whole
  session, from `opts[:start_position]`) is reserved for the best
  *explorable* item: one whose topics are all new to the user. The slot is
  filled inside the greedy diversity pass, so the diversity window sees it.
  A slot changes where an item goes, never its score: the item is marked
  `placement: "explore"` and its trace still sums to its score. With no
  explorable item left, the slot is filled normally.

  A zero-valued learned feature is omitted rather than listed as 0, to keep
  explanations readable; it changes no sums.
  """

  alias TSpec.Feed.LabelShares
  alias TSpec.Feed.Ranker.Defaults
  alias TSpec.Feed.Settings

  @version "v1.2"
  @hard_off_threshold 0.5
  @diversity_depth 50
  @creator_window 5
  @topic_window 3
  # One explore slot per @explore_every positions at the Explore slider's
  # default (1×); the slider scales the rate.
  @explore_every 10
  # A topic counts as known (not explorable) while its learned value is at
  # least this far from 0, either way. One finished view fades below it in
  # about five weeks.
  @explore_known_value 0.05

  def version, do: @version
  def hard_off_threshold, do: @hard_off_threshold
  def explore_known_value, do: @explore_known_value

  defmodule Candidate do
    @moduledoc """
    An item the candidate sources found, with the raw facts the ranker needs.
    `labels` are effective topic labels: `%{topic_id, confidence, sources}`.
    """
    @enforce_keys [:content_id, :author_id, :published_at]
    defstruct [
      :content_id,
      :author_id,
      :published_at,
      sources: [],
      labels: [],
      quality: 0.0,
      following: false
    ]
  end

  defmodule Scored do
    @moduledoc "A ranked item and its trace."
    defstruct [
      :content_id,
      :author_id,
      :candidate_source,
      :primary_topic,
      # "explore" when an explore slot placed the item (ADR 0015).
      :placement,
      explorable: false,
      sources: [],
      contributions: [],
      final_score: 0.0
    ]
  end

  @doc """
  The spacing of explore slots: every `round(10 / m)`-th position, where `m`
  is the Explore slider, or `nil` (no slots) at 0 and in non-personalized
  mode.

      iex> TSpec.Feed.Ranker.explore_every(%TSpec.Feed.Settings{})
      10
      iex> TSpec.Feed.Ranker.explore_every(%TSpec.Feed.Settings{sources: %{"explore" => 2.0}})
      5
      iex> TSpec.Feed.Ranker.explore_every(%TSpec.Feed.Settings{sources: %{"explore" => 0.0}})
      nil
  """
  def explore_every(%Settings{non_personalized: true}), do: nil

  def explore_every(%Settings{} = settings) do
    case Settings.source_multiplier(settings, "explore") do
      m when m <= 0.0 -> nil
      m -> max(round(@explore_every / m), 1)
    end
  end

  @doc """
  Topic ids that make an item *not* explorable: topics the user knows (a
  learned value at least `explore_known_value/0` from 0, a recent forget,
  or a slider moved off 1×), and the children of each. An item is
  explorable when none of its labels is in this set.

  `features.known_topic_ids` holds the user's known topics by history (see
  `TSpec.Feed.Ranking.features/3`); without it, they're read off
  `features.topic_affinity`.
  """
  def explore_blocked_topic_ids(features, %Settings{} = settings, taxonomy) do
    by_history =
      Map.get_lazy(features, :known_topic_ids, fn ->
        for {id, v} <- features.topic_affinity,
            abs(v) >= @explore_known_value,
            into: MapSet.new(),
            do: id
      end)

    by_slider =
      taxonomy
      |> Enum.filter(fn {_id, t} ->
        parent_slug = t.parent_id && taxonomy[t.parent_id].slug
        Settings.topic_multiplier(settings, t.slug, parent_slug) != 1.0
      end)
      |> MapSet.new(&elem(&1, 0))

    known = MapSet.union(MapSet.new(by_history), by_slider)

    for {id, t} <- taxonomy,
        MapSet.member?(known, id) or (t.parent_id != nil and MapSet.member?(known, t.parent_id)),
        into: MapSet.new(),
        do: id
  end

  @doc "Whether an item is explorable: it has labels, and none is blocked."
  def explorable?(%Candidate{labels: []}, _blocked), do: false

  def explorable?(%Candidate{labels: labels}, blocked),
    do: not Enum.any?(labels, &MapSet.member?(blocked, &1.topic_id))

  @doc """
  Whether hard-off settings allow the item: no label at confidence ≥ 0.5 on a
  hard-off topic or on a child of one. Raw confidence, never the label's
  share: three labels at 1.0 have a share of ⅓ each, and a switched-off
  topic must not slip under the threshold that way.
  """
  def eligible?(%Candidate{labels: labels}, %Settings{} = settings, taxonomy) do
    off = MapSet.new(Settings.hard_off_slugs(settings))

    off == MapSet.new() or
      not Enum.any?(labels, fn %{topic_id: id, confidence: c} ->
        c >= @hard_off_threshold and blocked?(taxonomy[id], off, taxonomy)
      end)
  end

  defp blocked?(nil, _off, _taxonomy), do: false

  defp blocked?(topic, off, taxonomy) do
    MapSet.member?(off, topic.slug) or
      (topic.parent_id != nil and MapSet.member?(off, taxonomy[topic.parent_id].slug))
  end

  @doc """
  Scores, filters and orders candidates. Returns `[%Scored{}]` best first.

  `features` is `%{now, personalized, topic_affinity: %{topic_id => value},
  creator_affinity: %{creator_id => value}}` with values already squashed
  into (−1, 1), plus optionally `known_topic_ids` (see
  `explore_blocked_topic_ids/3`). Options:

    * `:recent` — the items already sent in this feed (oldest first, as
      `%{author_id, primary_topic}`), so diversity carries across pages and
      re-ranks.
    * `:start_position` — the feed position of the first item returned, so
      explore slots fall at the same positions across pages and re-ranks.
      Defaults to `length(recent)`.
  """
  def rank(candidates, features, %Settings{} = settings, taxonomy, opts \\ []) do
    recent = Keyword.get(opts, :recent, [])
    depth = Keyword.get(opts, :diversity_depth, @diversity_depth)
    start = Keyword.get(opts, :start_position, length(recent))

    explorable? =
      if features.personalized and explore_every(settings) do
        blocked = explore_blocked_topic_ids(features, settings, taxonomy)
        &explorable?(&1, blocked)
      else
        fn _ -> false end
      end

    scored =
      for c <- candidates, eligible?(c, settings, taxonomy) do
        %{score(c, features, settings, taxonomy) | explorable: explorable?.(c)}
      end

    {greedy, rest} = greedy(scored, recent, depth, {start, explore_every(settings)})
    greedy ++ Enum.sort_by(rest, &{-&1.final_score, &1.content_id})
  end

  @doc "Scores one candidate (everything except diversity, which depends on order)."
  def score(%Candidate{} = c, features, %Settings{} = settings, taxonomy) do
    contributions =
      topic_contributions(c, features, settings, taxonomy) ++
        creator_contributions(c, features) ++
        [source_contribution(c, settings), freshness(c, features.now), quality(c)]

    {source, _} = best_source(c, settings)

    %Scored{
      content_id: c.content_id,
      author_id: c.author_id,
      candidate_source: source,
      sources: Enum.sort(c.sources),
      primary_topic: primary_topic(c, taxonomy),
      contributions: contributions,
      final_score: sum(contributions)
    }
  end

  # Traces are stored as jsonb, whose numbers are decimals with no negative
  # zero. Normalizing -0.0 to 0.0 up front keeps a stored trace bit-identical
  # to the one that was ranked.
  defp z(x), do: x + 0.0

  @doc "The defining sum: contributions added in list order."
  def sum(contributions), do: Enum.reduce(contributions, 0.0, &(&1.contribution + &2))

  # One `topic_affinity` (and, off the default slider, one `topic_preference`)
  # row per label, each scaled by the label's share of the item
  # (`LabelShares`), so labels split the item's topic signal rather than
  # adding up.
  defp topic_contributions(c, features, settings, taxonomy) do
    labels = Enum.sort_by(c.labels, &{-&1.confidence, taxonomy[&1.topic_id].slug})
    shares = LabelShares.shares(Enum.map(labels, &{&1.topic_id, &1.confidence}))

    Enum.flat_map(labels, fn %{topic_id: id, confidence: conf} = label ->
      topic = taxonomy[id]
      parent = topic.parent_id && taxonomy[topic.parent_id]
      m = Settings.topic_multiplier(settings, topic.slug, parent && parent.slug)
      share = shares[id]

      trace = [
        topic: topic.slug,
        label_sources: Map.get(label, :sources, []),
        confidence: z(conf / 1),
        label_share: z(share)
      ]

      learned =
        if features.personalized do
          value = affinity_value(features.topic_affinity, topic, parent) * share

          if value != 0.0,
            do: [contribution("topic_affinity", :topic_affinity, m, value, trace)],
            else: []
        else
          []
        end

      explicit =
        if m != 1.0 do
          w = Defaults.feature(:topic_preference)

          [
            Map.merge(
              %{
                feature: "topic_preference",
                default_weight: w,
                user_multiplier: m,
                weight: z(w * (m - 1.0)),
                value: z(share),
                contribution: z(w * (m - 1.0) * share)
              },
              Map.new(trace)
            )
          ]
        else
          []
        end

      learned ++ explicit
    end)
  end

  # The topic's own affinity, or half its parent's when there's no history
  # with the topic itself.
  defp affinity_value(affinities, topic, parent) do
    case {Map.fetch(affinities, topic.id), parent && Map.fetch(affinities, parent.id)} do
      {{:ok, v}, _} -> v
      {:error, {:ok, v}} -> 0.5 * v
      _ -> 0.0
    end
  end

  defp creator_contributions(c, features) do
    learned =
      with true <- features.personalized,
           {:ok, v} when v != 0.0 <- Map.fetch(features.creator_affinity, c.author_id) do
        [contribution("creator_affinity", :creator_affinity, 1.0, v)]
      else
        _ -> []
      end

    following = if c.following, do: [contribution("following", :following, 1.0, 1.0)], else: []
    learned ++ following
  end

  defp source_contribution(c, settings) do
    {source, m} = best_source(c, settings)
    w = Defaults.source_prior(source)

    %{
      feature: "source_prior",
      source: source,
      default_weight: w,
      user_multiplier: m,
      weight: z(w * m),
      value: 1.0,
      contribution: z(w * m * 1.0)
    }
  end

  # The Explore slider sets how often explore slots come up, not the explore
  # source's prior (ADR 0015), so that source's multiplier is always 1.
  defp best_source(%Candidate{sources: sources}, settings) do
    sources
    |> Enum.map(&{&1, prior_multiplier(settings, &1)})
    |> Enum.max_by(fn {s, m} -> {Defaults.source_prior(s) * m, s} end)
  end

  defp prior_multiplier(_settings, "explore"), do: 1.0
  defp prior_multiplier(settings, source), do: Settings.source_multiplier(settings, source)

  defp freshness(c, now) do
    hours = max(DateTime.diff(now, c.published_at, :second), 0) / 3600
    contribution("freshness", :freshness, 1.0, :math.pow(0.5, hours / 24))
  end

  defp quality(c), do: contribution("quality", :quality, 1.0, c.quality / 1)

  defp contribution(feature, key, multiplier, value, extra \\ []) do
    w = Defaults.feature(key)

    Map.merge(
      %{
        feature: feature,
        default_weight: w,
        user_multiplier: multiplier,
        weight: z(w * multiplier),
        value: z(value),
        contribution: z(w * multiplier * value)
      },
      Map.new(extra)
    )
  end

  # The highest-confidence label's slug (ties by slug), for diversity.
  defp primary_topic(%Candidate{labels: []}, _taxonomy), do: nil

  defp primary_topic(%Candidate{labels: labels}, taxonomy) do
    labels
    |> Enum.map(&{&1.confidence, taxonomy[&1.topic_id].slug})
    |> Enum.min_by(fn {conf, slug} -> {-conf, slug} end)
    |> elem(1)
  end

  ## Diversity re-rank

  # Picks the best item one at a time, penalizing repeats of a recently
  # shown creator or primary topic. The penalty is part of the item's trace.
  # At an explore slot only explorable items compete (if there are any).
  defp greedy(scored, recent, depth, slots) do
    window = Enum.map(recent, &{&1.author_id, &1.primary_topic})
    do_greedy(scored, Enum.reverse(window), depth, slots, [])
  end

  defp do_greedy(rest, _window, 0, _slots, picked), do: {Enum.reverse(picked), rest}
  defp do_greedy([], _window, _n, _slots, picked), do: {Enum.reverse(picked), []}

  defp do_greedy(rest, window, n, {position, every}, picked) do
    explore_pool = if explore_slot?(position, every), do: Enum.filter(rest, & &1.explorable)
    pool = if explore_pool in [nil, []], do: rest, else: explore_pool

    {best, penalty} =
      pool
      |> Enum.map(&{&1, diversity_value(&1, window)})
      |> Enum.max_by(fn {s, p} ->
        {s.final_score + Defaults.feature(:diversity) * p, invert(s.content_id)}
      end)

    best = with_diversity(best, penalty)
    best = if pool == explore_pool, do: %{best | placement: "explore"}, else: best
    window = [{best.author_id, best.primary_topic} | window]
    rest = List.delete(rest, elem_by_id(rest, best.content_id))

    do_greedy(rest, window, n - 1, {position + 1, every}, [best | picked])
  end

  # Positions are 0-based, so with every = 10 the slots are the 10th, 20th, ...
  defp explore_slot?(_position, nil), do: false
  defp explore_slot?(position, every), do: rem(position + 1, every) == 0

  defp elem_by_id(list, id), do: Enum.find(list, &(&1.content_id == id))

  # Ties go to the smaller content id (max_by picks the largest key).
  defp invert(id), do: Enum.map(:binary.bin_to_list(id), &(-&1))

  defp diversity_value(%Scored{author_id: author, primary_topic: topic}, window) do
    same_creator =
      window |> Enum.take(@creator_window) |> Enum.count(fn {a, _} -> a == author end)

    same_topic =
      if topic,
        do: window |> Enum.take(@topic_window) |> Enum.count(fn {_, t} -> t == topic end),
        else: 0

    -1.0 * same_creator - 0.5 * same_topic
  end

  defp with_diversity(scored, penalty) when penalty == 0.0, do: scored

  defp with_diversity(%Scored{} = s, penalty) do
    contributions = s.contributions ++ [contribution("diversity", :diversity, 1.0, penalty)]
    %{s | contributions: contributions, final_score: sum(contributions)}
  end
end
