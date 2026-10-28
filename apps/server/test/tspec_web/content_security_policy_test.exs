defmodule TSpecWeb.ContentSecurityPolicyTest do
  use TSpecWeb.ConnCase, async: true

  defp nonce(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, policy)
    {policy, nonce}
  end

  test "HTML pages get a policy, and the inline script carries its nonce", %{conn: conn} do
    conn = get(conn, ~p"/")
    {policy, nonce} = nonce(conn)

    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'self'"
    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end

  test "each request gets a fresh nonce", %{conn: conn} do
    {_, first} = conn |> get(~p"/") |> nonce()
    {_, second} = build_conn() |> get(~p"/") |> nonce()

    refute first == second
  end
end
