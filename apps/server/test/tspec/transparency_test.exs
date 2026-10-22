defmodule TSpec.TransparencyTest do
  use TSpec.DataCase, async: true

  import TSpec.AccountsFixtures

  alias TSpec.{Accounts, Transparency}
  alias TSpec.Feed.Settings
  alias TSpec.Transparency.UserSetting

  setup do
    user = onboarded_user_fixture()
    %{user: user, scope: Accounts.scope_for_user(user)}
  end

  test "new users have default settings at version 0", %{user: user} do
    assert %Settings{version: 0, non_personalized: false, topics: t, sources: s} =
             Transparency.get_settings(user.id)

    assert t == %{} and s == %{}
  end

  test "changes are stored sparsely, bump the version, and are broadcast", %{
    user: user,
    scope: scope
  } do
    :ok = Transparency.subscribe_settings(user.id)

    assert {:ok, %Settings{version: 1} = s} =
             Transparency.update_settings(scope, %{
               topics: %{
                 "cooking" => %{multiplier: 1.5},
                 "fitness-and-exercise" => %{hard_off: true}
               },
               sources: %{"trending" => 0.0}
             })

    assert s.topics == %{
             "cooking" => %{multiplier: 1.5, hard_off: false},
             "fitness-and-exercise" => %{multiplier: 1.0, hard_off: true}
           }

    assert s.sources == %{"trending" => 0.0}
    assert_receive {:settings_changed, %Settings{version: 1}}

    # Back to the default removes the row.
    {:ok, s} = Transparency.update_settings(scope, %{topics: %{"cooking" => %{multiplier: 1}}})
    assert s.version == 2
    refute Map.has_key?(s.topics, "cooking")
    assert Repo.aggregate(from(u in UserSetting, where: u.user_id == ^user.id), :count) == 2
  end

  test "invalid changes are rejected whole", %{user: user, scope: scope} do
    assert {:error, :invalid_settings, msg} =
             Transparency.update_settings(scope, %{
               topics: %{"cooking" => %{multiplier: 3}, "nope" => %{hard_off: true}},
               sources: %{"psychic" => 1.0}
             })

    assert msg =~ "cooking: multiplier must be 0..2"
    assert msg =~ "unknown topic: nope"
    assert msg =~ "unknown source: psychic"
    assert Transparency.get_settings(user.id).version == 0
  end

  test "reset clears controls but keeps the non-personalized choice", %{user: user, scope: scope} do
    {:ok, _} =
      Transparency.update_settings(scope, %{
        topics: %{"cooking" => %{multiplier: 2}},
        non_personalized: true
      })

    {:ok, s} = Transparency.reset_settings(scope)

    assert %Settings{version: 2, non_personalized: true, topics: topics} = s
    assert topics == %{}
    assert Transparency.get_settings(user.id) == s
  end

  test "snapshots are deduplicated by content and version", %{user: user} do
    a = %Settings{version: 1, topics: %{"cooking" => %{multiplier: 2.0, hard_off: false}}}
    id = Transparency.snapshot_settings(user.id, a)
    assert Transparency.snapshot_settings(user.id, a) == id
    refute Transparency.snapshot_settings(user.id, %{a | version: 2}) == id
  end
end
