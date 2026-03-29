defmodule CodeMySpec.Integration.InitWorkflowTest do
  @moduledoc """
  Integration test for the full init → project setup transition.

  Verifies that get_next_requirement guides the agent through:
  1. Init checklist (no project)
  2. Link project → computed graph returns project_setup directly
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Projects


  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  test "full init flow: init checklist → link project → computed graph returns project_setup" do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    frame = %Frame{assigns: %{working_dir: tmp_dir}}

    # Step 1: no project — get_next_requirement returns init checklist
    {:reply, init_resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    refute init_resp.isError
    assert is_nil(init_resp.structured_content)
    init_text = response_text(init_resp)
    assert init_text =~ "Initialization"
    assert init_text =~ "get_next_requirement"

    # The init checklist should not reference curl endpoints
    refute init_text =~ "curl"

    # Step 2: seed a Phoenix project in the tmp dir (satisfies PhoenixProject step)
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project
      def project, do: [app: :my_app]
    end
    """)

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "config"))

    # Step 3: still init (no project in DB yet)
    {:reply, still_init_resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    assert is_nil(still_init_resp.structured_content)

    # Step 4: create project in DB with local_path (simulates init_project MCP tool)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})
    scope = %{scope | active_project: project, environment: Environment.new(:local, tmp_dir)}

    # Step 5: get_next_requirement computes the graph directly — returns project_setup
    {:reply, graph_resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    refute graph_resp.isError
    graph_text = response_text(graph_resp)
    assert graph_text =~ "Next Requirement: project_setup"
  end

end
