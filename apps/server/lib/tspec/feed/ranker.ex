defmodule TSpec.Feed.Ranker do
  @moduledoc """
  Ranker v1: a decomposable, explainable scorer (ADR 0006).

      final_score = Σ contribution,   contribution = weight × value

  Every scored item carries its `contributions` — the trace — and
  `final_score` is *defined* as their sum in list order, so a persisted trace
  sums back to the persisted score exactly. Pure: no database, no clock
  (`features.now` is passed in), deterministic for equal inputs.

  ## Features

    * `topic_affinity` (per topic label) — learned interest. Value is the
      squashed affinity at the label's topic (or half its parent's, if the
      user has no history with the topic itself) × label confidence.
      Weight `w × m`, where `m` is the user's slider for the topic.
    * `topic_preference` (per topic label, only when `m ≠ 1`) — the explicit
      part of the slider: value = label confidence, weight `w × (m − 1)`.
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

  A zero-valued learned feature is omitted rather than listed as 0, to keep
  explanations readable; it changes no sums.
  """

  alias TSpec.Feed.Ranker.Defaults
  alias TSpec.Feed.Settings

  @version "v1"
  @hard_off_threshold 0.5
  @diversity_depth 50
  @creator_window 5
  @topic_window 3

  def version, do: @version
  def hard_off_threshold, do: @hard_off_threshold

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
      sources: [],
      contributions: [],
      final_score: 0.0
    ]
  end

  @doc """
  Whether hard-off settings allow the item: no label at confidence ≥ 0.5 on a
  hard-off topic or on a child of one.
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
  into (−1, 1). `opts[:recent]` is the list of items already shown in this
  feed (oldest first, as `%{author_id, primary_topic}`), so diversity carries
  across pages and re-ranks.
  """
  def rank(candidates, features, %Settings{} = settings, taxonomy, opts \\ []) do
    recent = Keyword.get(opts, :recent, [])
    depth = Keyword.get(opts, :diversity_depth, @diversity_depth)

    scored =
      for c <- candidates, eligible?(c, settings, taxonomy) do
        score(c, features, settings, taxonomy)
      end

    {greedy, rest} = greedy(scored, recent, depth)
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

  defp topic_contributions(c, features, settings, taxonomy) do
    labels = Enum.sort_by(c.labels, &{-&1.confidence, taxonomy[&1.topic_id].slug})

    Enum.flat_map(labels, fn %{topic_id: id, confidence: conf} = label ->
      topic = taxonomy[id]
      parent = topic.parent_id && taxonomy[topic.parent_id]
      m = Settings.topic_multiplier(settings, topic.slug, parent && parent.slug)
      label_sources = Map.get(label, :sources, [])

      learned =
        if features.personalized do
          value = affinity_value(features.topic_affinity, topic, parent) * conf

          if value != 0.0,
            do: [
              contribution("topic_affinity", :topic_affinity, m, value,
                topic: topic.slug,
                label_sources: label_sources
              )
            ],
            else: []
        else
          []
        end

      explicit =
        if m != 1.0 do
          w = Defaults.feature(:topic_preference)

          [
            %{
              feature: "topic_preference",
              topic: topic.slug,
              label_sources: label_sources,
              default_weight: w,
              user_multiplier: m,
              weight: z(w * (m - 1.0)),
              value: z(conf / 1),
              contribution: z(w * (m - 1.0) * conf)
            }
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

  defp best_source(%Candidate{sources: sources}, settings) do
    sources
    |> Enum.map(&{&1, Settings.source_multiplier(settings, &1)})
    |> Enum.max_by(fn {s, m} -> {Defaults.source_prior(s) * m, s} end)
  end

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
  defp greedy(scored, recent, depth) do
    window = Enum.map(recent, &{&1.author_id, &1.primary_topic})
    do_greedy(scored, Enum.reverse(window), depth, [])
  end

  defp do_greedy(rest, _window, 0, picked), do: {Enum.reverse(picked), rest}
  defp do_greedy([], _window, _n, picked), do: {Enum.reverse(picked), []}

  defp do_greedy(rest, window, n, picked) do
    {best, penalty} =
      rest
      |> Enum.map(&{&1, diversity_value(&1, window)})
      |> Enum.max_by(fn {s, p} ->
        {s.final_score + Defaults.feature(:diversity) * p, invert(s.content_id)}
      end)

    best = with_diversity(best, penalty)
    window = [{best.author_id, best.primary_topic} | window]

    do_greedy(List.delete(rest, elem_by_id(rest, best.content_id)), window, n - 1, [best | picked])
  end

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
