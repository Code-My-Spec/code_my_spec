defmodule CodeMySpecWeb.UserAuth do
  @moduledoc false
  use CodeMySpecWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope
  alias ExOauth2Provider.AccessTokens

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_code_my_spec_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(user))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Users.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      CodeMySpecWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Users.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Users.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    # The guided-intake token is the only way back to a plan the visitor built
    # before they had an account, and clearing the session at the gate orphaned
    # it — they signed up and landed back on "What do you want to build?",
    # having lost everything, which is the exact opposite of the promise.
    # Carried across the renewal rather than kept out of the session, so
    # fixation protection still does its job.
    intake_token = get_session(conn, CodeMySpecWeb.Plugs.IntakeSession.session_key())

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> restore_intake_token(intake_token)
  end

  defp restore_intake_token(conn, nil), do: conn

  defp restore_intake_token(conn, token),
    do: put_session(conn, CodeMySpecWeb.Plugs.IntakeSession.session_key(), token)

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      CodeMySpecWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:require_at_least_one_account` - Requires the user owns at least one
      account. If they own zero, redirects to /app where the wizard
      handles account creation. Must be used after `:require_authenticated`.

    * `:require_active_account` - Requires that the user has an active
      account selected in their scope. Auto-picks the first account when
      one exists but none is active. Stack after `:require_at_least_one_account`
      so the empty-list case is already redirected.

    * `:require_at_least_one_project` - Requires the user owns at least one
      project in their active account. If they own zero, redirects to /app
      where the wizard handles project creation. Must be used after
      `:require_active_account` so the active-account is in scope.

    * `:require_active_project` - Requires that the user has an active
      project selected in their scope. Auto-picks the first project when
      one exists but none is active. Stack after `:require_at_least_one_project`.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule CodeMySpecWeb.PageLive do
        use CodeMySpecWeb, :live_view

        on_mount {CodeMySpecWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{CodeMySpecWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Users.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_at_least_one_account, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if Accounts.list_accounts(scope) == [] do
      socket = Phoenix.LiveView.redirect(socket, to: ~p"/app")
      {:halt, socket}
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_active_account, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if is_nil(scope.active_account) do
      [first | _] = Accounts.list_accounts(scope)

      case UserPreferences.select_active_account(scope, first.id) do
        {:ok, _} ->
          new_scope = Scope.for_user(scope.user)
          {:cont, Phoenix.Component.assign(socket, :current_scope, new_scope)}

        {:error, _} ->
          {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/accounts/picker")}
      end
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_at_least_one_project, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if Projects.list_projects(scope) == [] do
      socket = Phoenix.LiveView.redirect(socket, to: ~p"/app")
      {:halt, socket}
    else
      {:cont, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Users.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "Returns the path to redirect to after log in."
  # Called with a User struct directly (e.g. from log_in_user/3 before the scope plug runs)
  def signed_in_path(%Users.User{}), do: ~p"/app/users/settings"

  # Called with a Conn that already has current_scope populated (legacy callers)
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Users.User{}}}}) do
    ~p"/app/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  @doc """
  Plug for OAuth Bearer token authentication for MCP endpoints.

  Checks for Authorization: Bearer <token> header and validates the OAuth access token.
  Returns 401 Unauthorized with WWW-Authenticate header if no token is provided.
  Returns 401 if the token is invalid or expired.
  Sets current_scope if the token is valid.
  """
  def require_oauth_token(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> access_token] -> assign_oauth_scope(conn, access_token)
      _other -> send_missing_auth_header(conn)
    end
  end

  defp assign_oauth_scope(conn, access_token) do
    case AccessTokens.get_by_token(access_token, otp_app: :code_my_spec) do
      %{} = token -> maybe_assign_scope_for_token(conn, token)
      nil -> send_unauthorized_response(conn, "invalid_token", "The access token is invalid")
    end
  end

  defp maybe_assign_scope_for_token(conn, token) do
    if AccessTokens.is_accessible?(token) do
      user = Users.get_user!(token.resource_owner_id)
      assign(conn, :current_scope, Scope.for_user(user))
    else
      send_unauthorized_response(
        conn,
        "invalid_token",
        "The access token is expired or invalid"
      )
    end
  end

  defp send_missing_auth_header(conn) do
    send_unauthorized_response(
      conn,
      "invalid_request",
      "The request is missing a required Authorization header"
    )
  end

  defp send_unauthorized_response(conn, error_code, error_description) do
    base_url = get_base_url()
    resource = base_url <> conn.request_path
    resource_metadata = base_url <> "/.well-known/oauth-protected-resource" <> conn.request_path

    conn
    |> put_resp_header(
      "www-authenticate",
      "Bearer realm=\"#{resource}\", error=\"#{error_code}\", " <>
        "error_description=\"#{error_description}\", resource_metadata=\"#{resource_metadata}\""
    )
    |> put_status(:unauthorized)
    |> json(%{
      error: error_code,
      error_description: error_description
    })
    |> halt()
  end

  defp get_base_url do
    CodeMySpecWeb.Endpoint.url()
  end
end
