defmodule TSpecWeb.CastErrorRenderer do
  @moduledoc """
  Renders OpenApiSpex request-validation failures in the same `Error` shape
  as every other API error, so clients handle one format.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) when is_list(errors) do
    fields = Enum.group_by(errors, &field_name/1, &OpenApiSpex.Cast.Error.message/1)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_request",
      message: "Request did not match the API schema",
      fields: fields
    })
    |> halt()
  end

  defp field_name(%{path: []}), do: "_request"
  defp field_name(%{path: path}), do: Enum.map_join(path, ".", &to_string/1)
end
