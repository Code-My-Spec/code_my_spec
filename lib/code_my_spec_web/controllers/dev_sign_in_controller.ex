defmodule CodeMySpecWeb.DevSignInController do
  @moduledoc """
  A sign-in link for QA, and a way to mint the account it signs in to.

  QA drives the browser, so it needs a real session. Getting one meant working
  the magic-link flow by hand every run — request a link, open `/dev/mailbox`,
  find the right message among everyone else's, extract the token. The mailbox
  is shared, so "the right message" is whichever login arrived last, and a
  second agent testing at the same time takes yours.

  Measured cost, 2026-09-12: a QA agent working around auth reached for
  `ask_user_question` against the live endpoint to get at a real agent context,
  and left a question in the owner's real inbox that no tool could withdraw.
  The improvisation was reasonable; there was no sanctioned door.

  ## Two doors, both dev-only

    * `POST /dev/sign-in` — `email` + `password`, answers with a one-time URL.
    * `POST /dev/sign-up` — `email` + optional `password`, creates the user and
      answers with the same, so QA can mint as many accounts as it needs rather
      than sharing one.

  ## It mints the real token

  `UserToken.build_email_token(user, "login")` — the same token
  `deliver_login_instructions/2` puts in the email, redeemed at the same
  `/users/log-in/:token` route by the same controller. So QA exercises the
  product's actual session auth rather than a test-only bypass, and a break in
  the real flow still fails QA rather than being routed around.

  What it skips is the mailbox, not the authentication.

  ## Why a route and not an MCP tool

  A tool that mints sessions is a credential vending machine on the agent
  surface, and the agent surface is reachable from more places than this is.
  Behind `:dev_routes` it is absent from a release rather than disabled in one
  — the same reasoning `/dev/agents` already carries, and for a sharper reason:
  that one can message an agent, this one can become a user.

  ## Passwords

  `sign-in` requires one and checks it, so it cannot hand out a session for an
  account whose password nobody knows. `sign-up` takes one optionally, because
  the product's own registration is magic-link-first and an account with no
  password is a state it really produces — QA should be able to test that one
  too.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Users
  alias CodeMySpec.Users.UserToken

  def create(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    email
    |> Users.get_user_by_email_and_password(password)
    |> respond(conn, "no user with that email and password")
  end

  def create(conn, _params) do
    refuse(conn, "sign-in needs both email and password")
  end

  def register(conn, %{"email" => email} = params) when is_binary(email) do
    case Users.register_user(%{email: email}) do
      {:ok, user} -> user |> set_password(params["password"]) |> respond(conn, nil)
      {:error, changeset} -> refuse(conn, errors(changeset))
    end
  end

  def register(conn, _params), do: refuse(conn, "sign-up needs an email")

  defp set_password(user, nil), do: user

  defp set_password(user, password) when is_binary(password) do
    {:ok, {updated, _expired_tokens}} =
      Users.update_user_password(user, %{password: password, password_confirmation: password})

    updated
  end

  defp respond(nil, conn, reason), do: refuse(conn, reason)

  defp respond(user, conn, _reason) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    CodeMySpec.Repo.insert!(user_token)

    json(conn, %{
      email: user.email,
      user_id: user.id,
      # Absolute, because QA hands this straight to a browser. A path would make
      # every caller reassemble the host, and get it wrong on the copy whose
      # endpoint is not on 4000.
      sign_in_url: url(~p"/users/log-in/#{encoded_token}")
    })
  end

  defp refuse(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: reason})
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end
end
