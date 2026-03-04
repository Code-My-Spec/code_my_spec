defmodule CodeMySpecTest.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CodeMySpecWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias CodeMySpec.Users

  using do
    quote do
      # The default endpoint for testing
      @endpoint CodeMySpecWeb.Endpoint

      use CodeMySpecWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CodeMySpecTest.ConnCase
    end
  end

  setup tags do
    CodeMySpecTest.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = CodeMySpec.UsersFixtures.user_fixture()
    scope = Users.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = CodeMySpec.Users.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc """
  Setup helper that sets up an active account for the user.

      setup :setup_active_account

  It creates an account and sets it as active for the user.
  """
  def setup_active_account(%{user: user} = context) do
    account = CodeMySpec.AccountsFixtures.account_with_owner_fixture(user)
    updated_scope = CodeMySpec.UsersFixtures.user_scope_fixture(user, account)

    # Create user preferences with the active account ID
    CodeMySpec.UserPreferences.select_active_account(updated_scope, account.id)

    Map.merge(context, %{account: account, scope: updated_scope})
  end

  def setup_active_project(%{user: user, account: account, scope: scope} = context) do
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, account_id: account.id)
    updated_scope = CodeMySpec.UsersFixtures.user_scope_fixture(user, account, project)
    CodeMySpec.UserPreferences.select_active_project(updated_scope, project.id)
    Map.merge(context, %{project: project, scope: updated_scope})
  end

  @doc """
  Setup helper that registers and logs in a user, then sets up an active account.

      setup :register_log_in_setup_account

  It combines register_and_log_in_user and setup_active_account.
  """
  def register_log_in_setup_account(context) do
    context
    |> register_and_log_in_user()
    |> setup_active_account()
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    CodeMySpec.UsersFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
