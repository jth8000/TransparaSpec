defmodule TSpec.Repo.Migrations.CreateTopics do
  use Ecto.Migration

  # Topic taxonomy (IAB Content Taxonomy 3.1, tiers 1–2; see priv/taxonomy/README.md)
  # and the labels that attach topics to content (ADR 0008/0012).
  #
  # The seed lives in the migration (not priv/repo/seeds.exs) so every
  # environment, including test and CI, has the same topics. The parsing is
  # inlined rather than calling app code, so later changes to app modules
  # can't change what this migration did.
  @taxonomy "iab-content-taxonomy-3.1.tsv"

  def up do
    create table(:topics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :iab_id, :string, null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :tier, :integer, null: false
      add :parent_id, references(:topics, type: :binary_id, on_delete: :restrict)
    end

    create unique_index(:topics, [:iab_id])
    create unique_index(:topics, [:slug])
    create index(:topics, [:parent_id])
    create constraint(:topics, :valid_tier, check: "tier IN (1, 2)")

    # One row per (item, topic, label source). An item's effective confidence
    # for a topic is the max over sources; explanations keep the source.
    create table(:content_topics, primary_key: false) do
      add :content_id, references(:content_items, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :topic_id, references(:topics, type: :binary_id, on_delete: :restrict),
        primary_key: true

      add :source, :string, primary_key: true
      add :confidence, :float, null: false
    end

    create index(:content_topics, [:topic_id, :content_id])

    create constraint(:content_topics, :valid_source,
             check: "source IN ('creator', 'model', 'moderator')"
           )

    create constraint(:content_topics, :valid_confidence,
             check: "confidence > 0 AND confidence <= 1"
           )

    flush()
    seed_topics()
  end

  def down do
    drop table(:content_topics)
    drop table(:topics)
  end

  defp seed_topics do
    rows =
      Application.app_dir(:tspec, Path.join("priv/taxonomy", @taxonomy))
      |> File.read!()
      |> String.split(["\r\n", "\n"], trim: true)
      # Two header rows: a group header, then column names.
      |> Enum.drop(2)
      |> Enum.map(&String.split(&1, "\t"))
      |> Enum.flat_map(fn [iab_id, parent, name, _t1, t2, t3 | _] ->
        cond do
          t2 == "" -> [%{iab_id: iab_id, parent: nil, name: name, tier: 1}]
          t3 == "" -> [%{iab_id: iab_id, parent: parent, name: name, tier: 2}]
          true -> []
        end
      end)

    ids = Map.new(rows, &{&1.iab_id, UUIDv7.generate()})

    # Parents first, so the self-referencing foreign key is satisfied.
    for tier <- [1, 2] do
      entries =
        for row <- rows, row.tier == tier do
          %{
            id: Ecto.UUID.dump!(ids[row.iab_id]),
            iab_id: row.iab_id,
            slug: slugify(row.name),
            name: row.name,
            tier: row.tier,
            parent_id: row.parent && Ecto.UUID.dump!(Map.fetch!(ids, row.parent))
          }
        end

      repo().insert_all("topics", entries)
    end
  end

  # "Food & Drink" -> "food-and-drink"
  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace("&", " and ")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
