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
    with {:ok, user} <- get_or_register_user(email),
         {:ok, {code, encoded_token}} <- issue_login_code(user) do
      {:ok, _email} = UserNotifier.deliver_login_code(user, code, link_url_fun.(encoded_token))
      :ok
    end
  end

  # Sign-in emails per address. Each carries a fresh code worth
  # LoginCode.max_attempts/0 guesses, so these caps bound brute force (at
  # most 50 guesses a day against a million codes) as well as how often
  # anyone can make us mail a stranger. They're counted from the "login"
  # tokens in Postgres, so they hold across nodes; signing in deletes those
  # tokens, which resets the count.
  @login_emails_per_hour 5
  @login_emails_per_day 10

  def login_email_limits, do: %{hour: @login_emails_per_hour, day: @login_emails_per_day}

  # Replaces the user's code and adds a magic-link token.
  defp issue_login_code(%User{} = user) do
    within_login_email_limits(user, fn ->
      {code, login_code} = LoginCode.build(user)
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")
      Repo.delete_all(from c in LoginCode, where: c.user_id == ^user.id)
      Repo.insert!(login_code)
      Repo.insert!(user_token)
      {:ok, {code, encoded_token}}
    end)
  end

  # Runs `fun` (which issues a "login" token) in a transaction, or returns
  # `{:error, :rate_limited}` if the address is over its limits. Locking the
  # user row makes concurrent requests for one address count each other.
  defp within_login_email_limits(%User{id: user_id}, fun) do
    Repo.transact(fn ->
      # FOR NO KEY UPDATE serializes sign-ins for this address without
      # blocking other transactions' foreign-key checks on the user.
      Repo.one!(from u in User, where: u.id == ^user_id, select: u.id, lock: "FOR NO KEY UPDATE")
      if login_emails_exceeded?(user_id), do: {:error, :rate_limited}, else: fun.()
    end)
  end

  defp login_emails_exceeded?(user_id) do
    now = DateTime.utc_now(:second)
    hour_ago = DateTime.add(now, -1, :hour)

    {last_hour, last_day} =
      Repo.one!(
        from t in UserToken,
          where:
            t.user_id == ^user_id and t.context == "login" and
              t.inserted_at > ^DateTime.add(now, -1, :day),
          select: {filter(count(), t.inserted_at > ^hour_ago), count()}
      )

    last_hour >= @login_emails_per_hour or last_day >= @login_emails_per_day
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
         {1, [login_code]} <- claim_login_attempt(user.id, email),
         true <- LoginCode.matches?(login_code, code) do
      Repo.delete_all(from c in LoginCode, where: c.user_id == ^user.id)
      Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id and t.context == "login")
      confirm_user(user)
    else
      _ -> {:error, :invalid_code}
    end
  end

  # Spends one attempt *before* the code is compared, in a single conditional
  # UPDATE. Reading the count and incrementing it later would let a burst of
  # concurrent guesses all see the same count and slip past the limit. A
  # right guess is consumed straight after, so spending its attempt is free.
  defp claim_login_attempt(user_id, email) do
    now = DateTime.utc_now(:second)

    from(c in LoginCode,
      where:
        c.user_id == ^user_id and c.sent_to == ^email and c.expires_at > ^now and
          c.attempts < ^LoginCode.max_attempts(),
      select: c
    )
    |> Repo.update_all(inc: [attempts: 1])
  end

  @doc """
  Verifies a magic-link token (web) issued to `email`. Returns `{:ok, user}`
  or `{:error, :invalid_code}`.

  The email must match because the web client shows it ("Sign in as …")
  before the user confirms. Without the check, someone could send a link
  carrying *their own* token with the victim's address on display, and sign
  the victim into the sender's account (login CSRF).
  """
  def verify_login_token(token, email) when is_binary(token) and is_binary(email) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {%User{} = user, user_token} <-
           Repo.one(from [_token, user] in query, where: user.email == ^email) do
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
end
