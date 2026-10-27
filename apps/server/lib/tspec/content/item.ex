defmodule TSpec.Content.Item do
  @moduledoc """
  The base row for every kind of content (ADR 0008). Kind-specific payloads
  (`ShortVideo`, `TextPost`) hang off it by `content_id`.
  """
  use TSpec.Schema

  @kinds ~w(short_video text_post)
  @statuses ~w(processing ready failed removed)

  schema "content_items" do
    field :kind, :string
    field :status, :string, default: "processing"
    field :visibility, :string, default: "public"
    field :caption, :string
    field :published_at, :utc_datetime_usec

    belongs_to :author, TSpec.Accounts.User
    belongs_to :parent, __MODULE__
    belongs_to :root, __MODULE__
    has_one :short_video, TSpec.Content.ShortVideo, foreign_key: :content_id
    has_one :text_post, TSpec.Content.TextPost, foreign_key: :content_id
    has_many :content_topics, TSpec.Content.ContentTopic, foreign_key: :content_id

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def caption_changeset(item, attrs) do
    item
    |> cast(attrs, [:caption])
    |> validate_length(:caption, max: 2200)
  end
end
