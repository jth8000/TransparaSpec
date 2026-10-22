defmodule TSpecWeb.ContentControllerTest do
  use TSpecWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  defp spec, do: TSpecWeb.ApiSpec.spec()

  setup do
    user = onboarded_user_fixture()
    %{user: user, conn: json_conn() |> api_auth(user)}
  end

  test "POST /api/videos returns a processing item and an upload slot", %{conn: conn} do
    body = conn |> post(~p"/api/videos", %{caption: "my clip"}) |> json_response(201)

    assert_schema(body, "VideoUpload", spec())
    assert %{"content" => %{"status" => "processing", "video" => %{"playback_url" => nil}}} = body
    assert %{"upload" => %{"method" => "POST", "form_field" => "file"}} = body
  end

  test "POST /api/posts creates a ready text post", %{conn: conn, user: user} do
    body = conn |> post(~p"/api/posts", %{body: "hello world"}) |> json_response(201)

    assert_schema(body, "ContentItem", spec())

    assert %{"kind" => "text_post", "status" => "ready", "text" => %{"body" => "hello world"}} =
             body

    assert body["author"]["handle"] == user.handle
  end

  test "GET /api/content/:id renders a ready video with playback URLs", %{user: user} do
    item = ready_video_fixture(user)
    body = json_conn() |> get(~p"/api/content/#{item.id}") |> json_response(200)

    assert_schema(body, "ContentItem", spec())
    assert body["video"]["playback_url"] =~ ~r{/dev_media/.+/index\.m3u8$}
    assert body["video"]["thumbnail_url"] =~ ~r{/thumb\.jpg$}
  end

  test "PATCH and DELETE /api/content/:id", %{conn: conn, user: user} do
    item = text_post_fixture(user)

    assert %{"caption" => "new"} =
             conn |> patch(~p"/api/content/#{item.id}", %{caption: "new"}) |> json_response(200)

    assert conn |> delete(~p"/api/content/#{item.id}") |> response(204)
    assert json_conn() |> get(~p"/api/content/#{item.id}") |> json_response(404)
  end

  test "GET /api/topics lists the taxonomy" do
    body = json_conn() |> get(~p"/api/topics") |> json_response(200)

    assert_schema(body, "TopicList", spec())
    assert body["max_creator_topics"] == 3

    assert %{"name" => "Fitness and Exercise", "tier" => 2, "parent" => "healthy-living"} =
             Enum.find(body["topics"], &(&1["slug"] == "fitness-and-exercise"))
  end

  test "creators label content with topics, and labels render merged by topic",
       %{conn: conn, user: user} do
    body =
      conn
      |> post(~p"/api/posts", %{body: "squats", topics: ["fitness-and-exercise"]})
      |> json_response(201)

    assert_schema(body, "ContentItem", spec())

    assert [%{"slug" => "fitness-and-exercise", "confidence" => 1.0, "sources" => ["creator"]}] =
             body["topics"]

    # A model label on the same topic merges into one entry (max confidence).
    TSpec.Repo.insert!(%TSpec.Content.ContentTopic{
      content_id: body["id"],
      topic_id: TSpec.Content.topics_by_slug()["fitness-and-exercise"].id,
      source: "model",
      confidence: 0.6
    })

    shown = json_conn() |> get(~p"/api/content/#{body["id"]}") |> json_response(200)
    assert [%{"confidence" => 1.0, "sources" => ["creator", "model"]}] = shown["topics"]

    edited =
      conn |> patch(~p"/api/content/#{body["id"]}", %{topics: ["cooking"]}) |> json_response(200)

    assert edited["caption"] == nil

    assert Enum.map(edited["topics"], &{&1["slug"], &1["sources"]}) ==
             [{"cooking", ["creator"]}, {"fitness-and-exercise", ["model"]}]

    _ = user
  end

  test "invalid topics are a 422", %{conn: conn} do
    body =
      conn |> post(~p"/api/videos", %{topics: ["not-a-topic"]}) |> json_response(422)

    assert %{"error" => "validation_failed", "fields" => %{"topics" => [_]}} = body

    # The schema caps the list at three before the context sees it.
    assert conn
           |> post(~p"/api/posts", %{body: "x", topics: ~w(a b c d)})
           |> json_response(422)
  end

  test "PATCH with an empty caption clears it; omitting it keeps it",
       %{conn: conn, user: user} do
    item = text_post_fixture(user, caption: "keep me")

    assert %{"caption" => "keep me"} =
             conn |> patch(~p"/api/content/#{item.id}", %{topics: []}) |> json_response(200)

    assert %{"caption" => nil} =
             conn |> patch(~p"/api/content/#{item.id}", %{caption: ""}) |> json_response(200)
  end

  test "creating content requires onboarding" do
    newbie = user_fixture()

    assert %{"error" => "onboarding_required"} =
             json_conn()
             |> api_auth(newbie)
             |> post(~p"/api/posts", %{body: "x"})
             |> json_response(403)
  end
end
