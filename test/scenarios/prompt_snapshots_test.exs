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

  alias CodeMySpec.AgentTasks.{ProjectSetup, TechnicalStrategy}

  describe "project_setup prompt" do
    test "matches snapshot" do
      tmp_dir = make_tmp_dir()
      project_dir = checkout_scenario_project(tmp_dir)
      %{scope: scope} = scenario_base_fixture()
      scope = put_scenario_environment(scope, project_dir)
      session = scenario_session_fixture(scope, ProjectSetup)

      {:ok, prompt} = ProjectSetup.command(scope, session, [])

      assert_snapshot("project_setup_prompt", prompt)
    end
  end

  describe "technical_strategy prompt" do
    test "matches snapshot" do
      tmp_dir = make_tmp_dir()
      project_dir = checkout_scenario_project(tmp_dir, post_setup_ref())
      %{scope: scope} = scenario_base_fixture()
      scope = put_scenario_environment(scope, project_dir)
      session = scenario_session_fixture(scope, TechnicalStrategy)

      {:ok, prompt} = TechnicalStrategy.command(scope, session, [])

      assert_snapshot("technical_strategy_prompt", prompt)
    end
  end

  describe "architecture_design prompt" do
    @tag :pending
    test "matches snapshot" do
      # Skip until architecture design phase is recorded
    end
  end

  defp make_tmp_dir do
    tmp_dir = System.tmp_dir!() |> Path.join("scenario_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end
end
