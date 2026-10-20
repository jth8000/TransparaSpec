defmodule TSpec.Repo do
  use Ecto.Repo,
    otp_app: :tspec,
    adapter: Ecto.Adapters.Postgres
end
