defmodule CodeMySpec.Scenarios.ArchitectureDesignTest do
  @moduledoc """
  Scenario replay test for Phase 3: Architecture Design.

  Replays prerequisite phases + architecture design transcript, then
  verifies the proposal file exists with expected structure.
  """
  use CodeMySpec.DataCase, async: false

  @moduletag :scenario

  import CodeMySpec.ScenarioFixtures
  import CodeMySpec.Support.ScenarioHelpers

  alias CodeMySpec.AgentTasks.ArchitectureDesign

  @prerequisites ["01_project_setup", "02_technical_strategy"]
  @phase "03_architecture_design"

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("scenario_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    project_dir = checkout_scenario_project(tmp_dir)
    %{scope: scope, stories: stories} = scenario_base_fixture()
    scope = put_scenario_environment(scope, project_dir)
    session = scenario_session_fixture(scope, ArchitectureDesign)

    %{scope: scope, stories: stories, project_dir: project_dir, session: session}
  end

  test "proposal file exists after replay", ctx do
    replay_phases(ctx.project_dir, @prerequisites)
    replay_phase(ctx.project_dir, @phase)

    assert File.exists?(Path.join(ctx.project_dir, ".code_my_spec/architecture/proposal.md"))
  end

  test "proposal contains component definitions", ctx do
    replay_phases(ctx.project_dir, @prerequisites)
    replay_phase(ctx.project_dir, @phase)

    proposal = File.read!(Path.join(ctx.project_dir, ".code_my_spec/architecture/proposal.md"))
    assert proposal =~ "MathTestProject"
  end
end
