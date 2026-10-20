defmodule TSpecWeb.HealthController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpecWeb.Schemas

  tags ["system"]

  operation :show,
    summary: "Health check",
    responses: [ok: {"Service is up", "application/json", Schemas.Health}]

  def show(conn, _params), do: json(conn, %{status: "ok"})
end
