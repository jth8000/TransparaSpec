defmodule TSpecWeb.RateLimitTest do
  @moduledoc """
  Per-address limits on sign-in, and the client address they key on. Not
  async: these tests change application config (limits, client IP header).
  """
  use TSpecWeb.ConnCase, async: false

  import TSpec.AccountsFixtures

  alias TSpecWeb.{ClientIP, RateLimit}

  setup do
    limits = Application.fetch_env!(:tspec, :rate_limits)
    header = Application.get_env(:tspec, :client_ip_header)

    Application.put_env(:tspec, :rate_limits,
      auth_request: {3, :timer.minutes(1)},
      auth_verify: {3, :timer.minutes(1)}
    )

    on_exit(fn ->
      Application.put_env(:tspec, :rate_limits, limits)
      Application.put_env(:tspec, :client_ip_header, header)
    end)
  end

  # Hammer's counters outlive a test, so each test uses fresh addresses.
  defp ipv4, do: {10, 0, rem(System.unique_integer([:positive]), 250), 1}
  defp ipv6_prefix, do: {0x2001, 0xDB8, System.unique_integer([:positive]), 0}

  defp request_from(ip) do
    %{json_conn() | remote_ip: ip}
    |> post(~p"/api/auth/request", %{email: unique_user_email()})
  end

  test "sign-in requests past the limit get 429 with Retry-After; other addresses don't" do
    ip = ipv4()
    for _ <- 1..3, do: assert(request_from(ip).status == 202)

    conn = request_from(ip)
    assert %{"error" => "rate_limited"} = json_response(conn, 429)
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60

    assert request_from(ipv4()).status == 202
  end

  test "verify attempts are limited per address too" do
    ip = ipv4()
    body = %{email: "nobody@example.com", token: "x"}
    verify = fn -> post(%{json_conn() | remote_ip: ip}, ~p"/api/auth/verify", body) end

    for _ <- 1..3, do: assert(verify.().status == 401)
    assert json_response(verify.(), 429)["error"] == "rate_limited"
  end

  test "IPv6 clients share a limit per /64" do
    {a, b, c, d} = ipv6_prefix()
    for host <- 1..3, do: assert(request_from({a, b, c, d, 0, 0, 0, host}).status == 202)

    assert request_from({a, b, c, d, 0xFFFF, 1, 2, 3}).status == 429
    assert request_from({a, b, c, d + 1, 0, 0, 0, 1}).status == 202
  end

  test "IPv4-mapped IPv6 addresses are keyed by the whole address" do
    mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}
    assert RateLimit.client_key(mapped) == mapped
    assert RateLimit.client_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) == {0x2001, 0xDB8, 1, 2}
  end

  describe "client address" do
    test "comes from the configured proxy header, so limits are per real client" do
      Application.put_env(:tspec, :client_ip_header, "fly-client-ip")
      {_, _, n, _} = ipv4()

      from = fn client ->
        json_conn()
        |> put_req_header("fly-client-ip", client)
        |> post(~p"/api/auth/request", %{email: unique_user_email()})
      end

      for _ <- 1..3, do: assert(from.("198.51.100.#{n}").status == 202)
      assert from.("198.51.100.#{n}").status == 429
      assert from.("2001:db8:#{n}::1").status == 202
    end

    test "ignores the header unless one is configured" do
      Application.put_env(:tspec, :client_ip_header, nil)

      conn =
        build_conn() |> put_req_header("fly-client-ip", "203.0.113.7") |> ClientIP.call([])

      assert conn.remote_ip == {127, 0, 0, 1}
    end

    test "keeps the peer address when the header is missing or malformed" do
      Application.put_env(:tspec, :client_ip_header, "fly-client-ip")

      assert ClientIP.call(build_conn(), []).remote_ip == {127, 0, 0, 1}

      for bad <- ["", "not-an-ip", "203.0.113.7, 10.0.0.1", "203.0.113"] do
        conn = build_conn() |> put_req_header("fly-client-ip", bad) |> ClientIP.call([])
        assert conn.remote_ip == {127, 0, 0, 1}, "accepted #{inspect(bad)}"
      end

      conn = build_conn() |> put_req_header("fly-client-ip", " 203.0.113.7 ") |> ClientIP.call([])
      assert conn.remote_ip == {203, 0, 113, 7}
    end
  end
end
