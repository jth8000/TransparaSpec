defmodule TSpecWeb.FallbackController do
  @moduledoc """
  Translates `{:error, reason}` results from API controllers into JSON errors
  matching `TSpecWeb.Schemas.Error`.
  """
  use TSpecWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "validation_failed",
      message: "Validation failed",
      fields: TSpecWeb.ChangesetErrors.to_map(changeset)
    })
  end

  def call(conn, {:error, :not_found}), do: error(conn, :not_found, "not_found", "Not found")

  def call(conn, {:error, :unauthorized}),
    do: error(conn, :unauthorized, "unauthorized", "Authentication required")

  def call(conn, {:error, :forbidden}), do: error(conn, :forbidden, "forbidden", "Not allowed")

  def call(conn, {:error, code, message}) when is_atom(code),
    do: error(conn, :unprocessable_entity, Atom.to_string(code), message)

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: code, message: message})
  end
end
