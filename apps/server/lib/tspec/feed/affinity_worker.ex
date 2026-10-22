defmodule TSpec.Feed.AffinityWorker do
  @moduledoc """
  Applies one user's dirty views to their affinities
  (`TSpec.Feed.Interests.apply_dirty_views/2`).

  Queued by `Events.record/2` in the same transaction as the events, so a
  job exists whenever new view state commits. Uniqueness only spares
  duplicate work: it covers queued jobs but not an executing one, so views
  that commit mid-run still get a follow-up job. Correctness never depends
  on it — re-applying is a no-op (ADR 0012). `TSpec.Feed.AffinitySweepWorker`
  catches anything a lost job left behind.
  """
  use Oban.Worker, queue: :affinity, max_attempts: 5

  alias TSpec.Feed.Interests

  @unique [period: 60, keys: [:user_id], states: [:available, :scheduled, :retryable]]

  def new_for_user(user_id), do: new(%{user_id: user_id}, unique: @unique)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Interests.apply_dirty_views(user_id) do
      {:ok, %{more?: true}} -> Interests.enqueue_apply(user_id)
      {:ok, _} -> :ok
    end
  end
end
