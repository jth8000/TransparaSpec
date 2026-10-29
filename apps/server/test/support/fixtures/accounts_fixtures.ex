defmodule TSpec.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `TSpec.Accounts` context.
  """

  alias TSpec.Accounts
  alias TSpec.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  @doc "A confirmed user, as after a first sign-in."
  def user_fixture(attrs \\ %{}) do
    attrs
    |> unconfirmed_user_fixture()
    |> Accounts.User.confirm_changeset()
    |> TSpec.Repo.update!()
  end

  def unique_handle, do: "user_#{System.unique_integer([:positive])}"

  @doc "A confirmed user who has completed onboarding (handle, 13+, consent v1)."
  def onboarded_user_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    user = user_fixture(Map.take(attrs, [:email]))

    {:ok, user} =
      Accounts.onboard_user(user, %{
        handle: Map.get(attrs, :handle, unique_handle()),
        birthdate: ~D[2000-01-01],
        accept_consent_version: Accounts.current_consent_document().version
      })

    user
  end

  @doc "Issues an API bearer token for `user`."
  def api_token_fixture(user), do: Accounts.create_api_token(user)

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end
end
