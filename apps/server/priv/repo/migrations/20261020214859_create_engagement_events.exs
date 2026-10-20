defmodule TSpec.Repo.Migrations.CreateEngagementEvents do
  use Ecto.Migration

  # Append-only engagement log (ADR 0006/0007). Range-partitioned by month on
  # the server receive time (client clocks can't be trusted to pick a
  # partition). Every row carries the consent version in force. Future months
  # are created ahead of time by TSpec.Events.PartitionWorker; the default
  # partition only catches anything that slips through.
  def up do
    execute """
    CREATE TABLE engagement_events (
      id uuid NOT NULL,
      user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      content_id uuid NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
      type text NOT NULL,
      value double precision,
      occurred_at timestamptz NOT NULL,
      received_at timestamptz NOT NULL,
      session_id text,
      consent_version integer NOT NULL REFERENCES consent_documents(version),
      PRIMARY KEY (id, received_at)
    ) PARTITION BY RANGE (received_at)
    """

    execute "CREATE TABLE engagement_events_default PARTITION OF engagement_events DEFAULT"

    execute "CREATE INDEX engagement_events_user_id_received_at_index ON engagement_events (user_id, received_at)"

    execute "CREATE INDEX engagement_events_content_id_received_at_index ON engagement_events (content_id, received_at)"

    this_month = Date.beginning_of_month(Date.utc_today())

    for month <- [this_month, Date.shift(this_month, month: 1)] do
      next = Date.shift(month, month: 1)
      name = "engagement_events_y#{month.year}m#{String.pad_leading("#{month.month}", 2, "0")}"

      execute """
      CREATE TABLE #{name} PARTITION OF engagement_events
      FOR VALUES FROM ('#{month}') TO ('#{next}')
      """
    end
  end

  def down do
    execute "DROP TABLE engagement_events CASCADE"
  end
end
