defmodule TSpec.Repo.Migrations.EnableExtensionsAndOban do
  use Ecto.Migration

  def up do
    # citext: case-insensitive emails and handles.
    execute "CREATE EXTENSION IF NOT EXISTS citext"
    # vector: content embeddings (Phase 1), enabled now so the schema is ready.
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    Oban.Migration.up()
  end

  def down do
    Oban.Migration.down(version: 1)

    execute "DROP EXTENSION IF EXISTS vector"
    execute "DROP EXTENSION IF EXISTS citext"
  end
end
