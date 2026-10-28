defmodule TSpec.Video.LocalProvider do
  @moduledoc """
  Development/test stand-in for a managed video provider.

  It mimics Cloudflare Stream's shape: the client POSTs the file (multipart
  field `file`) to a one-time URL, the file is transcoded to HLS with ffmpeg
  in an Oban job, and a signed webhook reports the result. Phoenix serves the
  media under `/dev_media`. This is the one sanctioned case of video bytes
  passing through Phoenix, and only outside production.
  """
  @behaviour TSpec.Video.Provider

  alias TSpec.Video.LocalTranscodeWorker

  @upload_salt "local-video-upload"
  @signature_header "x-local-signature"

  @impl true
  def create_direct_upload(_opts) do
    asset_id = UUIDv7.generate()
    token = Plug.Crypto.sign(secret(), @upload_salt, asset_id)

    {:ok,
     %{
       asset_id: asset_id,
       url: base_url() <> "/dev/video-uploads/" <> token,
       method: "POST",
       form_field: "file"
     }}
  end

  @doc "Resolves a one-time upload token (valid for an hour) to its asset id."
  def verify_upload_token(token) do
    case Plug.Crypto.verify(secret(), @upload_salt, token, max_age: 3600) do
      {:ok, asset_id} -> {:ok, asset_id}
      {:error, _} -> {:error, :invalid_token}
    end
  end

  @doc "Stores an uploaded file for `asset_id` and queues the transcode."
  # Dev/test only. `asset_dir!/1` rejects anything but a UUID, and
  # `uploaded_path` is Plug's temp file, not a client-chosen path.
  # sobelow_skip ["Traversal"]
  def store_upload(asset_id, uploaded_path) do
    dir = asset_dir!(asset_id)

    if File.exists?(Path.join(dir, "source")) do
      {:error, :already_uploaded}
    else
      File.mkdir_p!(dir)
      File.cp!(uploaded_path, Path.join(dir, "source"))
      {:ok, _job} = Oban.insert(LocalTranscodeWorker.new(%{asset_id: asset_id}))
      :ok
    end
  end

  @impl true
  # sobelow_skip ["Traversal"]
  def delete_asset(asset_id) do
    {:ok, _} = File.rm_rf(asset_dir!(asset_id))
    :ok
  end

  @impl true
  def playback_url(playback_id), do: "#{base_url()}/dev_media/#{playback_id}/index.m3u8"

  @impl true
  def thumbnail_url(playback_id, _opts \\ []),
    do: "#{base_url()}/dev_media/#{playback_id}/thumb.jpg"

  @impl true
  def verify_webhook(raw_body, headers) do
    with {_, signature} <- List.keyfind(headers, @signature_header, 0),
         true <- Plug.Crypto.secure_compare(sign(raw_body), signature),
         {:ok, payload} <- Jason.decode(raw_body) do
      parse_event(payload)
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_payload}
      _ -> {:error, :invalid_signature}
    end
  end

  defp parse_event(%{"state" => "ready", "asset_id" => id} = p) do
    {:ok,
     %{
       type: :ready,
       asset_id: id,
       playback_id: id,
       duration_ms: p["duration_ms"],
       width: p["width"],
       height: p["height"]
     }}
  end

  defp parse_event(%{"state" => "failed", "asset_id" => id} = p),
    do: {:ok, %{type: :failed, asset_id: id, reason: p["reason"] || "unknown"}}

  defp parse_event(_), do: {:error, :invalid_payload}

  @doc """
  Reports a transcode result the way a real provider would: as a signed
  webhook. In dev it's an HTTP POST to our own endpoint; in test (no running
  server) the same verify-and-enqueue path is called directly.
  """
  def deliver_event(payload) when is_map(payload) do
    body = Jason.encode!(payload)
    headers = [{"content-type", "application/json"}, {@signature_header, sign(body)}]

    case config(:webhook) do
      :http ->
        url = base_url() <> "/api/webhooks/video/local"
        %{status: 200} = Req.post!(url, body: body, headers: headers, retry: :transient)
        :ok

      :inline ->
        {:ok, event} = verify_webhook(body, headers)
        TSpec.Content.enqueue_video_event("local", event)
    end
  end

  @doc "Directory holding an asset's files. Raises on ids that aren't UUIDs."
  def asset_dir!(asset_id) do
    {:ok, _} = Ecto.UUID.cast(asset_id)
    Path.join(config(:media_root), asset_id)
  end

  defp sign(body), do: :crypto.mac(:hmac, :sha256, secret(), body) |> Base.encode16(case: :lower)

  defp base_url, do: config(:base_url)
  defp secret, do: config(:secret)
  defp config(key), do: Application.fetch_env!(:tspec, __MODULE__) |> Keyword.fetch!(key)
end
