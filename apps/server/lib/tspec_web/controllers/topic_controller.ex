defmodule TSpecWeb.TopicController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Content
  alias TSpecWeb.Schemas

  tags ["topics"]

  operation :index,
    summary: "The topic taxonomy (IAB Content Taxonomy 3.1, tiers 1–2)",
    responses: [ok: {"Topics, tier 1 first", "application/json", Schemas.TopicList}]

  def index(conn, _params) do
    topics = Content.list_topics()
    slugs = Map.new(topics, &{&1.id, &1.slug})

    json(conn, %{
      topics:
        for t <- topics do
          %{slug: t.slug, name: t.name, tier: t.tier, parent: t.parent_id && slugs[t.parent_id]}
        end,
      max_creator_topics: Content.max_creator_topics()
    })
  end
end
