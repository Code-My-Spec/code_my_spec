defmodule CodeMySpec.Scenarios.PromptSnapshotsTest do
  @moduledoc """
  Snapshot tests for agent task prompts.

  Captures the output of `command/3` for each phase and compares against
  saved snapshots. When a prompt changes, this test fails.

  Run: mix test test/scenarios/prompt_snapshots_test.exs --include scenario
  Update: UPDATE_SNAPSHOTS=true mix test test/scenarios/prompt_snapshots_test.exs --include scenario
  """
  use CodeMySpec.DataCase, async: false

  @moduletag :scenario

  import CodeMySpec.ScenarioFixtures
  import CodeMySpec.Support.ScenarioHelpers

  alias CodeMySpec.AgentTasks.{ArchitectureDesign, ProjectSetup, TechnicalStrategy}

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("scenario_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    project_dir = checkout_scenario_project(tmp_dir)
    %{scope: scope, stories: stories} = scenario_base_fixture()
    scope = put_scenario_environment(scope, project_dir)

    %{scope: scope, stories: stories, project_dir: project_dir}
  end

  describe "project_setup prompt" do
    test "matches snapshot", ctx do
      session = scenario_session_fixture(ctx.scope, ProjectSetup)

      {:ok, prompt} = ProjectSetup.command(ctx.scope, session, [])

      assert_snapshot("project_setup_prompt", prompt)
    end
  end

  describe "technical_strategy prompt" do
    test "matches snapshot", ctx do
      replay_phase(ctx.project_dir, "01_project_setup")

      session = scenario_session_fixture(ctx.scope, TechnicalStrategy)

      {:ok, prompt} = TechnicalStrategy.command(ctx.scope, session, [])

      assert_snapshot("technical_strategy_prompt", prompt)
    end
  end

  describe "architecture_design prompt" do
    test "matches snapshot", ctx do
      replay_phases(ctx.project_dir, ["01_project_setup", "02_technical_strategy"])

      session = scenario_session_fixture(ctx.scope, ArchitectureDesign)

      {:ok, prompt} = ArchitectureDesign.command(ctx.scope, session, [])

      assert_snapshot("architecture_design_prompt", prompt)
    end
  end
end
