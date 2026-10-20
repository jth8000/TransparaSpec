defmodule TSpec.Repo.Migrations.CreateContentTables do
  use Ecto.Migration

  def change do
    # One base table for every kind of content (ADR 0008). Kind-specific data
    # lives in payload tables keyed by content_id. Comments/replies will be
    # content items with parent_id/root_id set.
    create table(:content_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :author_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :parent_id, references(:content_items, type: :binary_id, on_delete: :nilify_all)
      add :root_id, references(:content_items, type: :binary_id, on_delete: :nilify_all)
      add :status, :string, null: false, default: "processing"
      add :visibility, :string, null: false, default: "public"
      add :caption, :text
      # Set when the item becomes ready; feeds order by (published_at, id).
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create constraint(:content_items, :valid_kind, check: "kind IN ('short_video', 'text_post')")

    create constraint(:content_items, :valid_status,
             check: "status IN ('processing', 'ready', 'failed', 'removed')"
           )

    create constraint(:content_items, :valid_visibility, check: "visibility IN ('public')")

    create index(:content_items, [:author_id, "published_at DESC", "id DESC"])

    create index(:content_items, ["published_at DESC", "id DESC"],
             where: "status = 'ready' AND visibility = 'public'",
             name: :content_items_public_feed_index
           )

    create table(:short_videos, primary_key: false) do
      add :content_id, references(:content_items, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :provider, :string, null: false
      add :asset_id, :string, null: false
      add :playback_id, :string
      add :duration_ms, :integer
      add :width, :integer
      add :height, :integer
      add :failure_reason, :string
    end

    create unique_index(:short_videos, [:provider, :asset_id])

    create table(:text_posts, primary_key: false) do
      add :content_id, references(:content_items, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :body, :text, null: false
    end
  end
end
