defmodule CodeMySpec.Scenarios.TechnicalStrategyTest do
  @moduledoc """
  Scenario replay test for Phase 2: Technical Strategy.

  Replays project setup transcript, then calls TechnicalStrategy.command/3
  (which writes pre-made decision ADRs server-side), replays the technical
  strategy transcript, and verifies evaluate passes.

  The command/3 call is important because it writes pre-made decision files
  to disk before the agent starts — these are NOT in the Claude transcript.
  """
  use CodeMySpec.DataCase, async: false

  @moduletag :scenario

  import CodeMySpec.ScenarioFixtures
  import CodeMySpec.Support.ScenarioHelpers

  alias CodeMySpec.AgentTasks.TechnicalStrategy

  @prerequisites ["01_project_setup"]
  @phase "02_technical_strategy"

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("scenario_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    project_dir = checkout_scenario_project(tmp_dir)
    %{scope: scope, stories: stories} = scenario_base_fixture()
    scope = put_scenario_environment(scope, project_dir)
    session = scenario_session_fixture(scope, TechnicalStrategy)

    # Apply phase 1 filesystem state
    replay_phases(project_dir, @prerequisites)

    # command/3 writes pre-made decision ADRs server-side before the agent runs
    {:ok, _prompt} = TechnicalStrategy.command(scope, session, [])

    %{scope: scope, stories: stories, project_dir: project_dir, session: session}
  end

  test "pre-made decision files exist after command", ctx do
    decisions_dir = Path.join(ctx.project_dir, ".code_my_spec/architecture/decisions")

    for topic <- ~w(elixir phoenix liveview tailwind daisyui phx-gen-auth exvcr bdd-testing dotenvy ngrok) do
      assert File.exists?(Path.join(decisions_dir, "#{topic}.md")),
             "Missing pre-made decision: #{topic}"
    end
  end

  test "decisions index exists after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    assert File.exists?(Path.join(ctx.project_dir, ".code_my_spec/architecture/decisions.md"))
  end

  test "research topics cleaned up after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    research_dir = Path.join(ctx.project_dir, ".code_my_spec/status/research")

    if File.dir?(research_dir) do
      research_files = Path.wildcard(Path.join(research_dir, "*.md"))
      assert research_files == [], "Research topic files should be cleaned up: #{inspect(research_files)}"
    end
  end

  test "non-pre-made decisions have knowledge entries after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    decisions_dir = Path.join(ctx.project_dir, ".code_my_spec/architecture/decisions")
    knowledge_dir = Path.join(ctx.project_dir, ".code_my_spec/knowledge")

    premade_topics = Enum.map(TechnicalStrategy.premade_decisions(), & &1.topic)

    all_decisions =
      decisions_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> Enum.reject(&(&1 == "decisions"))

    researched = Enum.reject(all_decisions, &(&1 in premade_topics))

    for topic <- researched do
      topic_knowledge = Path.wildcard(Path.join([knowledge_dir, topic, "**"]))
      assert topic_knowledge != [], "Missing knowledge entries for researched topic: #{topic}"
    end
  end

  test "evaluate returns valid after replay", ctx do
    replay_phase(ctx.project_dir, @phase)

    assert {:ok, :valid} = TechnicalStrategy.evaluate(ctx.scope, ctx.session, [])
  end
end
