defmodule TSpecWeb.FeedChannelTest do
  # Not async: feed sessions run under the app's supervisor (shared sandbox).
  use TSpecWeb.ChannelCase, async: false

  # Stopping sessions mid-query at test exit logs harmless disconnects.
  @moduletag :capture_log

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Feed, Transparency}

  setup do
    on_exit(&TSpec.DataCase.stop_feed_sessions/0)

    user = onboarded_user_fixture()
    creator = onboarded_user_fixture()
    for _ <- 1..4, do: text_post_fixture(creator, topics: ["fitness-and-exercise"])
    for _ <- 1..8, do: text_post_fixture(onboarded_user_fixture(), topics: ["cooking"])

    {:ok, socket} = connect(TSpecWeb.UserSocket, %{"token" => api_token_fixture(user)})
    %{user: user, scope: Accounts.scope_for_user(user), socket: socket}
  end

  defp first_page(scope) do
    {:ok, page} = Feed.for_you(scope, nil, limit: 5)
    page
  end

  test "update_settings saves the change and pushes a re-ranked tail with rendered items",
       %{socket: socket, scope: scope} do
    page = first_page(scope)
    {:ok, _, socket} = subscribe_and_join(socket, "feed_session:#{page.session_id}", %{})

    first = hd(page.items)
    push(socket, "at", %{"impression_id" => first.impression_id, "rev" => 0})

    ref =
      push(socket, "update_settings", %{
        "topics" => %{"fitness-and-exercise" => %{"hard_off" => true}}
      })

    assert_reply ref, :ok, %{settings_version: 1}

    assert_push "feed_reranked", %{rev: 1, after_impression_id: after_id, items: items}, 2_000
    assert after_id == first.impression_id
    assert items != []

    for item <- items do
      assert %{impression_id: _, candidate_source: _, kind: _, topics: topics} = item
      refute Enum.any?(topics, &(&1.slug == "fitness-and-exercise"))
    end

    assert Transparency.get_settings(scope.user.id).topics["fitness-and-exercise"].hard_off
  end

  test "invalid settings are rejected in the reply", %{socket: socket, scope: scope} do
    page = first_page(scope)
    {:ok, _, socket} = subscribe_and_join(socket, "feed_session:#{page.session_id}", %{})

    ref = push(socket, "update_settings", %{"topics" => %{"cooking" => %{"multiplier" => 9}}})
    assert_reply ref, :error, %{error: :invalid_settings, message: message}
    assert message =~ "multiplier"
    refute_push "feed_reranked", _
  end

  test "joining needs a valid session id; another user's session id gets them their own feed",
       %{socket: socket, scope: scope} do
    assert {:error, %{reason: "invalid_session"}} =
             subscribe_and_join(socket, "feed_session:not-a-uuid", %{})

    page = first_page(scope)

    # Someone else joining the same id gets a separate session (keyed by
    # user) and never sees this user's pushes.
    intruder = onboarded_user_fixture()
    {:ok, other} = connect(TSpecWeb.UserSocket, %{"token" => api_token_fixture(intruder)})
    {:ok, _, _} = subscribe_and_join(other, "feed_session:#{page.session_id}", %{})

    {:ok, _} = Transparency.update_settings(scope, %{sources: %{"fresh" => 2.0}})
    refute_push "feed_reranked", _, 300
  end

  test "parse_changes only accepts known keys" do
    assert TSpecWeb.FeedChannel.parse_changes(%{
             "topics" => %{"cooking" => %{"multiplier" => 1.5, "evil" => true}},
             "sources" => %{"fresh" => 0.5},
             "non_personalized" => true,
             "other" => 1
           }) == %{
             topics: %{"cooking" => %{multiplier: 1.5}},
             sources: %{"fresh" => 0.5},
             non_personalized: true
           }
  end
end
