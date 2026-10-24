defmodule TSpec.Repo.Migrations.CreateAlgorithmSettings do
  use Ecto.Migration

  # A user's algorithm controls (ADR 0011/0012). Sparse: a row exists only
  # where the user changed something from the default (multiplier 1.0, not
  # hard-off). Every change bumps users.settings_version, which impressions
  # record so explanations show the settings as they were.
  def change do
    alter table(:users) do
      add :settings_version, :integer, null: false, default: 0
    end

    create table(:user_algorithm_settings, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      # "topic:<slug>" or "source:<name>"
      add :key, :string, primary_key: true
      add :multiplier, :float, null: false, default: 1.0
      add :hard_off, :boolean, null: false, default: false
    end

    create constraint(:user_algorithm_settings, :valid_multiplier,
             check: "multiplier >= 0 AND multiplier <= 2"
           )

    create constraint(:user_algorithm_settings, :valid_key,
             check: "key LIKE 'topic:%' OR key LIKE 'source:%'"
           )
  end
end
