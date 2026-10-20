defmodule TSpec.Content.ShortVideo do
  use TSpec.Schema

  @primary_key {:content_id, :binary_id, autogenerate: false}
  schema "short_videos" do
    field :provider, :string
    field :asset_id, :string
    field :playback_id, :string
    field :duration_ms, :integer
    field :width, :integer
    field :height, :integer
    field :failure_reason, :string
  end
end
