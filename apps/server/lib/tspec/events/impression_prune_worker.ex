defmodule TSpec.Events.ImpressionPruneWorker do
  @moduledoc """
  Daily: deletes impressions that were *served* but never *shown* (no
  `view_start` carried their id) once they're 30 days old (ADR 0011).
  They're the bulk of the table — every re-rank serves a fresh page — and
  nothing reads them after that: the dashboard and dividend attribution
  count only shown impressions, which follow the normal retention window.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias TSpec.Events

  @keep_days 30

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _deleted} =
      Events.prune_unexposed_impressions(DateTime.add(DateTime.utc_now(), -@keep_days, :day))

    :ok
  end
end
