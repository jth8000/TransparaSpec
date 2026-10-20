defmodule TSpecWeb.Dev.VideoUploadController do
  @moduledoc """
  The upload endpoint of `TSpec.Video.LocalProvider` (dev/test only): accepts
  a multipart `file` at a one-time URL, like Cloudflare Stream's direct
  creator uploads.
  """
  use TSpecWeb, :controller

  alias TSpec.Video.LocalProvider

  def create(conn, %{"token" => token, "file" => %Plug.Upload{path: path}}) do
    with {:ok, asset_id} <- LocalProvider.verify_upload_token(token),
         :ok <- LocalProvider.store_upload(asset_id, path) do
      json(conn, %{status: "ok"})
    else
      {:error, :invalid_token} ->
        conn |> put_status(:forbidden) |> json(%{error: "invalid_token"})

      {:error, :already_uploaded} ->
        conn |> put_status(:conflict) |> json(%{error: "already_uploaded"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "missing_file"})
  end
end
