defmodule TSpecWeb.UserSocketLogTest do
  @moduledoc """
  Connecting puts the socket's params in the log at `:info`, and the bearer
  token is one of them. Not async: it raises the global log level.
  """
  use TSpecWeb.ChannelCase, async: false

  import ExUnit.CaptureLog
  import TSpec.AccountsFixtures

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "the connect log doesn't contain the token" do
    token = api_token_fixture(onboarded_user_fixture())

    log =
      capture_log(fn ->
        assert {:ok, _socket} = connect(TSpecWeb.UserSocket, %{"token" => token})
      end)

    assert log =~ "CONNECTED TO TSpecWeb.UserSocket"
    assert log =~ ~s("token" => "[FILTERED]")
    refute log =~ token
  end
end
