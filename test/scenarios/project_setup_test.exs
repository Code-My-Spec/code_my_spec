defmodule CodeMySpec.Scenarios.ProjectSetupTest do
  @moduledoc """
  Scenario replay test for Phase 1: Project Setup.

  Replays a recorded transcript of Claude setting up a Phoenix project
  with CodeMySpec deps, .code_my_spec/ structure, and configuration.

  Server-side operations (symlinks, agents.md, rules, claude.md) are
  triggered via bootstrap API curl calls in the real flow. Since there's
  no server in tests, we call the install functions directly after replay.
  """
  use CodeMySpecTest.DataCase, async: false

  @moduletag :scenario

  import CodeMySpec.ScenarioFixtures
  import CodeMySpec.Support.ScenarioHelpers

  alias CodeMySpec.AgentTasks.ProjectSetup

  @phase "01_project_setup"

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("scenario_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    project_dir = checkout_scenario_project(tmp_dir)
    %{scope: scope, stories: stories} = scenario_base_fixture()
    scope = put_scenario_environment(scope, project_dir)
    session = scenario_session_fixture(scope, ProjectSetup)

    # Simulate bootstrap init API creating config.yml before the agent runs
    install_cli_config(project_dir)

    %{scope: scope, stories: stories, project_dir: project_dir, session: session}
  end

  test "replay applies all file operations", ctx do
    replay_phase(ctx.project_dir, @phase)

    # mix.exs was edited (CodeMySpec deps added)
    mix_content = File.read!(Path.join(ctx.project_dir, "mix.exs"))
    assert mix_content =~ "client_utils"
    assert mix_content =~ "sexy_spex"
    assert mix_content =~ "credo"
    assert mix_content =~ "sobelow"
  end

  test "project structure created after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    assert File.dir?(Path.join(ctx.project_dir, ".code_my_spec"))
    assert File.dir?(Path.join(ctx.project_dir, ".code_my_spec/rules"))
    assert File.dir?(Path.join(ctx.project_dir, ".code_my_spec/spec/math_test_project"))
    assert File.dir?(Path.join(ctx.project_dir, ".code_my_spec/spec/math_test_project_web"))
  end

  test "codemyspec config exists after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    config_path = Path.join(ctx.project_dir, ".code_my_spec/config.yml")
    assert File.exists?(config_path)
  end

  test "test boundary files created after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    assert File.exists?(Path.join(ctx.project_dir, "test/support/math_test_project_spex.ex"))
    assert File.exists?(Path.join(ctx.project_dir, "test/support/math_test_project_test_boundary.ex"))
  end

  test "application module moved to web namespace after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    assert File.exists?(Path.join(ctx.project_dir, "lib/math_test_project_web/application.ex"))
  end

  test "evaluate returns valid after replay + server-side installs", ctx do
    replay_phase(ctx.project_dir, @phase)

    # Server-side operations that would be triggered via bootstrap API curls
    :ok = ProjectSetup.install_app_symlinks(ctx.project_dir)
    :ok = ProjectSetup.install_agents_md(ctx.project_dir)
    :ok = ProjectSetup.install_rules(ctx.project_dir)
    :ok = ProjectSetup.install_claude_md(ctx.project_dir)

    assert {:ok, :valid} = ProjectSetup.evaluate(ctx.scope, ctx.session, [])
  end
end
