defmodule TSpec.Repo.Migrations.AddInterestResetsAndExposureIndex do
  use Ecto.Migration

  def up do
    # "Forget this interest" (ADR 0012): the row is zeroed and stamped, and
    # views that started before the stamp never credit it again.
    for table <- [:user_topic_affinity, :user_creator_affinity] do
      alter table(table) do
        add :reset_at, :utc_datetime_usec
      end
    end

    # Exposure lookups (dashboard, session rebuild, pruning unexposed
    # impressions) go from impression id to its view_start.
    execute """
    CREATE INDEX engagement_events_impression_id_index
    ON engagement_events (impression_id) WHERE impression_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX engagement_events_impression_id_index"

    for table <- [:user_topic_affinity, :user_creator_affinity] do
      alter table(table) do
        remove :reset_at
      end
    end
  end
end
