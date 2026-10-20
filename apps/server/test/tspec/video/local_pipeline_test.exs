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

    clip = Path.join(dir, "clip.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=2:size=360x640:rate=24
           -f lavfi -i sine=duration=2 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac) ++
          [clip]
      )

    %{clip: clip}
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

    # Transcode, then apply the webhook event it emits.
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
