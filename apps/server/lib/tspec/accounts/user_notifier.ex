defmodule TSpec.Accounts.UserNotifier do
  import Swoosh.Email

  alias TSpec.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"T-Spec", "no-reply@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver a sign-in email for the API flow: a 6-digit code for the native
  apps and a magic link for web. Both are single-use and short-lived.
  """
  def deliver_login_code(user, code, url) do
    deliver(user.email, "Your T-Spec sign-in code: #{code}", """

    ==============================

    Hi #{user.email},

    Your T-Spec sign-in code is:

        #{code}

    It expires in 10 minutes. On the web you can also sign in with this link:

    #{url}

    If you didn't request this, you can ignore this email.

    ==============================
    """)
  end
end
