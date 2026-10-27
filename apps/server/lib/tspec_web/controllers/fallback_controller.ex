defmodule TSpecWeb.FallbackController do
  @moduledoc """
  Translates `{:error, reason}` results from API controllers into JSON errors
  matching `TSpecWeb.Schemas.Error`.
  """
  use TSpecWeb, :controller

  # reason => {HTTP status, message}. The reason atom becomes the `error` code.
  @errors %{
    not_found: {:not_found, "Not found"},
    unauthorized: {:unauthorized, "Authentication required"},
    forbidden: {:forbidden, "Not allowed"},
    invalid_code: {:unauthorized, "The code or link is invalid or has expired"},
    age_requirement: {:forbidden, "You must be at least 13 to use T-Spec"},
    already_onboarded: {:conflict, "Onboarding is already complete"},
    consent_required: {:unprocessable_entity, "You must accept the current terms"},
    cannot_follow_self: {:unprocessable_entity, "You can't follow yourself"},
    batch_too_large: {:unprocessable_entity, "Too many events in one batch"},
    invalid_session: {:unprocessable_entity, "The feed session id is invalid"},
    rate_limited:
      {:too_many_requests, "Too many sign-in emails for this address. Try again later."}
  }

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "validation_failed",
      message: "Validation failed",
      fields: TSpecWeb.ChangesetErrors.to_map(changeset)
    })
  end

  def call(conn, {:error, reason}) when is_map_key(@errors, reason) do
    {status, message} = Map.fetch!(@errors, reason)
    error(conn, status, reason, message)
  end

  def call(conn, {:error, reason, message}) when is_atom(reason) do
    error(conn, :unprocessable_entity, reason, message)
  end

  defp error(conn, status, reason, message) do
    conn
    |> put_status(status)
    |> json(%{error: Atom.to_string(reason), message: message})
  end
end
