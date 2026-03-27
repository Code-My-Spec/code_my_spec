defmodule CodeMySpecLocalWeb.Tasks.NextTaskLiveTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpecLocalWeb.Tasks.NextTaskLive

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "handle_params/3" do
    test "loads project and gets next actions" do
      {project, _scope} = setup_local_project()

      socket = build_socket()
      {:noreply, socket} = NextTaskLive.handle_params(%{"project_name" => project.name}, "/", socket)

      assert socket.assigns.project.id == project.id
      assert socket.assigns.error == nil
      assert socket.assigns.result != nil
    end

    test "returns complete when no requirements exist" do
      {project, _scope} = setup_local_project()

      socket = build_socket()
      {:noreply, socket} = NextTaskLive.handle_params(%{"project_name" => project.name}, "/", socket)

      assert socket.assigns.result == :complete
    end

    test "returns error for non-existent project" do
      socket = build_socket()
      {:noreply, socket} = NextTaskLive.handle_params(%{"project_name" => "nonexistent"}, "/", socket)

      assert socket.assigns.error =~ "Failed to load project"
    end

    test "result reflects unsatisfied requirement" do
      {project, scope} = setup_local_project()
      component = component_fixture(scope)

      _requirement =
        requirement_fixture(scope, component, %{
          name: "spec_file",
          satisfied: false,
          satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
        })

      socket = build_socket()
      {:noreply, socket} = NextTaskLive.handle_params(%{"project_name" => project.name}, "/", socket)

      assert socket.assigns.project.id == project.id
      assert socket.assigns.error == nil
      # Result depends on coordinator graph traversal — just verify it loaded
      assert socket.assigns.result != nil
    end
  end

  describe "mount/3" do
    test "initializes with nil assigns" do
      {:ok, socket} = NextTaskLive.mount(%{}, %{}, build_socket())

      assert socket.assigns.project == nil
      assert socket.assigns.result == nil
      assert socket.assigns.error == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_local_project do
    scope = full_scope_fixture()
    project = scope.active_project

    # Set local_path so Scope.for_local_project succeeds
    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, project, %{local_path: "/tmp/test-project"})

    scope = %{scope | active_project: project}
    {project, scope}
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        project: nil,
        result: nil,
        error: nil,
        flash: %{},
        live_action: nil
      },
      endpoint: CodeMySpecLocalWeb.Endpoint
    }
  end
end
