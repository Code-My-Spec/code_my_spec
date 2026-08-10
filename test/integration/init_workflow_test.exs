defmodule CodeMySpec.Integration.InitWorkflowTest do
  @moduledoc """
  Integration test for the full init → project setup transition.

  Verifies that get_next_requirement guides the agent through:
  1. Init checklist (no project)
  2. Link project → computed graph returns the first requirement directly
     (personas_complete since project_setup left the graph — see ProjectSetupLive)
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

  test "full init flow: init checklist → link project → computed graph returns the first requirement" do
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

    # From here the frame carries the scope, which is what production does:
    # `HarnessScope` reads `X-Harness-Id` off the request and assigns
    # `current_scope`, so a tool that computes a graph knows which checkout it
    # is answering about.
    #
    # The bare frame above resolves through `working_dir` instead, and that path
    # attaches no harness — `HarnessScope` itself warns that walking up to the
    # nearest `mix.exs` "cannot tell two checkouts apart reliably". A graph built
    # that way blends every checkout's files, which is what
    # `Preloader.load/1` now refuses with `{:error, :no_working_copy}`.
    graph_frame = %Frame{assigns: %{working_dir: tmp_dir, current_scope: scope}}

    # Step 5: get_next_requirement computes the graph directly. Setup used to
    # head this list and no longer does — `cms new` covers it, so a generated
    # project has nothing to do there.
    {:reply, graph_resp, ^graph_frame} = GetNextRequirement.execute(%{}, graph_frame)
    refute graph_resp.isError
    graph_text = response_text(graph_resp)
    assert graph_text =~ "### PersonaResearch"
    assert graph_text =~ "requirement_name=`personas_complete`"
  end
end
