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
  """
  use Oban.Worker, queue: :affinity, max_attempts: 5

  alias TSpec.Feed.Interests

  def new_for_user(user_id), do: new(%{user_id: user_id})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Interests.apply_dirty_views(user_id) do
      {:ok, %{more?: true}} -> Interests.enqueue_apply(user_id)
      {:ok, _} -> :ok
    end
  end
end
