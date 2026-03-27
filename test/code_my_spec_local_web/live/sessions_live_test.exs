defmodule CodeMySpecLocalWeb.SessionsLiveTest do
  use ExUnit.Case, async: true

  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpecLocalWeb.SessionsLive
  alias CodeMySpec.Sessions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "handle_params :index" do
    test "loads sessions for the project" do
      {project, scope} = setup_local_project()
      _session = session_fixture(scope)

      socket = build_socket(:index)
      {:noreply, socket} = SessionsLive.handle_params(%{"project_name" => project.name}, "/", socket)

      assert socket.assigns.project.id == project.id
      assert length(socket.assigns.sessions) == 1
      assert socket.assigns.error == nil
    end

    test "returns empty list when no sessions" do
      {project, _scope} = setup_local_project()

      socket = build_socket(:index)
      {:noreply, socket} = SessionsLive.handle_params(%{"project_name" => project.name}, "/", socket)

      assert socket.assigns.sessions == []
    end

    test "returns error for non-existent project" do
      socket = build_socket(:index)
      {:noreply, socket} = SessionsLive.handle_params(%{"project_name" => "nonexistent"}, "/", socket)

      assert socket.assigns.error != nil
    end
  end

  describe "handle_params :show" do
    test "loads a specific session" do
      {project, scope} = setup_local_project()
      session = session_fixture(scope)

      socket = build_socket(:show)
      {:noreply, socket} = SessionsLive.handle_params(%{"project_name" => project.name, "id" => session.id}, "/", socket)

      assert socket.assigns.session.id == session.id
      assert socket.assigns.error == nil
    end

    test "returns error for non-existent session" do
      {project, _scope} = setup_local_project()

      socket = build_socket(:show)
      {:noreply, socket} = SessionsLive.handle_params(%{"project_name" => project.name, "id" => Ecto.UUID.generate()}, "/", socket)

      assert socket.assigns.error =~ "Session not found"
    end
  end

  describe "handle_params :task_show" do
    test "loads a specific task within a session" do
      {project, scope} = setup_local_project()
      session = session_fixture(scope)

      {:ok, session} = Sessions.prepare_task(scope, session, %{
        session_type: CodeMySpec.AgentTasks.ContextSpec,
        requirement_name: "test_spec",
        project_id: scope.active_project_id
      })

      task = List.first(session.tasks)

      socket = build_socket(:task_show)
      {:noreply, socket} = SessionsLive.handle_params(
        %{"project_name" => project.name, "id" => session.id, "task_id" => task.id},
        "/",
        socket
      )

      assert socket.assigns.task.id == task.id
      assert socket.assigns.session.id == session.id
      assert socket.assigns.error == nil
    end

    test "returns error for non-existent task" do
      {project, scope} = setup_local_project()
      session = session_fixture(scope)

      socket = build_socket(:task_show)
      {:noreply, socket} = SessionsLive.handle_params(
        %{"project_name" => project.name, "id" => session.id, "task_id" => Ecto.UUID.generate()},
        "/",
        socket
      )

      assert socket.assigns.error =~ "Task not found"
    end
  end

  describe "mount/3" do
    test "initializes with nil assigns" do
      {:ok, socket} = SessionsLive.mount(%{}, %{}, build_socket(:index))

      assert socket.assigns.project == nil
      assert socket.assigns.sessions == []
      assert socket.assigns.session == nil
      assert socket.assigns.task == nil
      assert socket.assigns.error == nil
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

  defp build_socket(action) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        live_action: action,
        project: nil,
        sessions: [],
        session: nil,
        task: nil,
        error: nil,
        flash: %{}
      },
      endpoint: CodeMySpecLocalWeb.Endpoint
    }
  end
end
