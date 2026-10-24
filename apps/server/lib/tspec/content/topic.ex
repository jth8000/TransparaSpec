defmodule TSpec.Content.Topic do
  @moduledoc """
  A topic from the IAB Content Taxonomy (tiers 1–2), seeded by migration.
  Tier-2 topics have a tier-1 `parent_id`. Rows are reference data: never
  edited at runtime.
  """
  use TSpec.Schema

  schema "topics" do
    field :iab_id, :string
    field :slug, :string
    field :name, :string
    field :tier, :integer
    belongs_to :parent, __MODULE__
  end
end
