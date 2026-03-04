defmodule CodeMySpec.Scenarios.ArchitectureDesignTest do
  @moduledoc """
  Scenario replay test for Phase 3: Architecture Design.

  Checks out post-setup state, applies tech strategy (command + transcript),
  then replays architecture design transcript and verifies evaluate passes.

  Requires `03_architecture_design.jsonl` transcript — tests are tagged
  :pending until it's recorded.
  """
  use CodeMySpecTest.DataCase, async: false

  @moduletag :scenario

  import CodeMySpec.ScenarioFixtures
  import CodeMySpec.Support.ScenarioHelpers

  alias CodeMySpec.AgentTasks.{ArchitectureDesign, TechnicalStrategy}

  @phase "03_architecture_design"

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("scenario_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Start from post-setup, apply tech strategy
    project_dir = checkout_scenario_project(tmp_dir, post_setup_ref())
    %{scope: scope, stories: stories} = scenario_base_fixture()
    scope = put_scenario_environment(scope, project_dir)

    ts_session = scenario_session_fixture(scope, TechnicalStrategy)
    {:ok, _} = TechnicalStrategy.command(scope, ts_session, [])
    replay_phase(project_dir, "02_technical_strategy")

    session = scenario_session_fixture(scope, ArchitectureDesign)

    %{scope: scope, stories: stories, project_dir: project_dir, session: session}
  end

  test "architecture files exist after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    assert File.exists?(Path.join(ctx.project_dir, ".code_my_spec/architecture/overview.md"))
    assert File.exists?(Path.join(ctx.project_dir, ".code_my_spec/architecture/namespace_hierarchy.md"))
  end

  test "evaluate returns valid after replay", ctx do
    replay_phase(ctx.project_dir, @phase)
    rewrite_proposal_story_ids(ctx.project_dir, ctx.stories)

    assert {:ok, :valid} = ArchitectureDesign.evaluate(ctx.scope, ctx.session, [])
  end
end
