defmodule TSpec.Social do
  @moduledoc """
  The social graph: follows (Phase 0); blocks, mutes, likes and comments later.
  """
  import Ecto.Query, warn: false

  alias TSpec.Repo
  alias TSpec.Accounts.{Scope, User}
  alias TSpec.Social.Follow

  @doc "Follows `followee`. Idempotent. Users can't follow themselves."
  def follow(%Scope{user: %User{id: id}}, %User{id: id}), do: {:error, :cannot_follow_self}

  def follow(%Scope{user: follower}, %User{} = followee) do
    %Follow{follower_id: follower.id, followee_id: followee.id}
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:follower_id, :followee_id])
    |> case do
      {:ok, _follow} -> :ok
      {:error, _changeset} = error -> error
    end
  end

  @doc "Unfollows `followee`. Idempotent."
  def unfollow(%Scope{user: follower}, %User{} = followee) do
    Repo.delete_all(
      from f in Follow, where: f.follower_id == ^follower.id and f.followee_id == ^followee.id
    )

    :ok
  end

  def following?(%Scope{user: follower}, %User{} = followee) do
    Repo.exists?(
      from f in Follow, where: f.follower_id == ^follower.id and f.followee_id == ^followee.id
    )
  end

  @doc "Returns `%{followers: n, following: n}` for a user."
  def counts(%User{id: user_id}) do
    followers = Repo.aggregate(from(f in Follow, where: f.followee_id == ^user_id), :count)
    following = Repo.aggregate(from(f in Follow, where: f.follower_id == ^user_id), :count)
    %{followers: followers, following: following}
  end

  @doc "Query of ids the scope's user follows (for feed queries)."
  def followee_ids_query(%Scope{user: %User{id: user_id}}), do: followee_ids_query(user_id)

  def followee_ids_query(user_id) when is_binary(user_id) do
    from f in Follow, where: f.follower_id == ^user_id, select: f.followee_id
  end
end
