defmodule TSpecWeb.UserJSON do
  @moduledoc "JSON shapes for users (`Schemas.Me`, `Schemas.PublicProfile`)."

  alias TSpec.Accounts
  alias TSpec.Accounts.Scope

  def me(%Scope{user: user} = scope) do
    profile = Accounts.get_profile(user)

    %{
      id: user.id,
      email: user.email,
      handle: user.handle,
      display_name: profile.display_name,
      bio: profile.bio,
      avatar_url: profile.avatar_url,
      onboarded: Scope.onboarded?(scope),
      consent_version: scope.consent_version
    }
  end

  def public_profile(user, %{followers: followers, following: following}, followed_by_me) do
    profile = user.profile || Accounts.get_profile(user)

    %{
      id: user.id,
      handle: user.handle,
      display_name: profile.display_name,
      bio: profile.bio,
      avatar_url: profile.avatar_url,
      followers_count: followers,
      following_count: following,
      followed_by_me: followed_by_me
    }
  end
end
