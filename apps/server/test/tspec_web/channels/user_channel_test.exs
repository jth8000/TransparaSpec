defmodule TSpecWeb.UserChannelTest do
  use TSpecWeb.ChannelCase, async: true

  import TSpec.AccountsFixtures

  alias TSpec.{Accounts, Content}

  setup do
    user = onboarded_user_fixture()
    token = api_token_fixture(user)
    {:ok, socket} = connect(TSpecWeb.UserSocket, %{"token" => token})
    %{user: user, token: token, socket: socket}
  end

  test "connecting requires a valid token" do
    assert :error = connect(TSpecWeb.UserSocket, %{"token" => "bogus"})
    assert :error = connect(TSpecWeb.UserSocket, %{})
  end

  test "signing out closes that token's sockets, not the user's other devices", %{
    user: user,
    token: token,
    socket: socket
  } do
    {:ok, other_device} = connect(TSpecWeb.UserSocket, %{"token" => api_token_fixture(user)})
    # `connect/2` subscribes the test process to each socket's id, as the
    # real transport process is, so we see what would close each socket.
    refute socket.id == other_device.id

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Phoenix.ConnTest.dispatch(@endpoint, :delete, "/api/auth/session")

    assert conn.status == 204
    {signed_out, still_in} = {socket.id, other_device.id}
    assert_receive %Phoenix.Socket.Broadcast{topic: ^signed_out, event: "disconnect"}
    refute_received %Phoenix.Socket.Broadcast{topic: ^still_in, event: "disconnect"}
  end

  test "users can only join their own channel", %{socket: socket, user: user} do
    assert {:ok, _, _} = subscribe_and_join(socket, "user:#{user.id}", %{})

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, "user:#{Ecto.UUID.generate()}", %{})
  end

  test "pushes upload status changes", %{socket: socket, user: user} do
    {:ok, _, _socket} = subscribe_and_join(socket, "user:#{user.id}", %{})
    {:ok, {item, upload}} = Content.create_video_upload(Accounts.scope_for_user(user), %{})

    :ok =
      Content.apply_video_event("local", %{
        "type" => "ready",
        "asset_id" => upload.asset_id,
        "playback_id" => upload.asset_id,
        "duration_ms" => 1000
      })

    content_id = item.id
    assert_push "content_status", %{content_id: ^content_id, status: "ready"}
  end
end
