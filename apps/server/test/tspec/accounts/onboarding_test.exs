defmodule TSpec.Accounts.OnboardingTest do
  use TSpec.DataCase, async: true

  import TSpec.AccountsFixtures

  alias TSpec.Accounts
  alias TSpec.Accounts.{Consent, Profile, Scope, User}

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        handle: unique_handle(),
        birthdate: ~D[2000-06-15],
        accept_consent_version: Accounts.current_consent_document().version
      },
      overrides
    )
  end

  test "sets the handle, records consent and creates the profile" do
    user = user_fixture()

    assert {:ok, %User{} = user} =
             Accounts.onboard_user(user, attrs(%{handle: "Jai_K", display_name: "Jai"}))

    assert user.handle == "jai_k"
    assert %DateTime{} = user.age_attested_at
    assert %DateTime{} = user.onboarded_at
    assert %Profile{display_name: "Jai"} = Accounts.get_profile(user)
    assert [%Consent{version: 1, revoked_at: nil}] = Repo.all(Consent)
    assert Scope.onboarded?(Accounts.scope_for_user(user))
  end

  test "rejects under-13s and deletes their account" do
    user = user_fixture()
    twelve = Date.shift(Date.utc_today(), year: -12)

    assert {:error, :age_requirement} = Accounts.onboard_user(user, attrs(%{birthdate: twelve}))
    assert Accounts.get_user_by_email(user.email) == nil
  end

  test "accepts someone whose 13th birthday is today" do
    user = user_fixture()
    thirteen_today = Date.shift(Date.utc_today(), year: -13)

    assert {:ok, _} = Accounts.onboard_user(user, attrs(%{birthdate: thirteen_today}))
  end

  test "never stores the birthdate" do
    refute :birthdate in User.__schema__(:fields)

    columns =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name IN ('users', 'profiles')"
      ).rows
      |> List.flatten()

    refute Enum.any?(columns, &String.contains?(&1, "birth"))
  end

  test "requires the current consent version" do
    user = user_fixture()

    assert {:error, :consent_required} =
             Accounts.onboard_user(user, attrs(%{accept_consent_version: 999}))
  end

  test "validates the handle" do
    user = user_fixture()

    assert {:error, changeset} = Accounts.onboard_user(user, attrs(%{handle: "no spaces!"}))
    assert %{handle: [_]} = errors_on(changeset)
  end

  test "handles are unique, case-insensitively" do
    onboarded_user_fixture(handle: "taken")
    user = user_fixture()

    assert {:error, changeset} = Accounts.onboard_user(user, attrs(%{handle: "TAKEN"}))
    assert %{handle: ["has already been taken"]} = errors_on(changeset)
  end

  test "can't onboard twice" do
    user = onboarded_user_fixture()
    assert {:error, :already_onboarded} = Accounts.onboard_user(user, attrs())
  end

  describe "age_on/2" do
    test "counts whole years" do
      assert Accounts.age_on(~D[2010-05-20], ~D[2023-05-19]) == 12
      assert Accounts.age_on(~D[2010-05-20], ~D[2023-05-20]) == 13
      assert Accounts.age_on(~D[2008-02-29], ~D[2021-02-28]) == 12
      assert Accounts.age_on(~D[2008-02-29], ~D[2021-03-01]) == 13
    end
  end
end
