defmodule TSpecWeb.VideoWebhookController do
  @moduledoc """
  Receives video-provider webhooks. Verifies the signature over the raw body
  (cached by `TSpecWeb.CacheBodyReader`), queues the event and returns
  immediately; `TSpec.Content.VideoEventWorker` applies it. Not part of the
  public OpenAPI spec.
  """
  use TSpecWeb, :controller

  alias TSpec.{Content, Video}

  def create(conn, %{"provider" => provider_name}) do
    with {:ok, provider} <- Video.provider(provider_name),
         raw_body when is_binary(raw_body) <- conn.assigns[:raw_body],
         {:ok, event} <- provider.verify_webhook(raw_body, conn.req_headers) do
      :ok = Content.enqueue_video_event(provider_name, event)
      json(conn, %{status: "ok"})
    else
      :error -> conn |> put_status(:not_found) |> json(%{error: "unknown_provider"})
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})
      nil -> conn |> put_status(:bad_request) |> json(%{error: "missing_body"})
    end
  end
end
