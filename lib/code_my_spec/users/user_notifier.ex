defmodule CodeMySpec.Users.UserNotifier do
  @moduledoc false
  import Swoosh.Email

  alias CodeMySpec.Mailer
  alias CodeMySpec.Users.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"CodeMySpec", "contact@codemyspec.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Your CodeMySpec login link", """

    ==============================

    Here's your login link:

    #{url}

    This link expires in 60 minutes.

    If you didn't request this, ignore this email.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Your CodeMySpec login link", """

    ==============================

    Welcome to CodeMySpec.

    Click below to confirm your account and get started:

    #{url}

    This link expires in 60 minutes.

    If you didn't sign up, ignore this email.

    -- John

    ==============================
    """)
  end
end
