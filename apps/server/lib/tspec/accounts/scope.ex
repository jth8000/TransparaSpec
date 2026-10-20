defmodule TSpec.Accounts.Scope do
  @moduledoc """
  The caller of a context function: which user, and which consent version is
  in force for them.

  `consent_version` is resolved server-side when the scope is built and is the
  only source for the consent version stamped on engagement events — clients
  never supply it (ADR 0007).
  """

  alias TSpec.Accounts.User

  defstruct user: nil, consent_version: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(user, consent_version \\ nil)

  def for_user(%User{} = user, consent_version) do
    %__MODULE__{user: user, consent_version: consent_version}
  end

  def for_user(nil, _consent_version), do: nil

  @doc "True once the user has a handle, a 13+ attestation and a consent."
  def onboarded?(%__MODULE__{user: %User{onboarded_at: %DateTime{}}, consent_version: v})
      when is_integer(v),
      do: true

  def onboarded?(_scope), do: false
end
