defmodule TSpecWeb.ApiAuthFlowTest do
  use TSpecWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import Swoosh.TestAssertions
  import TSpec.AccountsFixtures

  @spec_mod TSpecWeb.ApiSpec

  setup do
    %{conn: json_conn()}
  end

  defp spec, do: @spec_mod.spec()

  defp sign_in(conn, email) do
    conn |> post(~p"/api/auth/request", %{email: email}) |> json_response(202)
    assert_email_sent(fn email -> send(self(), {:email, email}) end)
    assert_received {:email, sent}
    [_, code] = Regex.run(~r/sign-in code: (\d{6})/, sent.subject)

    body =
      json_conn() |> post(~p"/api/auth/verify", %{email: email, code: code}) |> json_response(200)

    assert_schema(body, "AuthSession", spec())
    body
  end

  defp bearer(token), do: json_conn() |> put_req_header("authorization", "Bearer " <> token)

  test "sign up, onboard, follow someone and see it on their profile", %{conn: conn} do
    bob = onboarded_user_fixture(handle: "bob")
    %{"token" => token, "user" => user} = sign_in(conn, "alice@example.com")
    assert user["onboarded"] == false
    assert user["handle"] == nil

    # Following requires onboarding first.
    assert %{"error" => "onboarding_required"} =
             bearer(token) |> post(~p"/api/users/bob/follow") |> json_response(403)

    version =
      json_conn() |> get(~p"/api/consent/current") |> json_response(200) |> Map.get("version")

    me =
      bearer(token)
      |> post(~p"/api/onboarding", %{
        handle: "alice",
        birthdate: "2001-02-03",
        accept_consent_version: version
      })
      |> json_response(200)

    assert_schema(me, "Me", spec())
    assert %{"handle" => "alice", "onboarded" => true, "consent_version" => ^version} = me

    assert bearer(token) |> post(~p"/api/users/bob/follow") |> response(204)

    profile = bearer(token) |> get(~p"/api/users/bob") |> json_response(200)
    assert_schema(profile, "PublicProfile", spec())
    assert %{"handle" => "bob", "followers_count" => 1, "followed_by_me" => true} = profile

    # Anonymous viewers see counts but not "followed_by_me".
    assert %{"followed_by_me" => false} =
             json_conn() |> get(~p"/api/users/bob") |> json_response(200)

    assert bob.handle == "bob"
  end

  test "sign out revokes the token", %{conn: conn} do
    %{"token" => token} = sign_in(conn, "carol@example.com")

    assert bearer(token) |> delete(~p"/api/auth/session") |> response(204)
    assert %{"error" => "unauthorized"} = bearer(token) |> get(~p"/api/me") |> json_response(401)
  end

  test "under-13 onboarding is refused and the account removed", %{conn: conn} do
    %{"token" => token} = sign_in(conn, "kid@example.com")
    birthdate = Date.utc_today() |> Date.shift(year: -10) |> Date.to_iso8601()

    assert %{"error" => "age_requirement"} =
             bearer(token)
             |> post(~p"/api/onboarding", %{
               handle: "kiddo",
               birthdate: birthdate,
               accept_consent_version: 1
             })
             |> json_response(403)

    assert TSpec.Accounts.get_user_by_email("kid@example.com") == nil
  end

  test "wrong codes are rejected", %{conn: conn} do
    conn |> post(~p"/api/auth/request", %{email: "dave@example.com"}) |> json_response(202)

    assert %{"error" => "invalid_code"} =
             json_conn()
             |> post(~p"/api/auth/verify", %{email: "dave@example.com", code: "000000"})
             |> json_response(401)
  end

  test "requests that don't match the schema get a field-level error", %{conn: conn} do
    body = conn |> post(~p"/api/auth/request", %{}) |> json_response(422)

    assert_schema(body, "Error", spec())
    assert %{"error" => "invalid_request", "fields" => %{"email" => [_ | _]}} = body
  end

  test "unknown profiles 404", %{conn: conn} do
    assert %{"error" => "not_found"} = conn |> get(~p"/api/users/ghost") |> json_response(404)
  end

  test "PATCH /api/me updates profile fields" do
    user = onboarded_user_fixture()

    me =
      json_conn()
      |> api_auth(user)
      |> patch(~p"/api/me", %{display_name: "New Name", bio: "hi"})
      |> json_response(200)

    assert %{"display_name" => "New Name", "bio" => "hi"} = me
  end
end
