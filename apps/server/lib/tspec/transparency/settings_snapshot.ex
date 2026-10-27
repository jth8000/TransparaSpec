defmodule TSpec.Transparency.SettingsSnapshot do
  @moduledoc """
  An immutable copy of the algorithm settings a ranking used. Impressions
  point at one, so an explanation shows the settings *as they were* when the
  item was served — not the user's current ones (ADR 0011). Deduplicated per
  user by a hash of the settings.
  """
  use TSpec.Schema

  schema "algorithm_settings_snapshots" do
    field :settings_version, :integer
    field :settings, :map
    field :hash, :binary
    belongs_to :user, TSpec.Accounts.User
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
