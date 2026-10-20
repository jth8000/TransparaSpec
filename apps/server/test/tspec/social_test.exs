defmodule TSpec.SocialTest do
  use TSpec.DataCase, async: true

  import TSpec.AccountsFixtures

  alias TSpec.{Accounts, Social}

  setup do
    alice = onboarded_user_fixture()
    bob = onboarded_user_fixture()
    %{alice: alice, bob: bob, alice_scope: Accounts.scope_for_user(alice)}
  end

  test "follow / unfollow are idempotent", %{alice_scope: scope, bob: bob} do
    assert :ok = Social.follow(scope, bob)
    assert :ok = Social.follow(scope, bob)
    assert Social.following?(scope, bob)
    assert Social.counts(bob) == %{followers: 1, following: 0}

    assert :ok = Social.unfollow(scope, bob)
    assert :ok = Social.unfollow(scope, bob)
    refute Social.following?(scope, bob)
  end

  test "can't follow yourself", %{alice: alice, alice_scope: scope} do
    assert {:error, :cannot_follow_self} = Social.follow(scope, alice)
  end
end
