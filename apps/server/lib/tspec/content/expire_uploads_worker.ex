defmodule TSpec.Content.ExpireUploadsWorker do
  @moduledoc """
  Hourly: fails video uploads still processing a day after their slot was
  created, and deletes their provider assets (`Content.expire_stale_uploads/1`).
  Every Post video creates a slot, so a failed upload that the client
  retries leaves the old slot behind; without this they'd sit in
  `processing` forever. A day is far beyond any real upload and transcode
  of a three-minute video.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias TSpec.Content

  @max_age_hours 24

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _expired} =
      Content.expire_stale_uploads(DateTime.add(DateTime.utc_now(), -@max_age_hours, :hour))

    :ok
  end
end
