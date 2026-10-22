defmodule TSpec.Repo.Migrations.CreateInterestModel do
  use Ecto.Migration

  # The interest model (ADR 0012). Affinities are learned from *views* (one
  # playback episode, `view_id`), each contributing exactly one delta.
  def change do
    # Non-personalized mode: no inferred signals are used or learned.
    alter table(:users) do
      add :non_personalized, :boolean, null: false, default: false
    end

    # Engagement events may carry the playback episode they belong to.
    # (ALTER on the partitioned parent propagates to every partition.)
    alter table(:engagement_events) do
      add :view_id, :uuid
    end

    # Derived, mutable per-view state, written in the same transaction as the
    # view's events. `topic_snapshot` and `creator_id` are frozen at view
    # start; `learnable` can only go true -> false; the affinity worker
    # applies `target_delta - applied_delta` and clears `dirty`.
    create table(:view_engagements, primary_key: false) do
      add :view_id, :uuid, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :content_id, references(:content_items, type: :binary_id, on_delete: :delete_all),
        null: false

      add :creator_id, :binary_id, null: false
      # From short_videos at view start; NULL for content without a duration.
      add :duration_ms, :integer
      add :watched_ms, :integer, null: false, default: 0
      add :completed, :boolean, null: false, default: false
      add :early_skip, :boolean, null: false, default: false
      add :learnable, :boolean, null: false
      # %{topic_id => weight}: label confidence, with the tier-1 roll-up.
      add :topic_snapshot, :map, null: false
      add :target_delta, :float, null: false, default: 0.0
      add :applied_delta, :float, null: false, default: 0.0
      # Set when this view first moved an affinity (evidence counting).
      add :applied_at, :utc_datetime_usec
      add :dirty, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:view_engagements, [:user_id],
             where: "dirty",
             name: :view_engagements_dirty_index
           )

    create index(:view_engagements, [:user_id, :inserted_at])

    for {table, key, ref} <- [
          {:user_topic_affinity, :topic_id, :topics},
          {:user_creator_affinity, :creator_id, :users}
        ] do
      create table(table, primary_key: false) do
        add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
          primary_key: true

        add key, references(ref, type: :binary_id, on_delete: :delete_all), primary_key: true
        # Decayed lazily: the effective score at time t is
        # score * 0.5^((t - as_of) / half-life).
        add :score, :float, null: false
        add :evidence_count, :integer, null: false, default: 0
        add :as_of, :utc_datetime_usec, null: false
      end
    end
  end
end
