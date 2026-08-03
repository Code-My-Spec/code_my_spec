defmodule CodeMySpecWeb.Tasks.NextTaskLiveTest do
  @moduledoc """
  NextTaskLive no longer looks a project up from a `project_name` param —
  `PortableHost` resolves it once for every portable view and assigns `scope`
  and `project` before `handle_params` runs. These tests hand it that socket.

  The "unknown project" case moved out with the lookup: this module cannot
  observe a bad project any more, because the host fails first. What is left
  here is the part that is still its own — computing the requirement markdown.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpecWeb.Tasks.NextTaskLive
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "handle_params/3" do
    test "renders markdown for the host-resolved project" do
      {project, scope} = setup_local_project()

      socket = build_socket(project, scope)
      {:noreply, socket} = NextTaskLive.handle_params(%{}, "/", socket)

      assert socket.assigns.project.id == project.id
      assert socket.assigns.error == nil
      assert is_binary(socket.assigns.markdown)
    end

    test "renders next requirements for an unbootstrapped project" do
      {project, scope} = setup_local_project()

      socket = build_socket(project, scope)
      {:noreply, socket} = NextTaskLive.handle_params(%{}, "/", socket)

      # An unbootstrapped project computes project-level requirements
      # (project_setup, all_bdd_specs_passing, etc.) which appear in
      # the rendered markdown.
      assert socket.assigns.markdown =~ "### ProjectSetup"
      assert socket.assigns.markdown =~ "start_task"
    end

    test "does nothing until the host has resolved a scope" do
      socket = build_socket(nil, nil)

      assert {:noreply, ^socket} = NextTaskLive.handle_params(%{}, "/", socket)
    end
  end

  describe "mount/3" do
    test "initializes its own assigns and leaves the host's alone" do
      {:ok, socket} = NextTaskLive.mount(%{}, %{}, build_socket(nil, nil))

      assert socket.assigns.markdown == nil
      assert socket.assigns.error == nil
      assert socket.assigns.section == :next_task
      assert socket.assigns.sync_status == :idle
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
  defp build_socket(project, scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        projects: [],
        scope: scope,
        project: project,
        markdown: nil,
        error: nil,
        sync_status: :idle,
        sync_error: nil,
        flash: %{},
        live_action: nil
      },
      endpoint: CodeMySpecWeb.Endpoint
    }
  end
end
