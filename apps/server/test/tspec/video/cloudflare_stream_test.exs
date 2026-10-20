defmodule TSpec.Video.CloudflareStreamTest do
  use ExUnit.Case, async: true

  alias TSpec.Video.CloudflareStream

  @secret "test-webhook-secret"

  defp signed_headers(body, time \\ System.os_time(:second)) do
    time = Integer.to_string(time)
    sig = :crypto.mac(:hmac, :sha256, @secret, time <> "." <> body) |> Base.encode16(case: :lower)
    [{"webhook-signature", "time=#{time},sig1=#{sig}"}]
  end

  describe "create_direct_upload/1" do
    test "creates a one-time URL with the duration limit" do
      Req.Test.stub(CloudflareStream, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/client/v4/accounts/test-account/stream/direct_upload"
        assert ["Bearer test-token"] = Plug.Conn.get_req_header(conn, "authorization")
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"maxDurationSeconds" => 180} = Jason.decode!(body)

        Req.Test.json(conn, %{
          "success" => true,
          "result" => %{"uid" => "abc123", "uploadURL" => "https://upload.videodelivery.net/xyz"}
        })
      end)

      assert {:ok,
              %{
                asset_id: "abc123",
                url: "https://upload.videodelivery.net/xyz",
                method: "POST",
                form_field: "file"
              }} = CloudflareStream.create_direct_upload(%{max_duration_seconds: 180})
    end

    test "surfaces API errors" do
      Req.Test.stub(CloudflareStream, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"success" => false, "errors" => [%{"message" => "nope"}]})
      end)

      assert {:error, {:cloudflare, 403, _}} =
               CloudflareStream.create_direct_upload(%{max_duration_seconds: 180})
    end
  end

  test "delete_asset/1 treats already-gone videos as deleted" do
    Req.Test.stub(CloudflareStream, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/client/v4/accounts/test-account/stream/abc123"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert :ok = CloudflareStream.delete_asset("abc123")
  end

  test "playback and thumbnail URLs use the customer subdomain" do
    assert CloudflareStream.playback_url("abc") ==
             "https://customer-test.cloudflarestream.com/abc/manifest/video.m3u8"

    assert CloudflareStream.thumbnail_url("abc", []) ==
             "https://customer-test.cloudflarestream.com/abc/thumbnails/thumbnail.jpg"
  end

  describe "verify_webhook/2" do
    test "parses a ready video" do
      body =
        Jason.encode!(%{
          uid: "abc",
          readyToStream: true,
          status: %{state: "ready"},
          duration: 12.5,
          input: %{width: 1080, height: 1920}
        })

      assert {:ok,
              %{
                type: :ready,
                asset_id: "abc",
                playback_id: "abc",
                duration_ms: 12_500,
                width: 1080,
                height: 1920
              }} = CloudflareStream.verify_webhook(body, signed_headers(body))
    end

    test "parses errors under either documented field name" do
      for field <- ["errReasonCode", "errorReasonCode"] do
        body =
          Jason.encode!(%{
            uid: "abc",
            readyToStream: false,
            status: %{:state => "error", field => "ERR_DURATION_EXCEED_CONSTRAINT"}
          })

        assert {:ok, %{type: :failed, asset_id: "abc", reason: "ERR_DURATION_EXCEED_CONSTRAINT"}} =
                 CloudflareStream.verify_webhook(body, signed_headers(body))
      end
    end

    test "ignores intermediate states" do
      body = Jason.encode!(%{uid: "abc", readyToStream: false, status: %{state: "inprogress"}})

      assert {:ok, %{type: :ignored}} =
               CloudflareStream.verify_webhook(body, signed_headers(body))
    end

    test "rejects tampered bodies, wrong secrets, stale timestamps and missing headers" do
      body = Jason.encode!(%{uid: "abc", readyToStream: true})
      [{name, value}] = signed_headers(body)

      assert {:error, :invalid_signature} =
               CloudflareStream.verify_webhook(body <> " ", [{name, value}])

      assert {:error, :invalid_signature} =
               CloudflareStream.verify_webhook(
                 body,
                 signed_headers(body, System.os_time(:second) - 3600)
               )

      assert {:error, :invalid_signature} =
               CloudflareStream.verify_webhook(body, [{name, "time=1,sig1=deadbeef"}])

      assert {:error, :invalid_signature} =
               CloudflareStream.verify_webhook(body, [{name, "junk"}])

      assert {:error, :invalid_signature} = CloudflareStream.verify_webhook(body, [])
    end
  end
end
