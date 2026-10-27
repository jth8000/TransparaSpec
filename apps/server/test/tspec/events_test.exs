defmodule TSpec.EventsTest do
  use TSpec.DataCase, async: true

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Content, Events}
  alias TSpec.Events.{Event, PartitionWorker}

  setup do
    viewer = onboarded_user_fixture()
    item = text_post_fixture(onboarded_user_fixture())
    %{scope: Accounts.scope_for_user(viewer), item: item}
  end

  defp event(item, overrides \\ %{}) do
    Map.merge(
      %{content_id: item.id, type: "view_start", occurred_at: DateTime.utc_now()},
      overrides
    )
  end

  test "stamps the server-side consent version, ignoring anything the client sends", %{
    scope: scope,
    item: item
  } do
    forged = event(item, %{consent_version: 999})

    assert {:ok, %{accepted: 1, rejected: 0}} = Events.record(scope, [forged])
    assert [%Event{consent_version: 1, user_id: user_id}] = Repo.all(Event)
    assert user_id == scope.user.id
  end

  test "refuses callers without consent", %{item: item} do
    not_onboarded = Accounts.scope_for_user(user_fixture())

    assert {:error, :consent_required} = Events.record(not_onboarded, [event(item)])
    assert {:error, :consent_required} = Events.record(nil, [event(item)])
    assert Repo.all(Event) == []
  end

  test "drops malformed events but keeps the rest", %{scope: scope, item: item} do
    now = DateTime.utc_now()

    events = [
      event(item, %{type: "watch_progress", value: 3}),
      event(item, %{type: "teleport"}),
      event(item, %{content_id: Ecto.UUID.generate()}),
      event(item, %{content_id: "not-a-uuid"}),
      event(item, %{occurred_at: DateTime.add(now, -8, :day)}),
      event(item, %{occurred_at: DateTime.add(now, 1, :hour)}),
      %{type: "skip"}
    ]

    assert {:ok, %{accepted: 1, rejected: 6}} = Events.record(scope, events)
    assert [%Event{type: "watch_progress", value: 3.0}] = Repo.all(Event)
  end

  test "ignores removed content", %{scope: scope, item: item} do
    :ok = Content.remove_item(Accounts.scope_for_user(item.author), item.id)
    assert {:ok, %{accepted: 0, rejected: 1}} = Events.record(scope, [event(item)])
  end

  test "ignores content the caller can't see (someone else's unprocessed upload)", %{
    scope: scope
  } do
    other = Accounts.scope_for_user(onboarded_user_fixture())
    {:ok, {processing, _upload}} = Content.create_video_upload(other, %{})

    assert {:ok, %{accepted: 0, rejected: 1}} = Events.record(scope, [event(processing)])

    # The author can record events on their own item while it processes.
    assert {:ok, %{accepted: 1}} = Events.record(other, [event(processing)])
  end

  test "rejects oversized batches", %{scope: scope, item: item} do
    batch = List.duplicate(event(item), Events.max_batch() + 1)
    assert {:error, :batch_too_large} = Events.record(scope, batch)
  end

  test "rows land in this month's partition", %{scope: scope, item: item} do
    {:ok, _} = Events.record(scope, [event(item)])
    this_month = Date.beginning_of_month(Date.utc_today())

    %{rows: [[partition]]} = Repo.query!("SELECT tableoid::regclass::text FROM engagement_events")
    assert partition == PartitionWorker.partition_name("engagement_events", this_month)
  end
end
