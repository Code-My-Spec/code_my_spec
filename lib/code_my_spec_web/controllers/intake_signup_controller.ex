defmodule CodeMySpecWeb.IntakeSignupController do
  @moduledoc """
  Email from the sign-up card, on the intake conversation.

  Distinct from `UserLive.Registration`'s email path: that one sends a magic
  link and stops at `/users/check-email`, which is a wait the visitor never
  agreed to — they were mid-conversation, not filling out a form to leave and
  come back to. This logs the account in immediately, the moment it exists.
  `confirmed_at` is left unset — nothing here consumes a magic-link token,
  which is the only thing that would set it — so confirming later is a fact
  about the account rather than a condition on using it.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Users
  alias CodeMySpecWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email}}) do
    case Users.register_user(%{"email" => email}) do
      {:ok, user} ->
        conn
        |> put_session(:user_return_to, ~p"/build/workspace")
        |> UserAuth.log_in_user(user)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "That email didn't work — try again.")
        |> redirect(to: ~p"/build")
    end
  end
end
