defmodule Mix.Tasks.Tspec.ExportTaxonomy do
  @shortdoc "Writes the topic taxonomy for the ML service (services/ml/taxonomy.json)"
  @moduledoc """
  Exports the `topics` table (IAB Content Taxonomy 3.1, tiers 1–2) to
  `services/ml/taxonomy.json`, which the ML service scores items against:

      mix tspec.export_taxonomy

  The file is committed. `export_taxonomy_test.exs` fails when it no longer
  matches the database, so a taxonomy migration has to re-export it in the
  same change. Each topic's prompt text and whether the model may label it
  live next to it, in `services/ml/prompts.json`.
  """
  use Mix.Task

  alias TSpec.Content

  @requirements ["app.start"]
  @path Path.expand("../../../../../services/ml/taxonomy.json", __DIR__)

  def path, do: @path

  @impl Mix.Task
  def run(_args) do
    File.write!(@path, render())
    Mix.shell().info("Wrote #{Path.relative_to_cwd(@path)}")
  end

  @doc "The file's contents: topics sorted by slug, one JSON object per topic."
  def render do
    by_id = Content.topics_by_id()

    topics =
      Content.list_topics()
      |> Enum.sort_by(& &1.slug)
      |> Enum.map(fn t ->
        %{
          "slug" => t.slug,
          "name" => t.name,
          "tier" => t.tier,
          "parent" => t.parent_id && by_id[t.parent_id].slug,
          "iab_id" => t.iab_id
        }
      end)

    Jason.encode!(%{"source" => "IAB Content Taxonomy 3.1, tiers 1-2", "topics" => topics},
      pretty: true
    ) <> "\n"
  end
end
