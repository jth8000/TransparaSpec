defmodule TSpec.Events.PartitionWorker do
  @moduledoc """
  Keeps monthly `engagement_events` partitions ahead of time (this month and
  the next two). Runs daily via Oban cron; idempotent.

  Creating a partition briefly takes locks on the parent and the tables its
  foreign keys reference (users, content_items, consent_documents), so it runs
  off-peak and creates months well before they're needed; a lock conflict
  just fails the job and Oban retries it.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias TSpec.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    this_month = Date.beginning_of_month(Date.utc_today())
    Enum.each(0..2, &ensure_month(Date.shift(this_month, month: &1)))
  end

  @doc "Creates the partition for the month starting at `month` if it doesn't exist."
  def ensure_month(%Date{day: 1} = month) do
    next = Date.shift(month, month: 1)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{partition_name(month)} PARTITION OF engagement_events
    FOR VALUES FROM ('#{month}') TO ('#{next}')
    """)

    :ok
  end

  def partition_name(%Date{year: year, month: month}) do
    "engagement_events_y#{year}m#{String.pad_leading("#{month}", 2, "0")}"
  end
end
