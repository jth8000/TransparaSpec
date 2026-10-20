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

  test "creating content requires onboarding" do
    newbie = user_fixture()

    assert %{"error" => "onboarding_required"} =
             json_conn()
             |> api_auth(newbie)
             |> post(~p"/api/posts", %{body: "x"})
             |> json_response(403)
  end
end
