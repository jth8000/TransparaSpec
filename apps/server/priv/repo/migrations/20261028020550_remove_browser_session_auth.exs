defmodule TSpec.Repo.Migrations.RemoveBrowserSessionAuth do
  use Ecto.Migration

  # The browser session sign-in from phx.gen.auth is gone: its session and
  # change-email tokens, the optional password, and the per-token
  # authenticated_at that drove "sudo mode". Sign-in is the API's email
  # code or magic link only.
  def change do
    execute "DELETE FROM users_tokens WHERE context = 'session' OR context LIKE 'change:%'", ""

    alter table(:users_tokens) do
      remove :authenticated_at, :utc_datetime
    end

    alter table(:users) do
      remove :hashed_password, :string
    end
  end
end
