defmodule TSpec.Repo.Migrations.AddPlacementToImpressions do
  use Ecto.Migration

  # Why an item sits where it does when that isn't its score alone: "explore"
  # for an explore slot (ADR 0015). Null for an ordinary placement and for
  # impressions served before ranker v1.2. Added on the partitioned parent,
  # so every partition gets it.
  def change do
    alter table(:impressions) do
      add :placement, :text
    end
  end
end
