defmodule TSpec.Repo.Migrations.AddLabelsVersionToContentItems do
  @moduledoc """
  `content_items.labels_version` goes up on every write to the item's
  `content_topics`, so a feed session can tell that labels it cached have
  changed (docs/review/concurrency.md, I34).

  A trigger keeps it, not the context: every writer (creator edits today,
  the ML pipeline in Phase 1b, tests that insert labels directly) bumps it
  without having to remember to. The bump is an `UPDATE` of a non-key
  column, so it takes `FOR NO KEY UPDATE` on the item, which doesn't block
  the `FOR KEY SHARE` that foreign-key checks take. When an item is deleted,
  its labels' cascade fires the trigger on a row that's already gone, and the
  update simply matches nothing.
  """
  use Ecto.Migration

  def up do
    alter table(:content_items) do
      add :labels_version, :integer, null: false, default: 0
    end

    execute """
    CREATE FUNCTION content_topics_bump_labels_version() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        UPDATE content_items SET labels_version = labels_version + 1
        WHERE id = OLD.content_id;
      END IF;

      IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.content_id <> OLD.content_id) THEN
        UPDATE content_items SET labels_version = labels_version + 1
        WHERE id = NEW.content_id;
      END IF;

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER content_topics_bump_labels_version
    AFTER INSERT OR UPDATE OR DELETE ON content_topics
    FOR EACH ROW EXECUTE FUNCTION content_topics_bump_labels_version()
    """
  end

  def down do
    execute "DROP TRIGGER content_topics_bump_labels_version ON content_topics"
    execute "DROP FUNCTION content_topics_bump_labels_version()"

    alter table(:content_items) do
      remove :labels_version
    end
  end
end
