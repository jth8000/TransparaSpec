defmodule TSpecWeb.FeedJSON do
  @moduledoc "JSON shapes for the For You feed (`Schemas.ForYouPage`, `Schemas.ForYouItem`)."

  alias TSpecWeb.ContentJSON

  @doc "A served For You item: the content plus the impression that explains it."
  def for_you_item(%{item: item, impression_id: impression_id, candidate_source: source}) do
    item
    |> ContentJSON.item()
    |> Map.merge(%{impression_id: impression_id, candidate_source: source})
  end

  def for_you_page(%{session_id: session_id, rev: rev, items: items}) do
    %{session_id: session_id, rev: rev, items: Enum.map(items, &for_you_item/1)}
  end
end
