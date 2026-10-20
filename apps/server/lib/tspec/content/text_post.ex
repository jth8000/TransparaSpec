defmodule TSpec.Content.TextPost do
  use TSpec.Schema

  @primary_key {:content_id, :binary_id, autogenerate: false}
  schema "text_posts" do
    field :body, :string
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:body])
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: 2000)
  end
end
