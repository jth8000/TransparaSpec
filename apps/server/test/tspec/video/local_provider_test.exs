defmodule TSpec.Video.LocalProviderTest do
  use ExUnit.Case, async: true

  alias TSpec.Video.LocalProvider

  test "upload tokens round-trip and can't be forged" do
    {:ok, upload} = LocalProvider.create_direct_upload(%{})
    token = upload.url |> String.split("/") |> List.last()

    assert {:ok, asset_id} = LocalProvider.verify_upload_token(token)
    assert asset_id == upload.asset_id
    assert {:error, :invalid_token} = LocalProvider.verify_upload_token(token <> "x")
  end

  test "webhooks must carry a valid signature" do
    body = Jason.encode!(%{state: "ready", asset_id: Ecto.UUID.generate(), duration_ms: 1})

    good =
      :crypto.mac(:hmac, :sha256, "test-only-local-video-secret", body)
      |> Base.encode16(case: :lower)

    assert {:ok, %{type: :ready}} =
             LocalProvider.verify_webhook(body, [{"x-local-signature", good}])

    assert {:error, :invalid_signature} =
             LocalProvider.verify_webhook(body, [{"x-local-signature", "deadbeef"}])

    assert {:error, :invalid_signature} = LocalProvider.verify_webhook(body, [])
  end

  test "asset paths only accept UUIDs (no traversal)" do
    assert_raise MatchError, fn -> LocalProvider.asset_dir!("../../etc") end
  end
end
