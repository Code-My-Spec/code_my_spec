defmodule CodeMySpecWeb.SessionsLiveTest do
  @moduledoc """
  SessionsLive used to resolve the project itself, from a `project_name` param.
  It doesn't any more — `PortableHost` resolves the project once, for every
  portable view, and assigns `scope` and `project` before `handle_params` runs.

  So these tests hand it the socket the host would have built, and the
  "unknown project" case is gone from here entirely: this module can no longer
  observe a bad project id, because the host fails before it is reached. That
  case belongs to the host's own tests, which is the point of having a seam.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Sessions
  alias CodeMySpecWeb.SessionsLive
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "handle_params :index" do
    test "loads sessions for the project" do
      {project, scope} = setup_local_project()
      _session = session_fixture(scope)

      socket = build_socket(:index, project, scope)
      {:noreply, socket} = SessionsLive.handle_params(%{}, "/", socket)

      assert socket.assigns.project.id == project.id
      assert length(socket.assigns.sessions) == 1
      assert socket.assigns.error == nil
    end

    test "returns empty list when no sessions" do
      {project, scope} = setup_local_project()

      socket = build_socket(:index, project, scope)
      {:noreply, socket} = SessionsLive.handle_params(%{}, "/", socket)

      assert socket.assigns.sessions == []
    end

    test "does nothing until the host has resolved a scope" do
      socket = %{
        build_socket(:index, nil, nil)
        | assigns: %{__changed__: %{}, live_action: :index, error: nil}
      }

      assert {:noreply, ^socket} = SessionsLive.handle_params(%{}, "/", socket)
    end
  end

  describe "handle_params :show" do
    test "loads a specific session" do
      {project, scope} = setup_local_project()
      session = session_fixture(scope)

      socket = build_socket(:show, project, scope)
      {:noreply, socket} = SessionsLive.handle_params(%{"id" => session.id}, "/", socket)

      assert socket.assigns.session.id == session.id
      assert socket.assigns.error == nil
    end

    test "returns error for non-existent session" do
      {project, scope} = setup_local_project()

      socket = build_socket(:show, project, scope)

      {:noreply, socket} =
        SessionsLive.handle_params(%{"id" => Ecto.UUID.generate()}, "/", socket)

      assert socket.assigns.error =~ "Session not found"
    end
  end

  describe "handle_params :task_show" do
    test "loads a specific task within a session" do
      {project, scope} = setup_local_project()
      session = session_fixture(scope)

      {:ok, session} =
        Sessions.prepare_task(scope, session, %{
          session_type: CodeMySpec.AgentTasks.ContextSpec,
          requirement_name: "test_spec",
          project_id: scope.active_project_id
        })

      task = List.first(session.tasks)

      socket = build_socket(:task_show, project, scope)

      {:noreply, socket} =
        SessionsLive.handle_params(%{"id" => session.id, "task_id" => task.id}, "/", socket)

      assert socket.assigns.task.id == task.id
      assert socket.assigns.session.id == session.id
      assert socket.assigns.error == nil
    end

    test "returns error for non-existent task" do
      {project, scope} = setup_local_project()
      session = session_fixture(scope)

      socket = build_socket(:task_show, project, scope)

      {:noreply, socket} =
        SessionsLive.handle_params(
          %{"id" => session.id, "task_id" => Ecto.UUID.generate()},
          "/",
          socket
        )

      assert socket.assigns.error =~ "Task not found"
    end
  end

  describe "mount/3" do
    test "initializes its own assigns and leaves the host's alone" do
      {:ok, socket} = SessionsLive.mount(%{}, %{}, build_socket(:index, nil, nil))

      assert socket.assigns.sessions == []
      assert socket.assigns.session == nil
      assert socket.assigns.task == nil
      assert socket.assigns.error == nil
      assert socket.assigns.section == :sessions
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_local_project do
    scope = full_scope_fixture()
    project = scope.active_project

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, project, %{local_path: "/tmp/test-project"})

    scope = %{scope | active_project: project}
    {project, scope}
  end

  # Mirrors what PortableHost leaves on the socket before handle_params runs.
  defp build_socket(action, project, scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        live_action: action,
        scope: scope,
        project: project,
        sessions: [],
        session: nil,
        task: nil,
        error: nil,
        flash: %{}
      },
      endpoint: CodeMySpecWeb.Endpoint
    }
  end
end
