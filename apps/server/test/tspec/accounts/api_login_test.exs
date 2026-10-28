defmodule TSpec.Accounts.ApiLoginTest do
  use TSpec.DataCase, async: true

  import Swoosh.TestAssertions
  import TSpec.AccountsFixtures

  alias TSpec.Accounts
  alias TSpec.Accounts.{LoginCode, User, UserToken}

  defp request_code(email) do
    :ok = Accounts.request_login(email, &"https://app.test/verify?token=#{&1}")
    assert_email_sent(fn email -> send(self(), {:email, email}) end)
    assert_received {:email, sent}
    [_, code] = Regex.run(~r/sign-in code: (\d{6})/, sent.subject)
    [_, token] = Regex.run(~r{verify\?token=(\S+)}, sent.text_body)
    {code, token}
  end

  # Moves the user's sign-in emails `seconds` into the past.
  defp backdate_login_emails(user, seconds) do
    Repo.update_all(
      from(t in UserToken, where: t.user_id == ^user.id and t.context == "login"),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -seconds)]
    )
  end

  describe "request_login/2" do
    test "creates the account on first use and emails a code and link" do
      email = unique_user_email()
      {code, _token} = request_code(email)

      assert %User{confirmed_at: nil} = Accounts.get_user_by_email(email)
      assert code =~ ~r/^\d{6}$/
    end

    test "reuses an existing account and replaces any previous code" do
      user = user_fixture()
      {_first, _} = request_code(user.email)
      {_second, _} = request_code(user.email)

      assert Repo.aggregate(from(c in LoginCode, where: c.user_id == ^user.id), :count) == 1
    end

    test "caps sign-in emails per address, per hour and per day" do
      %{hour: per_hour, day: per_day} = Accounts.login_email_limits()
      email = unique_user_email()

      for _ <- 1..per_hour, do: request_code(email)
      assert {:error, :rate_limited} = Accounts.request_login(email, & &1)
      refute_email_sent()

      # Out of the hourly window, but they still count toward the day.
      user = Accounts.get_user_by_email(email)
      backdate_login_emails(user, 2 * 60 * 60)
      for _ <- 1..(per_day - per_hour), do: request_code(email)
      assert {:error, :rate_limited} = Accounts.request_login(email, & &1)

      backdate_login_emails(user, 25 * 60 * 60)
      request_code(email)
    end

    test "signing in resets the count" do
      email = unique_user_email()
      for _ <- 1..(Accounts.login_email_limits().hour - 1), do: request_code(email)
      {code, _} = request_code(email)
      assert {:error, :rate_limited} = Accounts.request_login(email, & &1)

      assert {:ok, _user} = Accounts.verify_login_code(email, code)
      request_code(email)
    end

    test "magic links from the browser sign-in page count toward the same cap" do
      user = user_fixture()

      for _ <- 1..Accounts.login_email_limits().hour,
          do: {:ok, _} = Accounts.deliver_login_instructions(user, & &1)

      assert {:error, :rate_limited} = Accounts.deliver_login_instructions(user, & &1)
      assert {:error, :rate_limited} = Accounts.request_login(user.email, & &1)
    end

    test "rejects malformed emails" do
      assert {:error, %Ecto.Changeset{}} = Accounts.request_login("not-an-email", & &1)
    end
  end

  describe "verify_login_code/2" do
    test "signs in, confirms the email and consumes the code" do
      email = unique_user_email()
      {code, _} = request_code(email)

      assert {:ok, %User{confirmed_at: %DateTime{}}} = Accounts.verify_login_code(email, code)
      assert {:error, :invalid_code} = Accounts.verify_login_code(email, code)
    end

    test "is case-insensitive on email" do
      email = unique_user_email()
      {code, _} = request_code(email)

      assert {:ok, _user} = Accounts.verify_login_code(String.upcase(email), code)
    end

    test "counts wrong guesses and locks the code after the limit" do
      email = unique_user_email()
      {code, _} = request_code(email)
      wrong = if code == "000000", do: "111111", else: "000000"

      for _ <- 1..LoginCode.max_attempts() do
        assert {:error, :invalid_code} = Accounts.verify_login_code(email, wrong)
      end

      # Even the right code is refused once the attempts are used up.
      assert {:error, :invalid_code} = Accounts.verify_login_code(email, code)
    end

    test "refuses expired codes" do
      email = unique_user_email()
      {code, _} = request_code(email)
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)
      Repo.update_all(LoginCode, set: [expires_at: past])

      assert {:error, :invalid_code} = Accounts.verify_login_code(email, code)
    end

    test "refuses unknown emails" do
      assert {:error, :invalid_code} = Accounts.verify_login_code(unique_user_email(), "123456")
    end

    test "stores only an HMAC of the code" do
      email = unique_user_email()
      {code, _} = request_code(email)
      stored = Repo.one!(LoginCode)

      refute stored.code_hash == code
      refute String.contains?(stored.code_hash, code)
    end
  end

  describe "verify_login_token/2" do
    test "signs in with the magic link once" do
      email = unique_user_email()
      {_code, token} = request_code(email)

      assert {:ok, %User{}} = Accounts.verify_login_token(token, email)
      assert {:error, :invalid_code} = Accounts.verify_login_token(token, email)
    end

    test "matches the email case-insensitively" do
      email = unique_user_email()
      {_code, token} = request_code(email)

      assert {:ok, %User{}} = Accounts.verify_login_token(token, String.upcase(email))
    end

    test "refuses a token presented with another address, and leaves it usable" do
      # A link carrying the sender's token can't be shown as the victim's address.
      sender = unique_user_email()
      {_code, token} = request_code(sender)

      assert {:error, :invalid_code} = Accounts.verify_login_token(token, unique_user_email())
      assert {:ok, %User{email: ^sender}} = Accounts.verify_login_token(token, sender)
    end

    test "refuses garbage tokens" do
      assert {:error, :invalid_code} = Accounts.verify_login_token("nope", unique_user_email())
    end
  end

  describe "API tokens" do
    test "round-trip and revoke" do
      user = user_fixture()
      token = Accounts.create_api_token(user)

      assert %User{id: id} = Accounts.get_user_by_api_token(token)
      assert id == user.id

      :ok = Accounts.delete_api_token(token)
      assert Accounts.get_user_by_api_token(token) == nil
    end

    test "are stored hashed" do
      user = user_fixture()
      token = Accounts.create_api_token(user)
      {:ok, raw} = Base.url_decode64(token, padding: false)

      refute Repo.exists?(from t in Accounts.UserToken, where: t.token == ^raw)
    end

    test "unknown or malformed tokens find nobody" do
      assert Accounts.get_user_by_api_token("not base64 !!") == nil
      assert Accounts.get_user_by_api_token(Base.url_encode64("x", padding: false)) == nil
    end
  end
end
