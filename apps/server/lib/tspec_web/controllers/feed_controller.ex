defmodule TSpecWeb.FeedController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Feed
  alias TSpecWeb.{ContentJSON, Schemas}

  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["feed"]

  @page_params [
    cursor: [in: :query, type: :string, description: "From the previous page's `next_cursor`"],
    limit: [in: :query, type: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 50}]
  ]

  operation :latest,
    summary: "Newest public items from everyone (non-personalized)",
    parameters: @page_params,
    responses: [
      ok: {"Page", "application/json", Schemas.FeedPage},
      unprocessable_entity: {"Bad cursor", "application/json", Schemas.Error}
    ]

  def latest(conn, params),
    do: render_page(conn, Feed.latest(conn.assigns.current_scope, opts(params)))

  operation :following,
    summary: "Newest public items from accounts you follow",
    parameters: @page_params,
    security: [%{"bearer" => []}],
    responses: [
      ok: {"Page", "application/json", Schemas.FeedPage},
      unprocessable_entity: {"Bad cursor", "application/json", Schemas.Error}
    ]

  def following(conn, params),
    do: render_page(conn, Feed.following(conn.assigns.current_scope, opts(params)))

  defp opts(params), do: params |> Map.take([:cursor, :limit]) |> Enum.to_list()

  defp render_page(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    json(conn, %{items: Enum.map(items, &ContentJSON.item/1), next_cursor: next_cursor})
  end

  defp render_page(_conn, {:error, :invalid_cursor}),
    do: {:error, :invalid_cursor, "The cursor is invalid"}
end
