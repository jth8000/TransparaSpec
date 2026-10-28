defmodule TSpec.Video.LocalTranscodeWorker do
  @moduledoc """
  Transcodes a locally uploaded video to a single HLS rendition (shorter side
  capped at 1080px, so vertical and landscape videos keep the same quality)
  plus a thumbnail, then reports the result through `LocalProvider.deliver_event/1`
  like a provider webhook. Content problems (unreadable file, too long) are
  reported as `failed` rather than retried.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  alias TSpec.Video
  alias TSpec.Video.LocalProvider

  # Cap the *shorter* side at 1080px and keep the aspect ratio (-2 = even
  # width/height for H.264). Capping width alone shrank landscape screen
  # recordings to 720px wide and made text unreadable.
  @scale_filter "scale='if(gt(iw,ih),-2,min(1080,iw))':'if(gt(iw,ih),min(1080,ih),-2)'"

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset_id" => asset_id}}) do
    dir = LocalProvider.asset_dir!(asset_id)
    source = Path.join(dir, "source")

    payload =
      with {:ok, probe} <- probe(source),
           :ok <- check_duration(probe),
           :ok <- transcode(source, dir),
           :ok <- thumbnail(source, dir, probe) do
        %{
          state: "ready",
          asset_id: asset_id,
          duration_ms: probe.duration_ms,
          width: probe.width,
          height: probe.height
        }
      else
        {:error, reason} -> %{state: "failed", asset_id: asset_id, reason: reason}
      end

    LocalProvider.deliver_event(payload)
  end

  defp probe(source) do
    args =
      ~w(-v error -select_streams v:0 -show_entries stream=width,height:format=duration -of json) ++
        [source]

    with {out, 0} <- run("ffprobe", args),
         {:ok, %{"streams" => [stream | _], "format" => %{"duration" => duration}}} <-
           Jason.decode(out),
         {seconds, _} <- Float.parse(duration) do
      {:ok,
       %{
         width: stream["width"],
         height: stream["height"],
         duration_ms: round(seconds * 1000)
       }}
    else
      _ -> {:error, "unreadable_video"}
    end
  end

  defp check_duration(%{duration_ms: ms}) do
    if ms <= Video.max_duration_seconds() * 1000, do: :ok, else: {:error, "too_long"}
  end

  defp transcode(source, dir) do
    args =
      ["-y", "-i", source, "-vf", @scale_filter] ++
        ~w[-c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p] ++
        ~w(-c:a aac -b:a 128k -hls_time 4 -hls_playlist_type vod) ++
        ["-hls_segment_filename", Path.join(dir, "seg_%03d.ts"), Path.join(dir, "index.m3u8")]

    case run("ffmpeg", args) do
      {_, 0} -> :ok
      _ -> {:error, "transcode_failed"}
    end
  end

  defp thumbnail(source, dir, %{duration_ms: ms}) do
    at = if ms > 1000, do: "0.5", else: "0"
    args = ["-y", "-ss", at, "-i", source, "-frames:v", "1", Path.join(dir, "thumb.jpg")]

    case run("ffmpeg", args) do
      {_, 0} -> :ok
      _ -> {:error, "thumbnail_failed"}
    end
  end

  # Dev/test only. `cmd` is always "ffmpeg", and `args` is a list passed
  # straight to the executable with no shell.
  # sobelow_skip ["CI.System"]
  defp run(cmd, args) do
    case System.find_executable(cmd) do
      nil -> {"#{cmd} not found", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end
end
