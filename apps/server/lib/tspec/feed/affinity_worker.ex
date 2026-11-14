defmodule TSpec.Feed.AffinityWorker do
  @moduledoc """
  Applies one user's dirty views to their affinities
  (`TSpec.Feed.Interests.apply_dirty_views/2`).

  Queued by `Events.record/2` in the same transaction as the events, so a
  job exists for every batch of view state that commits — and Oban only
  runs committed jobs, so it always runs after the views it's for are
  visible. Deliberately **not** deduplicated: a unique job could be folded
  into one that runs before this transaction commits, leaving the new views
  with no job until the sweep. Extra runs are cheap and idempotent (ADR 0012).
  `TSpec.Feed.AffinitySweepWorker` only covers jobs that were discarded.

  After the views are applied (their transaction has committed), the user's
  live feed sessions are told to refresh their learned features, so a topic
  discovered mid-session gets its learned boost on the next page.
  """
  use Oban.Worker, queue: :affinity, max_attempts: 5

  alias TSpec.Feed.Interests
  alias TSpec.Transparency

  def new_for_user(user_id), do: new(%{user_id: user_id})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    {:ok, result} = Interests.apply_dirty_views(user_id)
    if result.applied > 0, do: Transparency.broadcast_interests_changed(user_id, :learned)
    if result.more?, do: Interests.enqueue_apply(user_id), else: :ok
  end
end
