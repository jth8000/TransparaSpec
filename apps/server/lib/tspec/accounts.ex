defmodule TSpec.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias TSpec.Repo

  alias TSpec.Accounts.{
    Consent,
    ConsentDocument,
    LoginCode,
    Profile,
    Scope,
    User,
    UserNotifier,
    UserToken
  }

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `TSpec.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `TSpec.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## API sign-in (email code + magic link)

  @doc """
  Starts an email sign-in. Creates the account on first use (sign-up and
  sign-in are the same flow) and emails a 6-digit code for native clients
  plus a magic link for web.

  Always returns `:ok` for a well-formed email so the response doesn't reveal
  whether an account exists. `link_url_fun` receives the encoded magic-link
  token and returns the URL to put in the email.
  """
  def request_login(email, link_url_fun) when is_function(link_url_fun, 1) do
    with {:ok, user} <- get_or_register_user(email) do
      {code, login_code} = LoginCode.build(user)
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")

      Repo.transact(fn ->
        Repo.delete_all(from c in LoginCode, where: c.user_id == ^user.id)
        Repo.insert!(login_code)
        Repo.insert!(user_token)
        {:ok, nil}
      end)

      {:ok, _email} = UserNotifier.deliver_login_code(user, code, link_url_fun.(encoded_token))
      :ok
    end
  end

  defp get_or_register_user(email) when is_binary(email) do
    case get_user_by_email(email) do
      %User{} = user -> {:ok, user}
      nil -> register_user(%{email: email})
    end
  end

  @doc """
  Verifies an emailed code. On success the code is consumed, the email is
  confirmed and `{:ok, user}` is returned. Each wrong guess counts against
  `LoginCode.max_attempts/0`; after that the code is dead and a new one must
  be requested.
  """
  def verify_login_code(email, code) when is_binary(email) and is_binary(code) do
    with %User{} = user <- get_user_by_email(email),
         %LoginCode{} = login_code <- Repo.get_by(LoginCode, user_id: user.id, sent_to: email),
         false <- LoginCode.expired?(login_code),
         true <- login_code.attempts < LoginCode.max_attempts() do
      if LoginCode.matches?(login_code, code) do
        Repo.delete_all(from c in LoginCode, where: c.user_id == ^user.id)

        Repo.delete_all(
          from t in UserToken, where: t.user_id == ^user.id and t.context == "login"
        )

        confirm_user(user)
      else
        Repo.update_all(from(c in LoginCode, where: c.id == ^login_code.id),
          inc: [attempts: 1]
        )

        {:error, :invalid_code}
      end
    else
      _ -> {:error, :invalid_code}
    end
  end

  @doc "Verifies a magic-link token (web). Returns `{:ok, user}` or `{:error, :invalid_code}`."
  def verify_login_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {%User{} = user, user_token} <- Repo.one(query) do
      Repo.delete!(user_token)
      Repo.delete_all(from c in LoginCode, where: c.user_id == ^user.id)
      confirm_user(user)
    else
      _ -> {:error, :invalid_code}
    end
  end

  defp confirm_user(%User{confirmed_at: nil} = user),
    do: Repo.update(User.confirm_changeset(user))

  defp confirm_user(%User{} = user), do: {:ok, user}

  @doc "Issues a bearer token for the API. Returns the plain token for the client."
  def create_api_token(%User{} = user) do
    {encoded_token, user_token} = UserToken.build_api_token(user)
    Repo.insert!(user_token)
    encoded_token
  end

  @doc "Returns the user owning a valid API token, or nil."
  def get_user_by_api_token(token) when is_binary(token) do
    case UserToken.verify_api_token_query(token) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  @doc "Revokes an API token (sign out on one device)."
  def delete_api_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.api_token_query(token), do: Repo.delete_all(query)
    :ok
  end

  ## Scope

  @doc "Builds the caller scope for a user, resolving their consent version."
  def scope_for_user(%User{} = user), do: Scope.for_user(user, current_consent_version(user))

  ## Consent

  @doc "The latest published consent document, which new users must accept."
  def current_consent_document do
    Repo.one!(from d in ConsentDocument, order_by: [desc: d.version], limit: 1)
  end

  @doc "The newest consent version the user has accepted and not revoked, or nil."
  def current_consent_version(%User{id: user_id}) do
    Repo.one(
      from c in Consent,
        where: c.user_id == ^user_id and is_nil(c.revoked_at),
        select: max(c.version)
    )
  end

  ## Onboarding

  @minimum_age 13

  @doc """
  Completes onboarding: handle, 13+ check and acceptance of the current
  consent document, in one transaction.

  The `birthdate` is used only to evaluate the age requirement and is never
  persisted. A user under #{@minimum_age} is deleted entirely (COPPA) and
  `{:error, :age_requirement}` is returned.
  """
  def onboard_user(%User{} = user, %{handle: handle, birthdate: %Date{} = birthdate} = attrs) do
    document = current_consent_document()

    cond do
      user.onboarded_at ->
        {:error, :already_onboarded}

      age_on(birthdate, Date.utc_today()) < @minimum_age ->
        Repo.delete!(user)
        {:error, :age_requirement}

      Map.get(attrs, :accept_consent_version) != document.version ->
        {:error, :consent_required}

      true ->
        Repo.transact(fn ->
          with {:ok, user} <- Repo.update(User.onboarding_changeset(user, %{handle: handle})) do
            Repo.insert!(%Profile{user_id: user.id, display_name: Map.get(attrs, :display_name)})

            Repo.insert!(%Consent{
              user_id: user.id,
              version: document.version,
              scopes: ["terms", "privacy"],
              granted_at: DateTime.utc_now(:second)
            })

            {:ok, user}
          end
        end)
    end
  end

  @doc false
  def age_on(%Date{} = birthdate, %Date{} = today) do
    years = today.year - birthdate.year
    had_birthday? = {today.month, today.day} >= {birthdate.month, birthdate.day}
    if had_birthday?, do: years, else: years - 1
  end

  ## Profiles

  @doc "Gets an onboarded user by handle (case-insensitive), with profile preloaded."
  def get_user_by_handle(handle) when is_binary(handle) do
    Repo.one(
      from u in User,
        where: u.handle == ^handle and not is_nil(u.onboarded_at),
        preload: :profile
    )
  end

  @doc "Returns the user's profile (empty struct before onboarding)."
  def get_profile(%User{id: user_id}) do
    Repo.get(Profile, user_id) || %Profile{user_id: user_id}
  end

  def update_profile(%Scope{user: user}, attrs) do
    user
    |> get_profile()
    |> Profile.changeset(attrs)
    |> Repo.insert_or_update()
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
