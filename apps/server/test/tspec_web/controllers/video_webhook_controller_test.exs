defmodule TSpecWeb.VideoWebhookControllerTest do
  use TSpecWeb.ConnCase, async: true
  use Oban.Testing, repo: TSpec.Repo

  alias TSpec.Content.VideoEventWorker

  @secret "test-only-local-video-secret"

  defp post_webhook(body, signature) do
    json_conn()
    |> put_req_header("x-local-signature", signature)
    |> post(~p"/api/webhooks/video/local", body)
  end

  defp sign(body), do: :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

  test "a correctly signed event is accepted and queued" do
    asset_id = Ecto.UUID.generate()
    body = Jason.encode!(%{state: "ready", asset_id: asset_id, duration_ms: 1500})

    assert %{"status" => "ok"} = body |> post_webhook(sign(body)) |> json_response(200)

    assert_enqueued(
      worker: VideoEventWorker,
      args: %{provider: "local", event: %{type: "ready", asset_id: asset_id}}
    )
  end

  test "a bad signature is rejected" do
    body = Jason.encode!(%{state: "ready", asset_id: Ecto.UUID.generate()})

    assert %{"error" => "invalid_signature"} =
             body |> post_webhook("nope") |> json_response(400)

    refute_enqueued(worker: VideoEventWorker)
  end

  test "a body over the parser's limit is refused, not buffered" do
    # Signed correctly, so reading the whole body would reach the provider
    # and fail later (400) instead.
    body = Jason.encode!(%{state: "ready", pad: String.duplicate("a", 8_100_000)})
    assert_error_sent 413, fn -> post_webhook(body, sign(body)) end
  end

  test "unknown providers 404" do
    assert json_conn() |> post(~p"/api/webhooks/video/nope", "{}") |> json_response(404)
  end
end
