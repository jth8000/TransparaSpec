defmodule TSpec.Transparency do
  @moduledoc """
  User-facing algorithm controls and explanations (ADR 0006/0011/0012).
  Phase 1a M2: the non-personalized mode switch. Settings, explanations
  and the dashboard land in later milestones.
  """
  import Ecto.Query, warn: false

  alias TSpec.Repo
  alias TSpec.Accounts.{Scope, User}
  alias TSpec.Feed.ViewEngagement

  # Events up to 7 days old are accepted (Events.record/2), so a view can
  # still change for about that long. Views older than this can't.
  @open_view_window_days 8

  @doc """
  Turns non-personalized mode on or off.

  Turning it **on** also clears `learnable` on the user's views that could
  still receive events, in the same transaction, so nothing watched from
  here on is learned — even by a worker that runs after the mode is turned
  back off (ADR 0012). `learnable` never goes back to true.

  Takes `FOR UPDATE` on the user row, which `Events.record/2` reads under
  `FOR SHARE`: a recording transaction either finishes first (and its views
  are then ratcheted here) or starts after and sees the new mode.
  """
  def set_non_personalized(%Scope{user: %User{id: user_id}}, enabled?)
      when is_boolean(enabled?) do
    Repo.transact(fn ->
      user = from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE") |> Repo.one!()
      user = user |> Ecto.Changeset.change(non_personalized: enabled?) |> Repo.update!()

      if enabled? do
        since = DateTime.add(DateTime.utc_now(), -@open_view_window_days, :day)

        from(v in ViewEngagement,
          where: v.user_id == ^user_id and v.learnable and v.inserted_at > ^since
        )
        |> Repo.update_all(set: [learnable: false])
      end

      {:ok, user}
    end)
  end
end
