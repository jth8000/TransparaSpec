defmodule TSpec.Video do
  @moduledoc "Looks up `TSpec.Video.Provider` implementations by name."

  @doc "The provider new uploads go to (config `:video_provider`)."
  def default_provider_name, do: Application.fetch_env!(:tspec, :video_provider)

  @doc "Returns `{:ok, module}` for a provider name, or `:error`."
  def provider(name) when is_binary(name) do
    Map.fetch(Application.fetch_env!(:tspec, :video_providers), name)
  end

  def provider!(name) do
    case provider(name) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "unknown video provider #{inspect(name)}"
    end
  end

  @max_duration_seconds 180

  @doc "Short-form limit from the requirements (3 minutes)."
  def max_duration_seconds, do: @max_duration_seconds
end
