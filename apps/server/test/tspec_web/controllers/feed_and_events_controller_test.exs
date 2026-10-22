defmodule TSpecWeb.FeedAndEventsControllerTest do
  use TSpecWeb.ConnCase, async: true
  use Oban.Testing, repo: TSpec.Repo

  import OpenApiSpex.TestAssertions
  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Social}

  defp spec, do: TSpecWeb.ApiSpec.spec()

  test "GET /api/feed/latest pages with a cursor" do
    author = onboarded_user_fixture()
    [first, second, third] = for _ <- 1..3, do: text_post_fixture(author)

    page1 = json_conn() |> get(~p"/api/feed/latest?limit=2") |> json_response(200)
    assert_schema(page1, "FeedPage", spec())
    assert Enum.map(page1["items"], & &1["id"]) == [third.id, second.id]

    page2 =
      json_conn()
      |> get(~p"/api/feed/latest?limit=2&cursor=#{page1["next_cursor"]}")
      |> json_response(200)

    assert Enum.map(page2["items"], & &1["id"]) == [first.id]
    assert page2["next_cursor"] == nil
  end

  test "GET /api/feed/latest rejects bad cursors" do
    assert %{"error" => "invalid_cursor"} =
             json_conn() |> get(~p"/api/feed/latest?cursor=nope") |> json_response(422)
  end

  test "GET /api/feed/following requires sign-in and shows followed accounts' videos" do
    me = onboarded_user_fixture()
    creator = onboarded_user_fixture()
    :ok = Social.follow(Accounts.scope_for_user(me), creator)
    video = ready_video_fixture(creator)

    assert json_conn() |> get(~p"/api/feed/following") |> json_response(401)

    page = json_conn() |> api_auth(me) |> get(~p"/api/feed/following") |> json_response(200)
    assert [%{"id" => id, "video" => %{"playback_url" => url}}] = page["items"]
    assert id == video.id
    assert url =~ "index.m3u8"
  end

  test "POST /api/events records a batch" do
    me = onboarded_user_fixture()
    item = text_post_fixture(onboarded_user_fixture())
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    body =
      json_conn()
      |> api_auth(me)
      |> post(~p"/api/events", %{
        events: [
          %{content_id: item.id, type: "view_start", occurred_at: now},
          %{content_id: item.id, type: "complete", occurred_at: now, value: 4.2}
        ]
      })
      |> json_response(202)

    assert_schema(body, "EventBatchResult", spec())
    assert body == %{"accepted" => 2, "rejected" => 0}
  end

  test "POST /api/events with a view_id tracks the view and queues the affinity worker" do
    me = onboarded_user_fixture()
    item = ready_video_fixture(onboarded_user_fixture(), topics: ["cooking"])
    view_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    assert %{"accepted" => 2} =
             json_conn()
             |> api_auth(me)
             |> post(~p"/api/events", %{
               events: [
                 %{content_id: item.id, view_id: view_id, type: "view_start", occurred_at: now},
                 %{
                   content_id: item.id,
                   view_id: view_id,
                   type: "complete",
                   occurred_at: now,
                   value: 2.0
                 }
               ]
             })
             |> json_response(202)

    assert %{completed: true, target_delta: 1.0, dirty: true} =
             TSpec.Repo.get!(TSpec.Feed.ViewEngagement, view_id)

    assert_enqueued(worker: TSpec.Feed.AffinityWorker, args: %{user_id: me.id})

    # A malformed view_id fails schema validation.
    assert json_conn()
           |> api_auth(me)
           |> post(~p"/api/events", %{
             events: [
               %{content_id: item.id, view_id: "nope", type: "view_start", occurred_at: now}
             ]
           })
           |> json_response(422)
  end

  test "POST /api/events validates against the schema" do
    me = onboarded_user_fixture()

    assert %{"error" => "invalid_request"} =
             json_conn()
             |> api_auth(me)
             |> post(~p"/api/events", %{events: [%{type: "teleport"}]})
             |> json_response(422)
  end
end
