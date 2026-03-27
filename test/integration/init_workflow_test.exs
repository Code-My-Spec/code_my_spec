defmodule CodeMySpec.Integration.InitWorkflowTest do
  @moduledoc """
  Integration test for the init → project setup transition.

  Verifies that get_next_requirement returns the init checklist when no
  project exists, and transitions to the requirements graph once a project
  is linked.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.RequirementsRepository

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  test "transitions from init checklist to requirements graph when project is linked" do
    {:ok, tmp_dir} = Briefly.create(directory: true)

    # Step 1: no project — get_next_requirement returns init checklist
    frame = %Frame{assigns: %{working_dir: tmp_dir}}

    {:reply, init_resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    refute init_resp.isError
    assert init_resp.structured_content == %{status: :init_required}
    init_text = response_text(init_resp)
    assert init_text =~ "Initialization"

    # Step 2: seed a Phoenix project in the tmp dir (satisfies PhoenixProject step)
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule MyApp.MixProject do\n  use Mix.Project\n  def project, do: [app: :my_app]\nend")
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "config"))

    # Step 3: call get_next_requirement again — still init (no project in DB)
    {:reply, still_init_resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    assert still_init_resp.structured_content == %{status: :init_required}

    # Step 4: create project in DB with local_path (simulates init_project MCP tool)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})
    scope = %{scope | active_project: project, environment: Environment.new(:local, tmp_dir)}

    # Seed a requirement so the graph has something to return
    project_requirement_fixture(scope, %{
      name: "project_setup",
      artifact_type: :specification,
      satisfied: false,
      satisfied_by: CodeMySpec.AgentTasks.ProjectSetup
    })

    # Step 5: get_next_requirement now finds the project → returns project_setup
    {:reply, graph_resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    refute graph_resp.isError
    data = extract_data(graph_resp)
    assert data["requirement_name"] == "project_setup"
  end

  defp project_requirement_fixture(scope, attrs) do
    attrs =
      Map.merge(
        %{
          description: "test",
          checker_module: CodeMySpec.Requirements.ArtifactExistenceChecker,
          score: 0.0,
          checked_at: DateTime.utc_now()
        },
        attrs
      )

    {:ok, req} =
      RequirementsRepository.create_project_requirement(scope, scope.active_project, attrs)

    req
  end
end
