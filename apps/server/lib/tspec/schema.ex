defmodule TSpec.Schema do
  @moduledoc """
  Base for T-Spec Ecto schemas: UUIDv7 primary keys (time-ordered, so they
  double as stable tie-breakers for keyset pagination), UUID foreign keys and
  UTC second-precision timestamps.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, UUIDv7, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
