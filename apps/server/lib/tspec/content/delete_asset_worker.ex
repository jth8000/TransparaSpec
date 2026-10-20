defmodule TSpec.Content.DeleteAssetWorker do
  @moduledoc "Deletes a removed video's asset at its provider."
  use Oban.Worker, queue: :media, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider, "asset_id" => asset_id}}) do
    TSpec.Video.provider!(provider).delete_asset(asset_id)
  end
end
