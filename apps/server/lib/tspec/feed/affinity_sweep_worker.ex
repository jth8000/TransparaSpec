defmodule TSpec.Feed.AffinitySweepWorker do
  @moduledoc """
  Periodic backstop: queues `TSpec.Feed.AffinityWorker` for every user who
  still has dirty views. Every committed batch already has its own job, so
  this only matters when a job was discarded after repeated failures.
  Applying views is idempotent, so an extra run is harmless.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias TSpec.Feed.Interests

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(Interests.users_with_dirty_views(), &Interests.enqueue_apply/1)
  end
end
