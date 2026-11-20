defmodule TSpecWeb.TextLimitsTest do
  @moduledoc """
  What people type, checked through the API as clients call it: text is
  limited in characters and in bytes (`TSpec.TextLimit`), handles and emails
  are matched to the end of the string, and bodies are capped before they're
  parsed.
  """
  use TSpecWeb.ConnCase, async: true

  import Ecto.Query
  import Swoosh.TestAssertions
  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.Repo
  alias TSpec.Accounts.{Profile, User}
  alias TSpec.Content.Item
  alias TSpec.Events.Event

  # One grapheme carrying 20,000 combining accents: 40,001 bytes, over every
  # limit's byte cap (the largest, a caption's, is 35,200).
  @zalgo "a" <> String.duplicate("́", 20_000)

  defp consent_version,
    do: json_conn() |> get(~p"/api/consent/current") |> json_response(200) |> Map.get("version")

  defp onboard(user, attrs) do
    defaults = %{
      handle: unique_handle(),
      birthdate: "2001-02-03",
      accept_consent_version: consent_version()
    }

    json_conn() |> api_auth(user) |> post(~p"/api/onboarding", Map.merge(defaults, attrs))
  end

  defp field_errors(conn) do
    assert %{"error" => "validation_failed", "fields" => fields} = json_response(conn, 422)
    fields
  end

  test "text that's short in characters but long in bytes is refused" do
    user = onboarded_user_fixture()

    cases = [
      {:post, ~p"/api/posts", %{body: "Hello", caption: @zalgo}, "caption"},
      {:post, ~p"/api/posts", %{body: @zalgo}, "body"},
      {:patch, ~p"/api/me", %{display_name: @zalgo}, "display_name"},
      {:patch, ~p"/api/me", %{bio: @zalgo}, "bio"}
    ]

    for {method, path, body, field} <- cases do
      conn = json_conn() |> api_auth(user) |> dispatch(@endpoint, method, path, body)
      assert [message] = field_errors(conn)[field], field
      assert message =~ "byte"
    end

    assert Repo.aggregate(Item, :count) == 0
    assert %Profile{display_name: nil, bio: nil} = Repo.get(Profile, user.id)
  end

  test "natural text at the character limit fits the byte caps" do
    user = onboarded_user_fixture()
    # 한 typed as three jamo, as some keyboards send it: one grapheme, 9 bytes.
    korean = String.duplicate("한", 2200)
    # A thumbs-up with a skin tone: one grapheme, 8 bytes.
    thumbs = String.duplicate("\u{1F44D}\u{1F3FD}", 2000)

    assert %{"id" => _} =
             json_conn()
             |> api_auth(user)
             |> post(~p"/api/posts", %{body: thumbs, caption: korean})
             |> json_response(201)

    assert %Item{caption: ^korean} = Repo.one!(Item)
  end

  test "a display name the limits accept is stored, however many code points it takes" do
    # 50 graphemes of an e with five accents: 300 code points, 550 bytes.
    # The column was varchar(255), which counts code points: the insert
    # failed with a 500, at onboarding and on every later edit.
    name = String.duplicate("e" <> String.duplicate("́", 5), 50)

    user = user_fixture()
    assert onboard(user, %{display_name: name}) |> json_response(200)
    assert %Profile{display_name: ^name} = Repo.get(Profile, user.id)

    other = onboarded_user_fixture()

    assert %{"display_name" => ^name} =
             json_conn()
             |> api_auth(other)
             |> patch(~p"/api/me", %{display_name: name})
             |> json_response(200)
  end

  test "onboarding checks the display name, and onboards nobody when it's refused" do
    user = user_fixture()

    assert %{"display_name" => [_]} = onboard(user, %{display_name: @zalgo}) |> field_errors()
    assert %User{onboarded_at: nil, handle: nil} = Repo.reload!(user)
    refute Repo.get(Profile, user.id)
  end

  test "a handle or email with a trailing newline is refused" do
    # `$` matches before a final newline, so "alice\n" was a second "alice",
    # distinct to the unique index and shown the same by clients.
    alice = onboarded_user_fixture()
    user = user_fixture()

    assert %{"handle" => [_]} = onboard(user, %{handle: alice.handle <> "\n"}) |> field_errors()
    assert %User{onboarded_at: nil} = Repo.reload!(user)

    conn = json_conn() |> post(~p"/api/auth/request", %{email: "eve@example.com\n"})
    assert %{"email" => [_]} = field_errors(conn)
    refute Repo.get_by(User, email: "eve@example.com\n")
    assert_no_email_sent()
  end

  test "an email over 254 bytes is refused, not a 500" do
    # 13 characters, 613 bytes. The user row took it, and then the sign-in
    # token's varchar(255) `sent_to` didn't.
    email = "x" <> String.duplicate("́", 300) <> "@example.com"

    conn = json_conn() |> post(~p"/api/auth/request", %{email: email})
    assert %{"email" => [message]} = field_errors(conn)
    assert message =~ "byte"
    refute Repo.get_by(User, email: email)
  end

  test "an event whose session id is over 64 bytes is dropped" do
    me = onboarded_user_fixture()
    item = text_post_fixture(onboarded_user_fixture())
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    ok = String.duplicate("s", 64)
    # One grapheme, so the API's maxLength of 64 lets it through: 81 bytes.
    long = "s" <> String.duplicate("́", 40)

    assert %{"accepted" => 1, "rejected" => 1} =
             json_conn()
             |> api_auth(me)
             |> post(~p"/api/events", %{
               events: [
                 %{content_id: item.id, type: "view_start", occurred_at: now, session_id: ok},
                 %{content_id: item.id, type: "view_start", occurred_at: now, session_id: long}
               ]
             })
             |> json_response(202)

    assert Repo.all(from e in Event, select: e.session_id) == [ok]
  end

  test "a JSON body over 1 MB is refused before it's parsed or authenticated" do
    body = Jason.encode!(%{events: [], pad: String.duplicate("a", 1_100_000)})

    assert_error_sent 413, fn -> json_conn() |> post(~p"/api/events", body) end
  end
end
