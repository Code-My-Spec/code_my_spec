defmodule CodeMySpec.Integration.ProjectSetupWorkflowTest do
  @moduledoc """
  The twelve-step setup checklist, and the graph that no longer contains it.

  This used to drive setup through MCP: `get_next_requirement` offered
  `project_setup`, `start_task` opened it, and the stop hook completed it.
  545fb741 took setup out of the requirement graph — `cms new` finishes it, so
  a generated project owes nothing there — and `start_task` refuses a
  requirement the graph does not hold. The MCP path is gone on purpose.

  What survived is the checklist itself, at `/app/projects/:id/setup`, for
  brownfield projects that were not generated. It reads the same
  `AgentTasks.ProjectSetup.command/2` and counts the same twelve steps, so the
  coverage moved to that surface rather than being deleted with the old route.

  Both halves are asserted here: the checklist still counts what is on disk,
  and the graph now starts somewhere else.
  """
  use CodeMySpecTest.ConnCase

  import CodeMySpec.Integration.WorkflowHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Projects
  alias Anubis.Server.Frame

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  # The checklist reads the working copy, so the project has to point at a real
  # directory rather than the fixture's stub.
  setup %{scope: scope, project: project} do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    {:ok, project} = Projects.update_project(scope, project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        environment: Environment.new(:local, tmp_dir),
        cwd: tmp_dir
    }

    %{scope: scope, project: project, tmp_dir: tmp_dir}
  end

  # Asserted against `ProjectSetup.command/2` rather than through the page.
  # The page is a renderer — it calls exactly this and pipes the result through
  # markdown — while the scope it builds comes from the session, so driving it
  # through `live/2` would test scope plumbing and not the counting. The
  # counting is what the removed MCP path used to cover.
  test "the setup checklist counts what is actually on disk", %{
    scope: scope,
    tmp_dir: tmp_dir
  } do
    assert {:ok, text} = ProjectSetup.command(scope, %{})
    assert text =~ "Project Setup (0/12)"
    assert text =~ "- [ ] **Claude md**"

    # One step, done for real. Since 403b3cc the checks read File records
    # rather than the filesystem, so the write has to be synced to count.
    File.write!(
      Path.join(tmp_dir, "CLAUDE.md"),
      "# Project\n<!-- code_my_spec:start -->\nmanaged\n<!-- code_my_spec:end -->"
    )

    {:ok, _} = FileSync.sync_changed(scope, base_dir: tmp_dir)

    assert {:ok, text} = ProjectSetup.command(scope, %{})
    assert text =~ "Project Setup (1/12)"
    assert text =~ "- [x] **Claude md**"

    seed_all_setup_steps(tmp_dir)
    {:ok, _} = FileSync.sync_changed(scope, base_dir: tmp_dir)

    assert {:ok, text} = ProjectSetup.command(scope, %{})
    assert text =~ "Project Setup (12/12)"
    refute text =~ "- [ ] "
  end

  test "the page the checklist now lives on mounts", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, ~p"/app/projects/#{project.id}/setup")

    assert html =~ "Project Setup"
  end

  test "the requirement graph no longer offers setup", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    refute resp.isError

    text = response_text(resp)

    assert text =~ "### PersonaResearch"
    assert text =~ "requirement_name=`personas_complete`"

    refute text =~ "project_setup",
           "setup left the graph in 545fb741 — offering it again would send a " <>
             "generated project back through work `cms new` already did"
  end
end
