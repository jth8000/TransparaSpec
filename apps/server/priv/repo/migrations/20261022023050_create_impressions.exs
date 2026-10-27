defmodule TSpec.Repo.Migrations.CreateImpressions do
  use Ecto.Migration

  # Served impressions with their exact contribution traces (ADR 0006/0011).
  # "Why am I seeing this?" reads these rows; it never recomputes.
  def up do
    # Deduplicated copies of the settings a ranking used, so each impression
    # can point at exactly what the user had set at the time.
    create table(:algorithm_settings_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :settings_version, :integer, null: false
      add :settings, :map, null: false
      add :hash, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:algorithm_settings_snapshots, [:user_id, :hash])

    # Partitioned by month on served_at, like engagement_events. Postgres
    # requires the partition key in the primary key, so it's (id, served_at);
    # served_at is the timestamp embedded in the UUIDv7 id, so a lookup by id
    # alone can compute it and hit exactly one partition.
    execute """
    CREATE TABLE impressions (
      id uuid NOT NULL,
      served_at timestamptz NOT NULL,
      user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      content_id uuid NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
      feed_session_id uuid NOT NULL,
      rev integer NOT NULL,
      position integer NOT NULL,
      ranker_version text NOT NULL,
      candidate_source text NOT NULL,
      sources text[] NOT NULL,
      final_score double precision NOT NULL,
      contributions jsonb NOT NULL,
      settings_version integer NOT NULL,
      settings_snapshot_id uuid NOT NULL REFERENCES algorithm_settings_snapshots(id) ON DELETE CASCADE,
      consent_version integer NOT NULL REFERENCES consent_documents(version),
      PRIMARY KEY (id, served_at)
    ) PARTITION BY RANGE (served_at)
    """

    execute "CREATE TABLE impressions_default PARTITION OF impressions DEFAULT"

    execute "CREATE INDEX impressions_user_id_served_at_index ON impressions (user_id, served_at)"

    this_month = Date.beginning_of_month(Date.utc_today())

    for month <- [this_month, Date.shift(this_month, month: 1)] do
      next = Date.shift(month, month: 1)
      name = "impressions_y#{month.year}m#{String.pad_leading("#{month.month}", 2, "0")}"

      execute """
      CREATE TABLE #{name} PARTITION OF impressions
      FOR VALUES FROM ('#{month}') TO ('#{next}')
      """
    end

    # Exposure: a view_start can name the impression it came from. No FK
    # (both tables are partitioned); Events.record/2 validates it.
    execute "ALTER TABLE engagement_events ADD COLUMN impression_id uuid"

    # Global trending pool, refreshed by TSpec.Feed.TrendingWorker.
    create table(:trending_scores, primary_key: false) do
      add :content_id, references(:content_items, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :score, :float, null: false
      add :computed_at, :utc_datetime_usec, null: false
    end

    create index(:trending_scores, ["score DESC"])

    # Candidate queries by topic and recency.
    create index(:content_items, [:published_at],
             where: "status = 'ready' AND visibility = 'public'",
             name: :content_items_ready_published_at_index
           )

    create index(:view_engagements, [:content_id, :completed])
  end

  def down do
    drop index(:view_engagements, [:content_id, :completed])
    drop index(:content_items, [:published_at], name: :content_items_ready_published_at_index)
    drop table(:trending_scores)
    execute "ALTER TABLE engagement_events DROP COLUMN impression_id"
    execute "DROP TABLE impressions CASCADE"
    drop table(:algorithm_settings_snapshots)
  end
end
