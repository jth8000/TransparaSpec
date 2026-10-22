defmodule TSpec.Content.ContentTopic do
  @moduledoc """
  A topic label on a content item, from one `source`:

    * `creator` — picked by the author (confidence 1.0: a deliberate
      declaration, not a claim that the label is certainly right)
    * `model` — from the ML service (Phase 1b)
    * `moderator` — set during review

  An item's effective confidence for a topic is the max over its sources.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  @sources ~w(creator model moderator)

  schema "content_topics" do
    belongs_to :content, TSpec.Content.Item, primary_key: true
    belongs_to :topic, TSpec.Content.Topic, primary_key: true
    field :source, :string, primary_key: true
    field :confidence, :float
  end

  def sources, do: @sources
end
