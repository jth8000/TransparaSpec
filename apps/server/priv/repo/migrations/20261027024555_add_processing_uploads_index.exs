defmodule TSpec.Repo.Migrations.AddProcessingUploadsIndex do
  use Ecto.Migration

  def change do
    # The hourly stale-upload sweep (Content.ExpireUploadsWorker) looks only
    # at items still processing; they're few, so a partial index keeps the
    # sweep off the rest of content_items.
    create index(:content_items, [:inserted_at],
             where: "status = 'processing'",
             name: :content_items_processing_index
           )
  end
end
