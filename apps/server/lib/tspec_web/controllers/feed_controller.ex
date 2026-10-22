defmodule TSpecWeb.FeedController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Feed
  alias TSpecWeb.{ContentJSON, FeedJSON, Schemas}

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

  operation :for_you,
    summary: "Your ranked feed, with an explanation for every item",
    parameters: [
      session: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :string, format: :uuid},
        description: "The feed session from the previous page; omit to start a new feed"
      ],
      limit: [in: :query, type: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 50}]
    ],
    security: [%{"bearer" => []}],
    responses: [
      ok: {"Page", "application/json", Schemas.ForYouPage},
      unprocessable_entity: {"Bad session", "application/json", Schemas.Error}
    ]

  def for_you(conn, params) do
    opts = params |> Map.take([:limit]) |> Enum.to_list()

    with {:ok, page} <- Feed.for_you(conn.assigns.current_scope, params[:session], opts) do
      json(conn, FeedJSON.for_you_page(page))
    end
  end

  defp opts(params), do: params |> Map.take([:cursor, :limit]) |> Enum.to_list()

  defp render_page(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    json(conn, %{items: Enum.map(items, &ContentJSON.item/1), next_cursor: next_cursor})
  end

  defp render_page(_conn, {:error, :invalid_cursor}),
    do: {:error, :invalid_cursor, "The cursor is invalid"}
end
