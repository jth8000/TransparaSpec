defmodule TSpec.Accounts.LoginCode do
  @moduledoc """
  A one-time 6-digit sign-in code, emailed alongside the magic link so native
  clients can sign in without deep-link plumbing.

  The code is stored as an HMAC keyed with a server secret (a leaked table
  can't be brute-forced offline), expires quickly and allows few attempts.
  """
  use TSpec.Schema

  @validity_in_minutes 10
  @max_attempts 5

  schema "login_codes" do
    field :code_hash, :binary, redact: true
    field :sent_to, :string
    field :attempts, :integer, default: 0
    field :expires_at, :utc_datetime
    belongs_to :user, TSpec.Accounts.User

    timestamps(updated_at: false)
  end

  def max_attempts, do: @max_attempts

  @doc "Builds a new code for `user`. Returns `{plain_code, %LoginCode{}}`."
  def build(user) do
    code =
      :crypto.strong_rand_bytes(4)
      |> :binary.decode_unsigned()
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    login_code = %__MODULE__{
      user_id: user.id,
      code_hash: hash(user.id, code),
      sent_to: user.email,
      expires_at: DateTime.add(DateTime.utc_now(:second), @validity_in_minutes, :minute)
    }

    {code, login_code}
  end

  @doc "Constant-time check of `code` against a stored login code."
  def matches?(%__MODULE__{user_id: user_id, code_hash: code_hash}, code) when is_binary(code) do
    Plug.Crypto.secure_compare(hash(user_id, code), code_hash)
  end

  defp hash(user_id, code) do
    :crypto.mac(:hmac, :sha256, secret(), user_id <> ":" <> code)
  end

  defp secret, do: Application.fetch_env!(:tspec, :login_code_secret)
end
