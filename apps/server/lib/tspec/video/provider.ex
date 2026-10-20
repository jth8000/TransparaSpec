defmodule TSpec.Video.Provider do
  @moduledoc """
  The boundary to a managed video service (ADR 0005). Video bytes go from the
  client straight to the provider; we only hold metadata and react to its
  webhooks.

  Implementations: `TSpec.Video.LocalProvider` (dev/test emulator, ffmpeg)
  and `TSpec.Video.CloudflareStream`.
  """

  @typedoc "Where and how the client uploads the file."
  @type upload :: %{
          asset_id: String.t(),
          url: String.t(),
          method: String.t(),
          form_field: String.t()
        }

  @typedoc "A normalized webhook event."
  @type event ::
          %{
            type: :ready,
            asset_id: String.t(),
            playback_id: String.t(),
            duration_ms: non_neg_integer(),
            width: pos_integer() | nil,
            height: pos_integer() | nil
          }
          | %{type: :failed, asset_id: String.t(), reason: String.t()}
          | %{type: :ignored}

  @doc "Creates a one-time direct-upload slot. `opts` includes `:max_duration_seconds`."
  @callback create_direct_upload(opts :: map()) :: {:ok, upload()} | {:error, term()}

  @callback delete_asset(asset_id :: String.t()) :: :ok | {:error, term()}

  @callback playback_url(playback_id :: String.t()) :: String.t()

  @callback thumbnail_url(playback_id :: String.t(), opts :: keyword()) :: String.t()

  @doc "Verifies a webhook's signature against the raw body and parses it into an `event`."
  @callback verify_webhook(raw_body :: binary(), headers :: [{String.t(), String.t()}]) ::
              {:ok, event()} | {:error, :invalid_signature | :invalid_payload}
end
