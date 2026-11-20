defmodule Mix.Tasks.Tspec.ExportTaxonomyTest do
  use TSpec.DataCase, async: true

  alias Mix.Tasks.Tspec.ExportTaxonomy

  test "services/ml/taxonomy.json matches the topics table" do
    assert File.read!(ExportTaxonomy.path()) == ExportTaxonomy.render(),
           "services/ml/taxonomy.json is stale: run `mix tspec.export_taxonomy`"
  end
end
