defmodule TSpecWeb.EventController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Events
  alias TSpecWeb.Schemas

  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["events"]
  security [%{"bearer" => []}]

  operation :create,
    summary: "Record a batch of engagement events",
    request_body: {"Events", "application/json", Schemas.EventBatch},
    responses: [
      accepted: {"Recorded", "application/json", Schemas.EventBatchResult},
      unprocessable_entity: {"Invalid", "application/json", Schemas.Error}
    ]

  def create(conn, _params) do
    events = Enum.map(conn.body_params.events, &Map.from_struct/1)

    with {:ok, result} <- Events.record(conn.assigns.current_scope, events) do
      conn |> put_status(:accepted) |> json(result)
    end
  end
end
