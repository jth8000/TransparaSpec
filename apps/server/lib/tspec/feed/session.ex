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

  One process per `{user_id, session_id}` **cluster-wide**: it's registered
  with `:global`, so a request that lands on another node reaches the same
  process instead of starting a second one. A user's phone and browser rank
  independently but share settings.

  The process is a cache. When it starts — first use, or after an idle
  timeout, crash or deploy — it rebuilds the client's list, `rev` and
  position from the session's stored impressions and exposures, so it never
  re-serves what the client already has and the client's revision stays
  valid. A client that reports a higher `rev` than the process knows (an
  empty re-rank leaves no impressions) is adopted.

  Pushes go to `"feed_session:<user_id>:<session_id>"` on `TSpec.PubSub`
  (the channel relays them); the user id in the topic keeps one user's
  session pushes away from anyone else.
  """
  use GenServer, restart: :temporary

  import Ecto.Query, warn: false

  alias TSpec.{Content, Repo, Transparency}
  alias TSpec.Accounts.Scope
  alias TSpec.Events.{Event, Impression}
  alias TSpec.Feed.{Candidates, Ranker, Ranking, Settings}

  @page_size 10
  @idle_ms :timer.minutes(10)
  @refill_below 30
  @boost_min 5
  # After a refill comes back empty (the pool is genuinely exhausted), wait
  # this long before a page may trigger another.
  @empty_refill_cooldown_ms :timer.seconds(60)
  # How far back to look for a session's impressions when rebuilding.
  @rebuild_window_hours 24

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
    refilling: nil,
    refill_ref: nil,
    empty_refill_at: nil,
    # The settings version the client's list was last ranked under.
    served_settings_version: nil,
    # Content the client kept on screen after the session re-ranked it away
    # (the client never drops its current item); never served again.
    client_kept: MapSet.new()
  ]

  ## API

  @doc """
  The session's process (on whichever node owns it), started here if no
  node has it. Options (tests): `:gather` — a `Candidates.gather/4`-compatible
  function.
  """
  def ensure(%Scope{} = scope, session_id, opts \\ []), do: ensure(scope, session_id, opts, 20)

  # A process that just died can stay registered for a moment (`:global`
  # cleans up asynchronously), so don't hand out a dead local pid: retry.
  defp ensure(scope, session_id, opts, tries) do
    result =
      case :global.whereis_name(name(scope.user.id, session_id)) do
        pid when is_pid(pid) ->
          {:ok, pid}

        :undefined ->
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
      {:ok, pid} when tries > 0 and node(pid) == node() ->
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

  @doc "The live session's pid, on any node, or nil."
  def whereis(user_id, session_id) do
    case :global.whereis_name(name(user_id, session_id)) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  def start_link({%Scope{} = scope, session_id, opts}) do
    GenServer.start_link(__MODULE__, {scope, session_id, opts},
      name: {:global, name(scope.user.id, session_id)}
    )
  end

  defp name(user_id, session_id), do: {__MODULE__, user_id, session_id}

  @doc "The PubSub topic a session's pushes go to."
  def topic(user_id, session_id), do: "feed_session:#{user_id}:#{session_id}"

  @doc "Ranks and serves the next page: `{:ok, %{rev, items: [{%Scored{}, impression_id}]}}`."
  def next_page(pid, limit \\ @page_size), do: GenServer.call(pid, {:next_page, limit}, 15_000)

  @doc """
  The client's current item. Ignored if `rev` is older than the session's;
  a newer `rev` (the session restarted) is adopted.
  """
  def at(pid, impression_id, rev), do: GenServer.cast(pid, {:at, impression_id, rev})

  @doc "The client's revision on (re)joining; adopted if it's ahead of the session's."
  def sync_rev(pid, rev), do: GenServer.cast(pid, {:sync_rev, rev})

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
    state = rebuild(state)
    features = Ranking.features(state.scope.user.id, state.settings)
    candidates = state.gather.(state.scope.user.id, state.settings, features, [])

    state = %{state | features: features, cache: Map.new(candidates, &{&1.content_id, &1})}

    # Settings changed while no process was listening (it had idled out, or
    # the change came from the Algorithm tab): the client's list was ranked
    # under older settings, so re-rank its tail now.
    state =
      if state.served != [] and state.served_settings_version < state.settings.version,
        do: rerank_tail(state),
        else: state

    {:noreply, state, @idle_ms}
  end

  # Restores what the client holds from this session's impressions: replay
  # them in (rev, position) order — a new rev's first impression truncates
  # the list to its position (that's what a re-rank did), then appends.
  # The position is the furthest item the client reported actually showing.
  defp rebuild(%{scope: %{user: %{id: user_id}}, id: session_id} = state) do
    since = DateTime.add(DateTime.utc_now(), -@rebuild_window_hours, :hour)

    rows =
      from(i in Impression,
        where:
          i.user_id == ^user_id and i.feed_session_id == ^session_id and i.served_at > ^since,
        join: c in assoc(i, :content),
        order_by: [asc: i.rev, asc: i.position],
        select: %{
          impression_id: i.id,
          content_id: i.content_id,
          author_id: c.author_id,
          rev: i.rev,
          position: i.position,
          settings_version: i.settings_version
        }
      )
      |> Repo.all()

    if rows == [] do
      state
    else
      {served, _rev} =
        Enum.reduce(rows, {[], -1}, fn row, {list, rev} ->
          list = if row.rev != rev, do: Enum.take(list, row.position), else: list
          {list ++ [row], row.rev}
        end)

      served = with_primary_topics(served)
      shown = shown_impressions(user_id, Enum.map(served, & &1.impression_id))

      position =
        served
        |> Enum.with_index()
        |> Enum.filter(fn {s, _} -> MapSet.member?(shown, s.impression_id) end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.max(fn -> -1 end)

      %{
        state
        | served: served,
          rev: rows |> Enum.map(& &1.rev) |> Enum.max(),
          position: position,
          served_settings_version: rows |> Enum.map(& &1.settings_version) |> Enum.max()
      }
    end
  end

  defp with_primary_topics(served) do
    taxonomy = Content.topics_by_id()
    labels = Candidates.labels(Enum.map(served, & &1.content_id))

    for s <- served do
      primary =
        case Map.get(labels, s.content_id, []) do
          [] ->
            nil

          ls ->
            ls
            |> Enum.min_by(&{-&1.confidence, taxonomy[&1.topic_id].slug})
            |> then(&taxonomy[&1.topic_id].slug)
        end

      %{
        content_id: s.content_id,
        impression_id: s.impression_id,
        author_id: s.author_id,
        primary_topic: primary
      }
    end
  end

  defp shown_impressions(_user_id, []), do: MapSet.new()

  defp shown_impressions(user_id, impression_ids) do
    from(e in Event,
      where:
        e.user_id == ^user_id and e.type == "view_start" and e.impression_id in ^impression_ids,
      select: e.impression_id
    )
    |> Repo.all()
    |> MapSet.new()
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

  # A refill for the settings still in force: merge, and push if the tail
  # changed. It's no longer in flight, so pages may trigger the next one.
  def handle_info({:refill, version, candidates}, %{settings: %{version: version}} = state) do
    new = Enum.reject(candidates, &Map.has_key?(state.cache, &1.content_id))

    state = %{
      state
      | cache: Map.merge(state.cache, Map.new(new, &{&1.content_id, &1})),
        refilling: nil,
        empty_refill_at: if(new == [], do: System.monotonic_time(:millisecond))
    }

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

  # A refill task that finished normally already reported (its message
  # arrives before its exit). One that died didn't: stop waiting for it and
  # back off before retrying.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{refill_ref: ref} = state) do
    state = %{state | refill_ref: nil}

    state =
      if reason == :normal,
        do: state,
        else: %{state | refilling: nil, empty_refill_at: System.monotonic_time(:millisecond)}

    {:noreply, state, @idle_ms}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state, @idle_ms}

  ## Calls

  @impl true
  def handle_call({:next_page, limit}, _from, state) do
    page = next_items(state, limit)
    {pairs, state} = serve(state, page)
    state = maybe_refill(state, :page)
    {:reply, {:ok, %{rev: state.rev, items: pairs}}, state, @idle_ms}
  end

  @impl true
  # Impression ids are unique, so a position report is valid whatever rev
  # it carries (channel messages arrive in order). A higher rev is adopted.
  # An impression the session no longer lists is one the client kept on
  # screen through a re-rank: remember its content so it isn't served again.
  def handle_cast({:at, impression_id, rev}, state) do
    state = %{state | rev: max(state.rev, rev)}

    case Enum.find_index(state.served, &(&1.impression_id == impression_id)) do
      nil -> {:noreply, remember_kept(state, impression_id), @idle_ms}
      index -> {:noreply, %{state | position: index}, @idle_ms}
    end
  end

  def handle_cast({:sync_rev, rev}, state) when is_integer(rev) and rev > state.rev,
    do: {:noreply, %{state | rev: rev}, @idle_ms}

  def handle_cast({:sync_rev, _rev}, state), do: {:noreply, state, @idle_ms}

  defp remember_kept(%{scope: %{user: %{id: user_id}}, id: session_id} = state, impression_id) do
    with {:ok, id} <- Ecto.UUID.cast(impression_id),
         %{content_id: content_id} <-
           Repo.one(
             from i in Impression,
               where:
                 i.id == ^id and i.served_at == ^Impression.served_at_for(id) and
                   i.user_id == ^user_id and i.feed_session_id == ^session_id,
               select: %{content_id: i.content_id}
           ) do
      %{state | client_kept: MapSet.put(state.client_kept, content_id)}
    else
      _ -> state
    end
  rescue
    # Not a UUIDv7: not one of ours.
    _ -> state
  end

  ## Ranking

  # The best `limit` unserved candidates, with diversity continuing from
  # what's already been served.
  defp next_items(state, limit) do
    served_ids = state.served |> MapSet.new(& &1.content_id) |> MapSet.union(state.client_kept)

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

  defp maybe_refill(%{empty_refill_at: at} = state, :page) when is_integer(at) do
    if System.monotonic_time(:millisecond) - at < @empty_refill_cooldown_ms,
      do: state,
      else: maybe_refill(%{state | empty_refill_at: nil}, :page)
  end

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

  # The task is monitored: if it dies before reporting (a database timeout,
  # a crash), the session clears `refilling` and backs off instead of
  # waiting forever.
  defp start_refill(state, topic_slugs) do
    %{scope: scope, settings: settings, features: features, gather: gather} = state
    pid = self()
    exclude = Map.keys(state.cache)

    {:ok, task} =
      Task.Supervisor.start_child(TSpec.TaskSupervisor, fn ->
        candidates =
          gather.(scope.user.id, settings, features,
            exclude: exclude,
            topic_slugs: topic_slugs,
            refill: true
          )

        send(pid, {:refill, settings.version, candidates})
      end)

    %{state | refilling: settings.version, refill_ref: Process.monitor(task)}
  end
end
