defmodule TSpec.Events.PartitionWorkerTest do
  # Not async: partition DDL locks the parent and referenced tables, which
  # deadlocks against concurrently running sandboxed tests.
  use TSpec.DataCase, async: false

  alias TSpec.Events.PartitionWorker

  test "the partition worker creates upcoming months idempotently" do
    assert :ok = PartitionWorker.perform(%Oban.Job{})
    assert :ok = PartitionWorker.perform(%Oban.Job{})

    in_two_months = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: 2)
    name = PartitionWorker.partition_name(in_two_months)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*)::int FROM pg_class WHERE relname = $1", [name])
  end
end
