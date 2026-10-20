defmodule TSpec.Content.VideoEventWorker do
  @moduledoc "Applies a verified video-provider webhook event (queued by the webhook endpoint)."
  use Oban.Worker, queue: :media, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider, "event" => event}}) do
    TSpec.Content.apply_video_event(provider, event)
  end
end
