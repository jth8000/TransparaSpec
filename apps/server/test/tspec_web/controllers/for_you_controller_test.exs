defmodule TSpecWeb.ForYouControllerTest do
  # Not async: feed sessions run under the app's supervisor (shared sandbox).
  use TSpecWeb.ConnCase, async: false

  # Stopping sessions mid-query at test exit logs harmless disconnects.
  @moduletag :capture_log

  import OpenApiSpex.TestAssertions
  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  defp spec, do: TSpecWeb.ApiSpec.spec()

  setup do
    on_exit(&TSpec.DataCase.stop_feed_sessions/0)
  end

  test "GET /api/feed/for-you serves ranked pages with an impression per item, continuing a session" do
    me = onboarded_user_fixture()
    creator = onboarded_user_fixture()
    for _ <- 1..6, do: text_post_fixture(creator, topics: ["cooking"])
    conn = json_conn() |> api_auth(me)

    body = conn |> get(~p"/api/feed/for-you?limit=3") |> json_response(200)
    assert_schema(body, "ForYouPage", spec())
    assert %{"rev" => 0, "session_id" => sid, "items" => [_, _, _] = first} = body
    assert Enum.all?(first, &match?(%{"impression_id" => _, "candidate_source" => _}, &1))

    next = conn |> get(~p"/api/feed/for-you?session=#{sid}&limit=3") |> json_response(200)
    assert next["session_id"] == sid

    seen = Enum.map(first, & &1["id"])
    refute Enum.any?(next["items"], &(&1["id"] in seen))
  end

  test "GET /api/feed/for-you requires sign-in and validates the session id" do
    assert json_conn() |> get(~p"/api/feed/for-you") |> json_response(401)

    assert json_conn()
           |> api_auth(onboarded_user_fixture())
           |> get(~p"/api/feed/for-you?session=nope")
           |> json_response(422)
  end
end
