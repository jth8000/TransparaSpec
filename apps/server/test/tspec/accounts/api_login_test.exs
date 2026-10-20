defmodule TSpec.Accounts.ApiLoginTest do
  use TSpec.DataCase, async: true

  import Swoosh.TestAssertions
  import TSpec.AccountsFixtures

  alias TSpec.Accounts
  alias TSpec.Accounts.{LoginCode, User}

  defp request_code(email) do
    :ok = Accounts.request_login(email, &"https://app.test/verify?token=#{&1}")
    assert_email_sent(fn email -> send(self(), {:email, email}) end)
    assert_received {:email, sent}
    [_, code] = Regex.run(~r/sign-in code: (\d{6})/, sent.subject)
    [_, token] = Regex.run(~r{verify\?token=(\S+)}, sent.text_body)
    {code, token}
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

  describe "verify_login_token/1" do
    test "signs in with the magic link once" do
      email = unique_user_email()
      {_code, token} = request_code(email)

      assert {:ok, %User{}} = Accounts.verify_login_token(token)
      assert {:error, :invalid_code} = Accounts.verify_login_token(token)
    end

    test "refuses garbage tokens" do
      assert {:error, :invalid_code} = Accounts.verify_login_token("nope")
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
