defmodule TSpec.Video.CloudflareStream do
  @moduledoc """
  Cloudflare Stream implementation of `TSpec.Video.Provider` (ADR 0005).

    * Uploads use basic direct creator uploads: we create a one-time URL with
      `maxDurationSeconds`, and the client POSTs the file (multipart field
      `file`, under 200 MB) straight to Cloudflare.
    * Cloudflare calls our webhook when processing ends. The
      `Webhook-Signature: time=…,sig1=…` header is an HMAC-SHA256 (hex) of
      `"<time>.<raw body>"` with the webhook secret; stale timestamps are
      rejected.
    * Playback is HLS from the account's `customer-<code>.cloudflarestream.com`
      subdomain; the playback id is the video uid.

  Config (`config :tspec, TSpec.Video.CloudflareStream`): `:account_id`,
  `:api_token`, `:webhook_secret`, `:customer_subdomain`, and optional
  `:req_options` (tests use it to plug in `Req.Test`).
  """
  @behaviour TSpec.Video.Provider

  @api "https://api.cloudflare.com/client/v4"
  @signature_tolerance_seconds 5 * 60

  @impl true
  def create_direct_upload(opts) do
    body = %{maxDurationSeconds: Map.fetch!(opts, :max_duration_seconds)}

    case Req.post(req(),
           url: "/accounts/#{config!(:account_id)}/stream/direct_upload",
           json: body
         ) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => result}}} ->
        {:ok,
         %{
           asset_id: result["uid"],
           url: result["uploadURL"],
           method: "POST",
           form_field: "file"
         }}

      {:ok, response} ->
        {:error, {:cloudflare, response.status, response.body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @impl true
  def delete_asset(asset_id) do
    case Req.delete(req(), url: "/accounts/#{config!(:account_id)}/stream/#{asset_id}") do
      {:ok, %{status: status}} when status in [200, 404] -> :ok
      {:ok, response} -> {:error, {:cloudflare, response.status, response.body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @impl true
  def playback_url(uid), do: "https://#{config!(:customer_subdomain)}/#{uid}/manifest/video.m3u8"

  @impl true
  def thumbnail_url(uid, _opts \\ []),
    do: "https://#{config!(:customer_subdomain)}/#{uid}/thumbnails/thumbnail.jpg"

  @impl true
  def verify_webhook(raw_body, headers) do
    with {_, header} <- List.keyfind(headers, "webhook-signature", 0),
         {:ok, time, signature} <- parse_signature(header),
         true <- fresh?(time),
         true <- Plug.Crypto.secure_compare(sign(time, raw_body), signature),
         {:ok, payload} <- Jason.decode(raw_body) do
      parse_event(payload)
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_payload}
      _ -> {:error, :invalid_signature}
    end
  end

  @doc false
  def sign(time, raw_body) do
    :crypto.mac(:hmac, :sha256, config!(:webhook_secret), time <> "." <> raw_body)
    |> Base.encode16(case: :lower)
  end

  defp parse_signature(header) do
    parts =
      for part <- String.split(header, ","),
          [key, value] <- [String.split(String.trim(part), "=", parts: 2)],
          into: %{},
          do: {key, value}

    case parts do
      %{"time" => time, "sig1" => sig} -> {:ok, time, sig}
      _ -> :error
    end
  end

  defp fresh?(time) do
    case Integer.parse(time) do
      {unix, ""} -> abs(System.os_time(:second) - unix) <= @signature_tolerance_seconds
      _ -> false
    end
  end

  defp parse_event(%{"uid" => uid, "readyToStream" => true} = p) do
    {:ok,
     %{
       type: :ready,
       asset_id: uid,
       playback_id: uid,
       duration_ms: duration_ms(p["duration"]),
       width: get_in(p, ["input", "width"]),
       height: get_in(p, ["input", "height"])
     }}
  end

  defp parse_event(%{"uid" => uid, "status" => %{"state" => "error"} = status}) do
    # Cloudflare's docs use both spellings of this field.
    reason = status["errReasonCode"] || status["errorReasonCode"] || "ERR_UNKNOWN"
    {:ok, %{type: :failed, asset_id: uid, reason: reason}}
  end

  # Intermediate states (queued, inprogress, …) need no action.
  defp parse_event(%{"uid" => _}), do: {:ok, %{type: :ignored}}
  defp parse_event(_), do: {:error, :invalid_payload}

  defp duration_ms(seconds) when is_number(seconds) and seconds >= 0, do: round(seconds * 1000)
  defp duration_ms(_), do: nil

  defp req do
    Req.new(
      [base_url: @api, auth: {:bearer, config!(:api_token)}, retry: :transient] ++
        Keyword.get(config(), :req_options, [])
    )
  end

  defp config, do: Application.get_env(:tspec, __MODULE__, [])

  defp config!(key) do
    case Keyword.fetch(config(), key) do
      {:ok, value} when value not in [nil, ""] -> value
      _ -> raise ArgumentError, "missing config :tspec, #{inspect(__MODULE__)}, #{inspect(key)}"
    end
  end
end
