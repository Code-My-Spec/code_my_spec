defmodule CodeMySpecSpex.Case do
  @moduledoc """
  Base case for spex (BDD spec) tests.

  Provides:
  - Phoenix.ConnTest for HTTP assertions
  - Phoenix.LiveViewTest for driving LiveViews
  - SexySpex DSL (spex/scenario/given_/when_/then_)
  - DB sandbox setup
  - Auth helpers via Fixtures (no direct Users context access)

  Specs compose Givens and interact through the Web layer. They cannot
  reach into the app — that's the job of `CodeMySpecSpex.Fixtures`, the
  approved bridge.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias CodeMySpecSpex.Fixtures

  using do
    quote do
      @endpoint CodeMySpecLocalWeb.Endpoint

      use CodeMySpecLocalWeb, :verified_routes
      use SexySpex

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import CodeMySpecSpex.Case
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(CodeMySpec.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # -- Auth setup helpers (mirror ConnCase, but route through Fixtures only) --

  @doc """
  Setup helper that registers and logs in a user.

      setup :register_and_log_in_user
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = Fixtures.user_fixture()
    scope = Fixtures.user_scope_fixture(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  @doc """
  Setup helper that sets up an active account for the user.

      setup :setup_active_account
  """
  def setup_active_account(%{user: user} = context) do
    account = Fixtures.account_with_owner_fixture(user)
    updated_scope = Fixtures.user_scope_fixture(user, account)

    Fixtures.select_active_account(updated_scope, account.id)

    Map.merge(context, %{account: account, scope: updated_scope})
  end

  @doc """
  Setup helper that sets up an active project for the user.
  """
  def setup_active_project(%{user: user, account: account, scope: scope} = context) do
    # Create a real stub directory with a mix.exs to satisfy the
    # WorkingDir plug (which hits File.exists?/File.dir? directly). Real
    # file I/O still goes through the in-memory environment — the stub
    # dir is just a marker for the plug and the project's local_path.
    stub_dir = Path.join(System.tmp_dir!(), "spex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(stub_dir)
    File.write!(Path.join(stub_dir, "mix.exs"), "# stub for WorkingDir plug\n")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(stub_dir) end)

    env = Fixtures.memory_environment_fixture(working_dir: stub_dir)

    project =
      Fixtures.project_fixture(scope, account_id: account.id, local_path: stub_dir)

    # Register the env so Scope.for_local_project (called by LiveViews that
    # rebuild scope from project) returns THIS env instead of a default
    # :local env. Registration is monitored — when the test process exits
    # the entry is cleaned up automatically.
    Fixtures.register_environment(project.id, env)
    ExUnit.Callbacks.on_exit(fn -> Fixtures.unregister_environment(project.id) end)

    updated_scope =
      user
      |> Fixtures.user_scope_fixture(account, project)
      |> Map.put(:cwd, stub_dir)
      |> Map.put(:environment, env)

    Fixtures.select_active_project(updated_scope, project.id)
    Map.merge(context, %{project: project, scope: updated_scope, environment: env})
  end

  @doc """
  Setup helper that registers, logs in, and sets up an active account.
  """
  def register_log_in_setup_account(context) do
    context
    |> register_and_log_in_user()
    |> setup_active_account()
  end

  @doc """
  Logs the given `user` into the `conn`.
  """
  def log_in_user(conn, user) do
    token = Fixtures.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
