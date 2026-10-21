defmodule TSpec.Video.LocalPipelineTest do
  @moduledoc """
  End-to-end through the real LocalProvider: multipart upload → ffmpeg HLS
  transcode → signed webhook → item ready → media served at /dev_media.
  """
  use TSpecWeb.ConnCase, async: false
  use Oban.Testing, repo: TSpec.Repo

  import TSpec.AccountsFixtures

  alias TSpec.{Accounts, Content}
  alias TSpec.Video.LocalProvider

  @moduletag :ffmpeg

  setup do
    dir = Path.join(System.tmp_dir!(), "tspec-pipeline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{clip: make_clip(dir, "360x640"), dir: dir}
  end

  defp make_clip(dir, size) do
    clip = Path.join(dir, "clip-#{size}.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=2:size=#{size}:rate=24
           -f lavfi -i sine=duration=2 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac) ++
          [clip]
      )

    clip
  end

  # Uploads `clip` through the one-time URL and runs the transcode + webhook jobs.
  defp upload_and_process(clip) do
    user = onboarded_user_fixture()
    {:ok, {item, upload}} = Content.create_video_upload(Accounts.scope_for_user(user), %{})
    on_exit(fn -> LocalProvider.delete_asset(upload.asset_id) end)

    file = %Plug.Upload{path: clip, filename: "clip.mp4", content_type: "video/mp4"}
    build_conn() |> post(URI.parse(upload.url).path, %{"file" => file}) |> json_response(200)
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :media, with_recursion: true)
    {item, upload}
  end

  defp encoded_size(asset_id) do
    segment = Path.join(LocalProvider.asset_dir!(asset_id), "seg_000.ts")

    {out, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0) ++
          [segment]
      )

    # MPEG-TS also prints a program section; the stream's line comes first.
    [line | _] = String.split(out, "\n", trim: true)
    line |> String.split(",") |> Enum.map(&String.to_integer/1)
  end

  test "landscape video keeps its width: the shorter side is capped, not the width", %{dir: dir} do
    {_item, upload} = upload_and_process(make_clip(dir, "2560x1440"))
    assert encoded_size(upload.asset_id) == [1920, 1080]
  end

  test "vertical video is capped on its width (the shorter side)", %{dir: dir} do
    {_item, upload} = upload_and_process(make_clip(dir, "1440x2560"))
    assert encoded_size(upload.asset_id) == [1080, 1920]
  end

  test "an uploaded clip becomes a playable HLS video", %{clip: clip} do
    user = onboarded_user_fixture()
    scope = Accounts.scope_for_user(user)
    {:ok, {item, upload}} = Content.create_video_upload(scope, %{caption: "test clip"})
    on_exit(fn -> LocalProvider.delete_asset(upload.asset_id) end)

    # The client's direct upload, as multipart to the one-time URL.
    path = URI.parse(upload.url).path
    file = %Plug.Upload{path: clip, filename: "clip.mp4", content_type: "video/mp4"}

    assert %{"status" => "ok"} =
             build_conn() |> post(path, %{"file" => file}) |> json_response(200)

    # Re-using the URL is refused.
    assert build_conn() |> post(path, %{"file" => file}) |> json_response(409)

    # Two jobs: the ffmpeg transcode, then the webhook event it emits.
    assert %{success: 2, failure: 0} =
             Oban.drain_queue(queue: :media, with_recursion: true)

    {:ok, item} = Content.get_item(nil, item.id)
    assert item.status == "ready"
    assert item.short_video.width == 360
    assert item.short_video.height == 640
    assert_in_delta item.short_video.duration_ms, 2000, 150

    playlist = build_conn() |> get("/dev_media/#{upload.asset_id}/index.m3u8") |> response(200)
    assert playlist =~ "#EXTM3U"
    assert playlist =~ "seg_000.ts"

    assert build_conn() |> get("/dev_media/#{upload.asset_id}/thumb.jpg") |> response(200)
  end
end
