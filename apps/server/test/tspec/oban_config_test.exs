defmodule TSpec.ObanConfigTest do
  @moduledoc """
  Oban's configuration, read from the app env: tests run Oban in `:manual`
  mode, which starts no plugins.
  """
  use ExUnit.Case, async: true

  test "orphaned jobs are rescued, after longer than any job may run" do
    plugins = Application.fetch_env!(:tspec, Oban)[:plugins]
    assert {Oban.Lifeline, opts} = List.keyfind(plugins, Oban.Lifeline, 0)
    rescue_after = Keyword.fetch!(opts, :rescue_after)

    {:ok, modules} = :application.get_key(:tspec, :modules)

    workers =
      for m <- modules,
          Code.ensure_loaded?(m),
          Oban.Worker in Keyword.get(m.module_info(:attributes), :behaviour, []),
          do: m

    assert TSpec.Video.LocalTranscodeWorker in workers

    # Lifeline goes by time alone: a job still running past `rescue_after`
    # would be rescued and run twice. Workers without a timeout run short
    # jobs; one that may run long must declare `timeout/1`.
    for worker <- workers, timeout = worker.timeout(%Oban.Job{}), is_integer(timeout) do
      assert timeout < rescue_after,
             "#{inspect(worker)}'s timeout (#{timeout} ms) isn't below Lifeline's rescue_after"
    end
  end
end
