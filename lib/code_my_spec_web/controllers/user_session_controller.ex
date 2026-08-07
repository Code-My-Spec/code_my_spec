defmodule CodeMySpecWeb.UserSessionController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Users
  alias CodeMySpecWeb.UserAuth

  def confirm(conn, %{"token" => token}) do
    case Users.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_session(:user_return_to, ~p"/app")
        |> put_flash(:info, "User confirmed successfully.")
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      # A real state with a real way out, so it gets its own message. Told
      # "invalid or expired" the user would keep requesting fresh links, and
      # every one of them would be refused for the same reason.
      {:error, :unconfirmed_with_password} ->
        conn
        |> put_flash(
          :error,
          "Confirm your email address before signing in with a link. We sent a confirmation " <>
            "email when you registered — open that link, or sign in with your password."
        )
        |> redirect(to: ~p"/users/log-in")

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def create(conn, %{"_action" => "confirmed"} = params) do
    conn
    |> put_session(:user_return_to, ~p"/app")
    |> create(params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  #
  # Magic links are a remembered-intent flow — the user demonstrated
  # they want a persistent login by clicking the email link. Force
  # `remember_me: "true"` regardless of form-field state. Without
  # this, the Plug.Session cookie is browser-life only and the user
  # gets bounced back to login when navigating across live_session
  # boundaries (issue e7e15279). Matches the `confirm/2` path above
  # which already forces it.
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Users.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        params = Map.put(user_params, "remember_me", "true")

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, params)

      # A real state with a real way out, so it gets its own message. Told
      # "invalid or expired" the user would keep requesting fresh links, and
      # every one of them would be refused for the same reason.
      {:error, :unconfirmed_with_password} ->
        conn
        |> put_flash(
          :error,
          "Confirm your email address before signing in with a link. We sent a confirmation " <>
            "email when you registered — open that link, or sign in with your password."
        )
        |> redirect(to: ~p"/users/log-in")

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Users.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Users.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Users.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/app/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
