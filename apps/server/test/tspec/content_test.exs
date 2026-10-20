defmodule TSpec.ContentTest do
  use TSpec.DataCase, async: true
  use Oban.Testing, repo: TSpec.Repo

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Content}
  alias TSpec.Content.{DeleteAssetWorker, Item}

  setup do
    author = onboarded_user_fixture()
    %{author: author, scope: Accounts.scope_for_user(author)}
  end

  describe "text posts" do
    test "are published immediately", %{scope: scope} do
      assert {:ok, %Item{kind: "text_post", status: "ready"} = item} =
               Content.create_text_post(scope, %{body: "first!"})

      assert item.text_post.body == "first!"
      assert %DateTime{} = item.published_at
    end

    test "require a body", %{scope: scope} do
      assert {:error, changeset} = Content.create_text_post(scope, %{})
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "video uploads" do
    test "start in processing with a provider upload slot", %{scope: scope} do
      assert {:ok, {item, upload}} = Content.create_video_upload(scope, %{caption: "hi"})

      assert %Item{kind: "short_video", status: "processing", caption: "hi"} = item
      assert item.short_video.provider == "local"
      assert item.short_video.asset_id == upload.asset_id
      assert upload.method == "POST"
      assert upload.form_field == "file"
      assert upload.url =~ "/dev/video-uploads/"
    end

    test "a ready event publishes the item and notifies the author", %{scope: scope} do
      {:ok, {item, upload}} = Content.create_video_upload(scope, %{})
      Content.subscribe_content_status(scope)

      assert :ok = Content.apply_video_event("local", ready_event(upload.asset_id))

      assert_receive {:content_status, %{content_id: id, status: "ready"}}
      assert id == item.id

      {:ok, item} = Content.get_item(nil, item.id)
      assert item.status == "ready"
      assert item.short_video.duration_ms == 2000
      assert %DateTime{} = item.published_at
    end

    test "a failed event marks the item failed with a reason", %{scope: scope} do
      {:ok, {item, upload}} = Content.create_video_upload(scope, %{})
      Content.subscribe_content_status(scope)

      event = %{"type" => "failed", "asset_id" => upload.asset_id, "reason" => "too_long"}
      assert :ok = Content.apply_video_event("local", event)

      assert_receive {:content_status, %{status: "failed"}}
      {:ok, item} = Content.get_item(scope, item.id)
      assert item.status == "failed"
      assert item.short_video.failure_reason == "too_long"
    end

    test "events are idempotent and ignore unknown assets", %{scope: scope} do
      {:ok, {_item, upload}} = Content.create_video_upload(scope, %{})

      assert :ok = Content.apply_video_event("local", ready_event(upload.asset_id))
      assert :ok = Content.apply_video_event("local", ready_event(upload.asset_id))
      assert :ok = Content.apply_video_event("local", ready_event(Ecto.UUID.generate()))
      assert :ok = Content.apply_video_event("other", ready_event(upload.asset_id))
    end
  end

  describe "visibility" do
    test "processing items are visible only to their author", %{scope: scope} do
      {:ok, {item, _upload}} = Content.create_video_upload(scope, %{})
      stranger = Accounts.scope_for_user(onboarded_user_fixture())

      assert {:ok, _} = Content.get_item(scope, item.id)
      assert {:error, :not_found} = Content.get_item(stranger, item.id)
      assert {:error, :not_found} = Content.get_item(nil, item.id)
    end

    test "ready items are public", %{author: author} do
      item = text_post_fixture(author)
      assert {:ok, _} = Content.get_item(nil, item.id)
    end

    test "garbage ids are not found" do
      assert {:error, :not_found} = Content.get_item(nil, "not-a-uuid")
    end
  end

  describe "editing and removal" do
    test "authors can edit captions; others can't", %{author: author, scope: scope} do
      item = text_post_fixture(author)
      stranger = Accounts.scope_for_user(onboarded_user_fixture())

      assert {:ok, %Item{caption: "edited"}} =
               Content.update_caption(scope, item.id, %{caption: "edited"})

      assert {:error, :forbidden} = Content.update_caption(stranger, item.id, %{caption: "x"})
    end

    test "removing a video hides it and schedules asset deletion", %{author: author, scope: scope} do
      item = ready_video_fixture(author)

      assert :ok = Content.remove_item(scope, item.id)
      assert {:error, :not_found} = Content.get_item(nil, item.id)
      assert {:error, :not_found} = Content.get_item(scope, item.id)
      assert {:error, :not_found} = Content.remove_item(scope, item.id)

      assert_enqueued(
        worker: DeleteAssetWorker,
        args: %{provider: "local", asset_id: item.short_video.asset_id}
      )
    end
  end

  defp ready_event(asset_id) do
    %{
      "type" => "ready",
      "asset_id" => asset_id,
      "playback_id" => asset_id,
      "duration_ms" => 2000,
      "width" => 360,
      "height" => 640
    }
  end
end
