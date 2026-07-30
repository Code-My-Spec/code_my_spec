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

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

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
    # Real subdirs so FileWatcherServer.start_watcher/1 finds watchable
    # roots and doesn't error with :no_watchable_dirs. The memfs still
    # owns content; these are just empty directories on disk.
    File.mkdir_p!(Path.join(stub_dir, "lib"))
    File.mkdir_p!(Path.join(stub_dir, "test"))
    File.mkdir_p!(Path.join(stub_dir, ".code_my_spec/spec"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(stub_dir) end)

    env = Fixtures.memory_environment_fixture(working_dir: stub_dir)

    project =
      Fixtures.project_fixture(scope,
        account_id: account.id,
        local_path: stub_dir,
        client_user_id: user.id
      )

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

    # The spex suite exercises the full development workflow — spec files,
    # design reviews, unit tests and everything gated on them. A fresh project
    # now defaults those three toggles OFF (it writes BDD spex and code and
    # nothing else), which is the right product default and the wrong baseline
    # for these specs: it silently removed the spec/review/test nodes from the
    # graph and took about seventy spex down with it, none of which mention a
    # configuration.
    #
    # Set here rather than in seventy files. Story 671's specs are about the
    # toggles themselves and drive the configuration LiveView explicitly, so
    # they override this and keep testing what they always tested.
    Fixtures.require_all!(updated_scope)

    Map.merge(context, %{project: project, scope: updated_scope, environment: env})
  end

  @doc """
  Setup helper that creates a fully-satisfied story with an active
  `qa_complete` session task.

  Applies the full project + story chain (project_setup → qa_setup,
  component subgraph, three_amigos_complete, bdd_specs_exist/passing)
  but leaves qa_complete open so the spex drives it.

  Requires context from `setup_active_project`. Produces:
  - `context.story` — the created story struct
  - `context.task_id` — an active `qa_complete` session task id
  - `context.session_id` — the external conversation id of the seeded session
  - `context.persona_id` and `context.persona_slug` (from project kickoff)
  - `context.component` — the synced architecture component

  Used by Stories 726 and 727 spex — all QA tool specs need a story with
  a valid session task so `submit_qa_result` can resolve `story_id` and
  `agent_id` from the session's tasks JSONB.

      setup :setup_active_project
      setup :setup_qa_story_task
  """
  def setup_qa_story_task(context) do
    # Apply the full project + story chain (component subgraph + three_amigos
    # + bdd_specs) but NOT qa_complete — the spex drives that itself.
    context = CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)

    scope = context.scope
    story = context.story

    # Create an active session with a qa_complete task for this story
    {_story, task_id, session} = Fixtures.qa_story_task_fixture(scope, story: story)

    Map.merge(context, %{
      story: story,
      task_id: task_id,
      session_id: session.external_conversation_id
    })
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

  @doc """
  Synchronously drains the channel's mailbox so callbacks like
  `:after_join` have run before the next observation.

  Phoenix channels send `:after_join` to themselves and process it
  asynchronously. Without this barrier, a test that joins a channel
  and then immediately observes the LiveView can see stale state —
  the channel hasn't yet called `Presence.track`, so no diff has
  been broadcast.

  Use after `subscribe_and_join/3`:

      {:ok, _reply, channel_socket} = subscribe_and_join(...)
      wait_for_channel(channel_socket)
  """
  def wait_for_channel(%Phoenix.Socket{channel_pid: pid} = socket) do
    :sys.get_state(pid)
    socket
  end
end
