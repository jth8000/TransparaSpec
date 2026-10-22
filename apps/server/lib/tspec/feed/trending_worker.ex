defmodule TSpec.Feed.TrendingWorker do
  @moduledoc """
  Refreshes the global trending pool (`trending_scores`) every few minutes:
  completions of each item in the last 24 hours, decayed by the item's age
  (half-life 48 hours) so yesterday's hit gives way to today's. Aggregate
  over all viewers — it's not personal data about anyone, which is why the
  `trending` source stays on in non-personalized mode.
  """
  use Oban.Worker, queue: :ranking, max_attempts: 3, unique: [period: 60]

  alias TSpec.Repo

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _} =
      Repo.transact(fn ->
        Repo.query!("DELETE FROM trending_scores")

        Repo.query!("""
        INSERT INTO trending_scores (content_id, score, computed_at)
        SELECT v.content_id,
               count(*) * power(0.5, extract(epoch FROM now() - i.published_at) / 172800),
               now()
        FROM view_engagements v
        JOIN content_items i ON i.id = v.content_id
        WHERE v.completed
          AND v.updated_at > now() - interval '24 hours'
          AND i.status = 'ready' AND i.visibility = 'public'
        GROUP BY v.content_id, i.published_at
        """)

        {:ok, :refreshed}
      end)

    :ok
  end
end
