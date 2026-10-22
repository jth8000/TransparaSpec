defmodule TSpec.Feed.Session do
  @moduledoc """
  One client's For You feed (ADR 0011). A *cache*, not a source of truth:

    * holds ~500 scored-ready candidates, the items it has served (in client
      order), the client's current position and a revision counter `rev`
    * serves pages and writes an impression for every item it sends
    * when the user's settings change (any device), re-ranks everything
      *after* the client's position, writes impressions for the new page and
      pushes it as `{:feed_reranked, ...}` — the item being watched is never
      taken away
    * refills its cache in the background when filters drain it or a newly
      boosted topic is missing, and merges the result only if the settings
      haven't changed since the refill started

  "Already seen" lives in Postgres (views/impressions), so losing this
  process — idle timeout, crash, another node — costs a rebuild, never
  correctness. One process per `{user_id, session_id}`; a user's phone and
  browser rank independently but share settings.

  Pushes go to `"feed_session:<user_id>:<session_id>"` on `TSpec.PubSub`
  (the channel relays them); the user id in the topic keeps one user's
  session pushes away from anyone else.
  """
  use GenServer, restart: :temporary

  alias TSpec.{Content, Transparency}
  alias TSpec.Accounts.Scope
  alias TSpec.Feed.{Candidates, Ranker, Ranking, Settings}

  @page_size 10
  @idle_ms :timer.minutes(10)
  @refill_below 30
  @boost_min 5

  defstruct [
    :scope,
    :id,
    :settings,
    :features,
    :gather,
    cache: %{},
    served: [],
    position: -1,
    rev: 0,
    refilling: nil
  ]

  ## API

  @doc """
  The session's process, started if needed. Options (tests): `:gather` — a
  `Candidates.gather/4`-compatible function.
  """
  def ensure(%Scope{} = scope, session_id, opts \\ []), do: ensure(scope, session_id, opts, 20)

  # A process that just died can linger in the Registry for a moment (it's
  # cleaned up asynchronously), so don't hand out a dead pid: retry briefly.
  defp ensure(scope, session_id, opts, tries) do
    result =
      case Registry.lookup(TSpec.Feed.SessionRegistry, {scope.user.id, session_id}) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          case DynamicSupervisor.start_child(
                 TSpec.Feed.SessionSupervisor,
                 {__MODULE__, {scope, session_id, opts}}
               ) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            error -> error
          end
      end

    case result do
      {:ok, pid} when tries > 0 ->
        if Process.alive?(pid) do
          result
        else
          Process.sleep(5)
          ensure(scope, session_id, opts, tries - 1)
        end

      other ->
        other
    end
  end

  def start_link({%Scope{} = scope, session_id, opts}) do
    GenServer.start_link(__MODULE__, {scope, session_id, opts},
      name: via(scope.user.id, session_id)
    )
  end

  defp via(user_id, session_id),
    do: {:via, Registry, {TSpec.Feed.SessionRegistry, {user_id, session_id}}}

  @doc "The PubSub topic a session's pushes go to."
  def topic(user_id, session_id), do: "feed_session:#{user_id}:#{session_id}"

  @doc "Ranks and serves the next page: `{:ok, %{rev, items: [{%Scored{}, impression_id}]}}`."
  def next_page(pid, limit \\ @page_size), do: GenServer.call(pid, {:next_page, limit}, 15_000)

  @doc "The client's current item. Ignored unless `rev` is the session's current one."
  def at(pid, impression_id, rev), do: GenServer.cast(pid, {:at, impression_id, rev})

  @doc false
  def state(pid), do: :sys.get_state(pid)

  ## Lifecycle

  @impl true
  def init({scope, session_id, opts}) do
    :ok = Transparency.subscribe_settings(scope.user.id)
    settings = Transparency.get_settings(scope.user.id)

    state = %__MODULE__{
      scope: scope,
      id: session_id,
      settings: settings,
      gather: Keyword.get(opts, :gather, &Candidates.gather/4)
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    features = Ranking.features(state.scope.user.id, state.settings)
    candidates = state.gather.(state.scope.user.id, state.settings, features, [])

    {:noreply, %{state | features: features, cache: Map.new(candidates, &{&1.content_id, &1})},
     @idle_ms}
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  # A newer settings version (from any device): re-rank the tail.
  def handle_info({:settings_changed, %Settings{version: v} = settings}, state)
      when v > state.settings.version do
    state = %{
      state
      | settings: settings,
        features: Ranking.features(state.scope.user.id, settings)
    }

    state = state |> rerank_tail() |> maybe_refill(:settings_changed)
    {:noreply, state, @idle_ms}
  end

  def handle_info({:settings_changed, _stale}, state), do: {:noreply, state, @idle_ms}

  # A refill for the settings still in force: merge, and push if the tail changed.
  def handle_info({:refill, version, candidates}, %{settings: %{version: version}} = state) do
    new = Enum.reject(candidates, &Map.has_key?(state.cache, &1.content_id))
    state = %{state | cache: Map.merge(state.cache, Map.new(new, &{&1.content_id, &1}))}

    # Push only if the refill brought something new that would change the
    # client's tail — re-ranked, or topped up to a full page when filters
    # left it short.
    tail_ids = Enum.map(tail(state), & &1.content_id)
    kept = Enum.take(state.served, kept_count(state))

    would_be =
      %{state | served: kept}
      |> next_items(max(length(tail_ids), @page_size))
      |> Enum.map(& &1.content_id)

    state = if new != [] and would_be != tail_ids, do: rerank_tail(state), else: state
    {:noreply, state, @idle_ms}
  end

  # A refill started under older settings: discard it. (The settings change
  # that made it stale started its own refill if one was needed.)
  def handle_info({:refill, _stale_version, _candidates}, state), do: {:noreply, state, @idle_ms}

  ## Calls

  @impl true
  def handle_call({:next_page, limit}, _from, state) do
    page = next_items(state, limit)
    {pairs, state} = serve(state, page)
    state = maybe_refill(state, :page)
    {:reply, {:ok, %{rev: state.rev, items: pairs}}, state, @idle_ms}
  end

  @impl true
  def handle_cast({:at, impression_id, rev}, %{rev: rev} = state) do
    case Enum.find_index(state.served, &(&1.impression_id == impression_id)) do
      nil -> {:noreply, state, @idle_ms}
      index -> {:noreply, %{state | position: index}, @idle_ms}
    end
  end

  def handle_cast({:at, _impression_id, _stale_rev}, state), do: {:noreply, state, @idle_ms}

  ## Ranking

  # The best `limit` unserved candidates, with diversity continuing from
  # what's already been served.
  defp next_items(state, limit) do
    served_ids = MapSet.new(state.served, & &1.content_id)

    state.cache
    |> Map.values()
    |> Enum.reject(&MapSet.member?(served_ids, &1.content_id))
    |> Ranker.rank(state.features, state.settings, Content.topics_by_id(), recent: state.served)
    |> Enum.take(limit)
  end

  # Items sent after the client's current position.
  defp tail(state), do: Enum.drop(state.served, kept_count(state))

  # Everything up to and including the client's position stays. Before the
  # client reports a position, assume it's on the first item.
  defp kept_count(%{served: []}), do: 0
  defp kept_count(%{position: p}), do: max(p, 0) + 1

  defp rerank_tail(state) do
    kept = Enum.take(state.served, kept_count(state))
    state = %{state | served: kept, rev: state.rev + 1}
    {pairs, state} = serve(state, next_items(state, @page_size))

    Phoenix.PubSub.broadcast(
      TSpec.PubSub,
      topic(state.scope.user.id, state.id),
      {:feed_reranked,
       %{
         session_id: state.id,
         rev: state.rev,
         after_impression_id: kept |> List.last() |> then(&(&1 && &1.impression_id)),
         items: pairs
       }}
    )

    state
  end

  # Writes impressions for `scored` and appends them to the served list.
  defp serve(state, []), do: {[], state}

  defp serve(state, scored) do
    {:ok, pairs} =
      Ranking.serve(state.scope, scored, %{
        feed_session_id: state.id,
        rev: state.rev,
        start_position: length(state.served),
        settings: state.settings
      })

    served =
      for {s, impression_id} <- pairs do
        %{
          content_id: s.content_id,
          impression_id: impression_id,
          author_id: s.author_id,
          primary_topic: s.primary_topic
        }
      end

    {pairs, %{state | served: state.served ++ served}}
  end

  ## Refill

  # Refills run in the background, tagged with the settings version they
  # ran under. A newer version may always start its own; results for an
  # older one are discarded on arrival. On a settings change, every boosted
  # topic that's barely in the cache gets a targeted query.
  defp maybe_refill(%{refilling: version, settings: %{version: version}} = state, :page),
    do: state

  defp maybe_refill(state, reason) do
    missing =
      if reason == :settings_changed,
        do:
          Enum.filter(
            Settings.boosted_slugs(state.settings),
            &(cached_with_topic(state, &1) < @boost_min)
          ),
        else: []

    if unserved_eligible(state) < @refill_below or missing != [] do
      start_refill(state, missing)
    else
      state
    end
  end

  defp unserved_eligible(state) do
    served_ids = MapSet.new(state.served, & &1.content_id)
    taxonomy = Content.topics_by_id()

    Enum.count(state.cache, fn {id, c} ->
      not MapSet.member?(served_ids, id) and Ranker.eligible?(c, state.settings, taxonomy)
    end)
  end

  defp cached_with_topic(state, slug) do
    taxonomy = Content.topics_by_id()

    Enum.count(state.cache, fn {_id, c} ->
      Enum.any?(c.labels, fn %{topic_id: id} ->
        t = taxonomy[id]
        t.slug == slug or (t.parent_id != nil and taxonomy[t.parent_id].slug == slug)
      end)
    end)
  end

  defp start_refill(state, topic_slugs) do
    %{scope: scope, settings: settings, features: features, gather: gather} = state
    pid = self()
    exclude = Map.keys(state.cache)

    {:ok, _} =
      Task.Supervisor.start_child(TSpec.TaskSupervisor, fn ->
        candidates =
          gather.(scope.user.id, settings, features,
            exclude: exclude,
            topic_slugs: topic_slugs,
            refill: true
          )

        send(pid, {:refill, settings.version, candidates})
      end)

    %{state | refilling: settings.version}
  end
end
