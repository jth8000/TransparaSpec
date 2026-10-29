defmodule TSpec.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias TSpec.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @api_validity_in_days 60

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :user, TSpec.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{user, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks whether the token has expired. The context
  of a magic link token is always "login".
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Builds a bearer token for the JSON API (native and web clients).

  Like email tokens, only the SHA-256 hash is stored: the plain token lives on
  the client, so a database leak doesn't expose usable credentials. Tokens are
  bound to the email they were issued for and expire after
  #{@api_validity_in_days} days.
  """
  def build_api_token(user), do: build_hashed_token(user, "api", user.email)

  @doc "Returns a query for the user owning a valid API token, or `:error`."
  def verify_api_token_query(token) do
    with {:ok, hashed_token} <- hash_encoded_token(token) do
      query =
        from token in by_token_and_context_query(hashed_token, "api"),
          join: user in assoc(token, :user),
          where: token.inserted_at > ago(^@api_validity_in_days, "day"),
          where: token.sent_to == user.email,
          select: user

      {:ok, query}
    end
  end

  @doc "Returns a query matching the stored row for an API token, or `:error`."
  def api_token_query(token) do
    with {:ok, hashed_token} <- hash_encoded_token(token) do
      {:ok, by_token_and_context_query(hashed_token, "api")}
    end
  end

  defp hash_encoded_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} -> {:ok, :crypto.hash(@hash_algorithm, decoded_token)}
      :error -> :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
