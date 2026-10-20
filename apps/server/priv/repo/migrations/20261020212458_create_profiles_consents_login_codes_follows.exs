defmodule TSpec.Repo.Migrations.CreateProfilesConsentsLoginCodesFollows do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Public identity. Null until onboarding completes.
      add :handle, :citext
      # Only the fact that the user attested to being 13+ is kept; the date of
      # birth itself is never stored (minimal PII, COPPA).
      add :age_attested_at, :utc_datetime
      add :onboarded_at, :utc_datetime
    end

    create unique_index(:users, [:handle])

    create table(:profiles, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :display_name, :string
      add :bio, :text
      add :avatar_url, :string

      timestamps(type: :utc_datetime)
    end

    # One-time 6-digit sign-in codes (native clients). The code is stored as an
    # HMAC so a database leak can't be brute-forced offline; attempts are capped.
    create table(:login_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :binary, null: false
      add :sent_to, :citext, null: false
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:login_codes, [:user_id])

    # Versioned terms/privacy documents. Every engagement event records the
    # consent version in force (ADR 0007).
    create table(:consent_documents, primary_key: false) do
      add :version, :integer, primary_key: true
      add :kind, :string, null: false
      add :body_hash, :string, null: false
      add :published_at, :utc_datetime, null: false
    end

    create table(:consents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :version, references(:consent_documents, column: :version, type: :integer), null: false

      add :scopes, {:array, :string}, null: false, default: []
      add :granted_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
    end

    create index(:consents, [:user_id])

    create table(:follows, primary_key: false) do
      add :follower_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :followee_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:follows, [:followee_id])
    create constraint(:follows, :no_self_follow, check: "follower_id <> followee_id")

    # Consent v1 must exist in every environment, so it's seeded here rather
    # than in seeds.exs. Its body lives in docs/legal (TBD before beta).
    execute(
      """
      INSERT INTO consent_documents (version, kind, body_hash, published_at)
      VALUES (1, 'terms_and_privacy', 'draft-v1', now())
      """,
      "DELETE FROM consent_documents WHERE version = 1"
    )
  end
end
