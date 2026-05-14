defmodule CodeMySpecLocalWeb.Tasks.NextTaskLiveTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpecLocalWeb.Tasks.NextTaskLive
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "handle_params/3" do
    test "loads project and renders markdown" do
      {project, _scope} = setup_local_project()

      socket = build_socket()
      {:noreply, socket} = NextTaskLive.handle_params(%{"project_name" => project.name}, "/", socket)

      assert socket.assigns.project.id == project.id
      assert socket.assigns.error == nil
      assert is_binary(socket.assigns.markdown)
    end

    test "renders next requirements for an unbootstrapped project" do
      {project, _scope} = setup_local_project()

      socket = build_socket()
      {:noreply, socket} = NextTaskLive.handle_params(%{"project_name" => project.name}, "/", socket)

      # An unbootstrapped project computes project-level requirements
      # (project_setup, all_bdd_specs_passing, etc.) which appear in
      # the rendered markdown.
      assert socket.assigns.markdown =~ "### ProjectSetup"
      assert socket.assigns.markdown =~ "start_task"
    end

    test "returns error for non-existent project" do
      socket = build_socket()
      {:noreply, socket} = NextTaskLive.handle_params(%{"project_name" => "nonexistent"}, "/", socket)

      assert socket.assigns.error =~ "Failed to load project"
    end
  end

  describe "mount/3" do
    test "initializes with nil assigns" do
      {:ok, socket} = NextTaskLive.mount(%{}, %{}, build_socket())

      assert socket.assigns.project == nil
      assert socket.assigns.markdown == nil
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

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        projects: [],
        project: nil,
        markdown: nil,
        error: nil,
        flash: %{},
        live_action: nil
      },
      endpoint: CodeMySpecLocalWeb.Endpoint
    }
  end
end
