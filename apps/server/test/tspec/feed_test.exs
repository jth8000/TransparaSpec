defmodule TSpec.FeedTest do
  use TSpec.DataCase, async: true
  use ExUnitProperties

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Content, Feed, Social}
  alias TSpec.Content.Item

  test "latest shows ready public items, newest first" do
    author = onboarded_user_fixture()
    older = text_post_fixture(author)
    newer = text_post_fixture(author)

    {:ok, {_processing, _upload}} =
      Content.create_video_upload(Accounts.scope_for_user(author), %{})

    removed = text_post_fixture(author)
    :ok = Content.remove_item(Accounts.scope_for_user(author), removed.id)

    assert {:ok, %{items: items, next_cursor: nil}} = Feed.latest(nil)
    assert Enum.map(items, & &1.id) == [newer.id, older.id]
  end

  test "following shows only followed accounts" do
    me = onboarded_user_fixture()
    followed = onboarded_user_fixture()
    stranger = onboarded_user_fixture()
    scope = Accounts.scope_for_user(me)
    :ok = Social.follow(scope, followed)

    mine = text_post_fixture(followed)
    _theirs = text_post_fixture(stranger)

    assert {:ok, %{items: [item]}} = Feed.following(scope)
    assert item.id == mine.id
  end

  test "bad cursors are rejected" do
    assert {:error, :invalid_cursor} = Feed.latest(nil, cursor: "garbage")
    assert {:error, :invalid_cursor} = Feed.latest(nil, cursor: Base.url_encode64("[1,2]"))
  end

  test "limit is clamped" do
    author = onboarded_user_fixture()
    for _ <- 1..3, do: text_post_fixture(author)

    assert {:ok, %{items: [_]}} = Feed.latest(nil, limit: 0)
    assert {:ok, %{items: items}} = Feed.latest(nil, limit: 500)
    assert length(items) == 3
  end

  # Many items sharing timestamps is the hard case for keyset pagination:
  # the id tie-breaker must keep every item exactly once, in order.
  property "paging through returns every item exactly once, in order" do
    author = onboarded_user_fixture()
    base = ~U[2026-01-01 00:00:00.000000Z]

    check all(
            offsets <- list_of(integer(0..5), min_length: 1, max_length: 25),
            limit <- integer(1..7),
            max_runs: 25
          ) do
      Repo.delete_all(Item)

      for offset <- offsets do
        item = text_post_fixture(author)

        Repo.update_all(from(i in Item, where: i.id == ^item.id),
          set: [published_at: DateTime.add(base, offset, :second)]
        )
      end

      expected =
        Repo.all(from i in Item, order_by: [desc: i.published_at, desc: i.id], select: i.id)

      assert collect_pages(limit, nil, []) == expected
    end
  end

  defp collect_pages(limit, cursor, acc) do
    {:ok, %{items: items, next_cursor: next}} = Feed.latest(nil, limit: limit, cursor: cursor)
    acc = acc ++ Enum.map(items, & &1.id)
    if next, do: collect_pages(limit, next, acc), else: acc
  end
end
