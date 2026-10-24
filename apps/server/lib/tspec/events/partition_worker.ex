defmodule TSpec.Events.PartitionWorker do
  @moduledoc """
  Keeps monthly partitions of the append-only logs ahead of time (this month
  and the next two): `engagement_events` (by `received_at`) and
  `impressions` (by `served_at`). Runs daily via Oban cron; idempotent.

  Creating a partition briefly takes locks on the parent and the tables its
  foreign keys reference (users, content_items, consent_documents, settings
  snapshots), so it runs off-peak and creates months well before they're
  needed; a lock conflict just fails the job and Oban retries it.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias TSpec.Repo

  @tables ~w(engagement_events impressions)

  def tables, do: @tables

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    this_month = Date.beginning_of_month(Date.utc_today())

    for table <- @tables, offset <- 0..2 do
      ensure_month(table, Date.shift(this_month, month: offset))
    end

    :ok
  end

  @doc "Creates `table`'s partition for the month starting at `month` if it doesn't exist."
  def ensure_month(table, %Date{day: 1} = month) when table in @tables do
    next = Date.shift(month, month: 1)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{partition_name(table, month)} PARTITION OF #{table}
    FOR VALUES FROM ('#{month}') TO ('#{next}')
    """)

    :ok
  end

  def partition_name(table, %Date{year: year, month: month}) when table in @tables do
    "#{table}_y#{year}m#{String.pad_leading("#{month}", 2, "0")}"
  end
end
