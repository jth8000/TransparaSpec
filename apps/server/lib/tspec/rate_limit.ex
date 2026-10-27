defmodule TSpec.RateLimit do
  @moduledoc """
  In-memory, per-node rate-limit counters (Hammer's ETS backend, fixed
  windows). `hit(key, window_ms, limit)` returns `{:allow, count}` or
  `{:deny, ms_until_the_window_resets}`.

  Counts are per node, so a cluster of N nodes lets a client through up to N
  times a limit. That's enough to blunt floods from one address. A limit
  that must hold exactly, like sign-in emails per address, is counted in
  Postgres instead (`TSpec.Accounts.request_login/2`).
  """
  use Hammer, backend: :ets
end
