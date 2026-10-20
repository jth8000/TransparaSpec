defmodule TSpec.ContentFixtures do
  @moduledoc "Test helpers for content items."

  alias TSpec.{Accounts, Content}

  def text_post_fixture(user, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{body: "hello #{System.unique_integer([:positive])}"})
    {:ok, item} = Content.create_text_post(Accounts.scope_for_user(user), attrs)
    item
  end

  @doc "A short video that has been through the provider and is ready."
  def ready_video_fixture(user, attrs \\ %{}) do
    {:ok, {item, upload}} =
      Content.create_video_upload(Accounts.scope_for_user(user), Enum.into(attrs, %{}))

    :ok =
      Content.apply_video_event("local", %{
        "type" => "ready",
        "asset_id" => upload.asset_id,
        "playback_id" => upload.asset_id,
        "duration_ms" => 2000,
        "width" => 360,
        "height" => 640
      })

    {:ok, item} = Content.get_item(nil, item.id)
    item
  end
end
