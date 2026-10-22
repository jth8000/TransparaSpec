defmodule TSpec.Feed do
  @moduledoc """
  Feeds:

    * `for_you/3` — ranked by the explainable ranker (ADR 0006), served by a
      per-client `TSpec.Feed.Session` (ADR 0011); every item comes with the
      impression id that explains it
    * `latest/2` — every public ready item, newest first
    * `following/2` — the same, from accounts the user follows

  Pagination is keyset-based on `(published_at, id)` with an opaque cursor,
  so pages stay stable while new items are published.
  """
  import Ecto.Query, warn: false

  alias TSpec.{Content, Repo, Social}
  alias TSpec.Accounts.Scope
  alias TSpec.Content.Item
  alias TSpec.Feed.Session

  @default_limit 10
  @max_limit 50

  @doc """
  The next page of the scope user's For You feed for `session_id` (a client
  generated UUID; a fresh one starts a new feed). Returns
  `{:ok, %{session_id, rev, items: [%{item, impression_id, candidate_source}]}}`.
  """
  def for_you(%Scope{} = scope, session_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)
    session_id = session_id || Ecto.UUID.generate()

    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         {:ok, pid} <- Session.ensure(scope, session_id),
         {:ok, page} <- Session.next_page(pid, limit) do
      {:ok, %{session_id: session_id, rev: page.rev, items: load_served(page.items)}}
    else
      :error -> {:error, :invalid_session}
      error -> error
    end
  end

  @doc """
  Loads served `{%Scored{}, impression_id}` pairs as renderable items, in
  order. Items removed since they were ranked are dropped.
  """
  def load_served(pairs) do
    ids = Enum.map(pairs, fn {s, _} -> s.content_id end)

    items =
      from(i in Item, where: i.id in ^ids and i.status == "ready")
      |> Repo.all()
      |> Content.preload_for_render()
      |> Map.new(&{&1.id, &1})

    for {s, impression_id} <- pairs, item = items[s.content_id], item != nil do
      %{item: item, impression_id: impression_id, candidate_source: s.candidate_source}
    end
  end

  @doc "Newest public items from everyone."
  def latest(_scope, opts \\ []), do: page(public_items(), opts)

  @doc "Newest public items from accounts the scope user follows."
  def following(%Scope{} = scope, opts \\ []) do
    public_items()
    |> where([i], i.author_id in subquery(Social.followee_ids_query(scope)))
    |> page(opts)
  end

  defp public_items do
    from i in Item, where: i.status == "ready" and i.visibility == "public"
  end

  defp page(query, opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    with {:ok, query} <- after_cursor(query, Keyword.get(opts, :cursor)) do
      rows =
        query
        |> order_by([i], desc: i.published_at, desc: i.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      {items, rest} = Enum.split(rows, limit)
      next_cursor = if rest != [], do: encode_cursor(List.last(items))

      {:ok, %{items: Content.preload_for_render(items), next_cursor: next_cursor}}
    end
  end

  defp after_cursor(query, nil), do: {:ok, query}

  defp after_cursor(query, cursor) do
    with {:ok, {published_at, id}} <- decode_cursor(cursor) do
      {:ok,
       where(
         query,
         [i],
         fragment(
           "(?, ?) < (?, ?)",
           i.published_at,
           i.id,
           type(^published_at, :utc_datetime_usec),
           type(^id, :binary_id)
         )
       )}
    end
  end

  @doc false
  def encode_cursor(%Item{published_at: published_at, id: id}) do
    Jason.encode!([DateTime.to_iso8601(published_at), id]) |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [iso, id]} when is_binary(iso) and is_binary(id) <- Jason.decode(json),
         {:ok, published_at, _offset} <- DateTime.from_iso8601(iso),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {published_at, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end
end
