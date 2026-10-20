defmodule TSpecWeb.CloudflareWebhookTest do
  @moduledoc "A Cloudflare-hosted upload goes ready through the real webhook endpoint."
  use TSpecWeb.ConnCase, async: true
  use Oban.Testing, repo: TSpec.Repo

  import TSpec.AccountsFixtures

  alias TSpec.{Accounts, Content, Repo}
  alias TSpec.Content.ShortVideo

  test "signed Cloudflare webhook marks the video ready with Cloudflare playback URLs" do
    user = onboarded_user_fixture()
    {:ok, {item, _upload}} = Content.create_video_upload(Accounts.scope_for_user(user), %{})
    # Pretend this upload went to Cloudflare.
    Repo.update_all(ShortVideo, set: [provider: "cloudflare", asset_id: "cf-uid-1"])

    body =
      Jason.encode!(%{
        uid: "cf-uid-1",
        readyToStream: true,
        status: %{state: "ready"},
        duration: 4.0,
        input: %{width: 720, height: 1280}
      })

    time = Integer.to_string(System.os_time(:second))

    sig =
      :crypto.mac(:hmac, :sha256, "test-webhook-secret", time <> "." <> body)
      |> Base.encode16(case: :lower)

    assert json_conn()
           |> put_req_header("webhook-signature", "time=#{time},sig1=#{sig}")
           |> post(~p"/api/webhooks/video/cloudflare", body)
           |> json_response(200)

    assert %{success: 1} = Oban.drain_queue(queue: :media)

    item_json = json_conn() |> get(~p"/api/content/#{item.id}") |> json_response(200)
    assert item_json["status"] == "ready"

    assert item_json["video"]["playback_url"] ==
             "https://customer-test.cloudflarestream.com/cf-uid-1/manifest/video.m3u8"
  end
end
