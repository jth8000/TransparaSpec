defmodule TSpec.Accounts.LoginCodeConcurrencyTest do
  @moduledoc """
  The sign-in code attempt limit under real concurrent requests. Inside the
  SQL sandbox every query shares one connection, so these run unboxed: each
  guess gets its own connection, as parallel HTTP requests would. The user
  is deleted afterwards (login codes cascade).
  """
  use TSpec.DataCase, async: false

  import Swoosh.TestAssertions
  import TSpec.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias TSpec.Accounts
  alias TSpec.Accounts.LoginCode

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  test "a burst of parallel wrong guesses can't spend more than the limit" do
    email = unique_user_email()

    code =
      unboxed(fn ->
        :ok = Accounts.request_login(email, &"https://app.test/verify?token=#{&1}")
        assert_email_sent(fn email -> send(self(), {:email, email}) end)
        assert_received {:email, sent}
        [_, code] = Regex.run(~r/sign-in code: (\d{6})/, sent.subject)
        code
      end)

    user = unboxed(fn -> Accounts.get_user_by_email(email) end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from u in Accounts.User, where: u.id == ^user.id) end)
    end)

    wrong = if code == "000000", do: "111111", else: "000000"

    results =
      1..(4 * LoginCode.max_attempts())
      |> Enum.map(fn _ ->
        Task.async(fn -> unboxed(fn -> Accounts.verify_login_code(email, wrong) end) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.all?(results, &(&1 == {:error, :invalid_code}))

    attempts =
      unboxed(fn ->
        Repo.one!(from c in LoginCode, where: c.user_id == ^user.id, select: c.attempts)
      end)

    assert attempts == LoginCode.max_attempts()

    # The limit held, so the right code is refused too.
    assert {:error, :invalid_code} = unboxed(fn -> Accounts.verify_login_code(email, code) end)
  end

  test "a burst of parallel sign-in requests can't send more emails than the cap" do
    user = unboxed(fn -> unconfirmed_user_fixture() end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from u in Accounts.User, where: u.id == ^user.id) end)
    end)

    per_hour = Accounts.login_email_limits().hour

    results =
      1..(4 * per_hour)
      |> Enum.map(fn _ ->
        Task.async(fn -> unboxed(fn -> Accounts.request_login(user.email, & &1) end) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &(&1 == :ok)) == per_hour
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 3 * per_hour
  end
end
