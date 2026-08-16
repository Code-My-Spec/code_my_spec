defmodule CodeMySpec.AgentTasks.ResearchTopicTest do
  @moduledoc false
  use CodeMySpecTest.DataCase, async: true

  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.ResearchTopic
  alias CodeMySpec.Environments.Environment

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp create_task(context) do
    task = %{
      project_id: context.scope.active_project.id,
      component_id: nil,
      story_id: nil,
      requirement_name: "wallaby",
      state: %{"topic" => "wallaby"}
    }

    Map.put(context, :task, task)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_research_brief(env, topic, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/tasks/research/#{topic}.md",
      content || "Research Wallaby for integration testing in a Phoenix LiveView project."
    )
  end

  defp write_mix_exs(env) do
    write_file!(env, "mix.exs", """
    defmodule MyApp.MixProject do
      use Mix.Project
      def project do
        [app: :my_app, version: "0.1.0", deps: deps()]
      end
      defp deps do
        [{:phoenix, "~> 1.7"}, {:phoenix_live_view, "~> 1.0"}]
      end
    end
    """)
  end

  defp write_decision_record(env, topic, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/architecture/decisions/#{topic}.md",
      content ||
        """
        # Use Wallaby for Integration Testing

        ## Status
        Accepted

        ## Context
        We need browser-based integration tests for our LiveView app.

        ## Decision
        Use Wallaby with ChromeDriver for integration testing.

        ## Consequences
        Adds a test dependency and requires ChromeDriver in CI.
        """
    )
  end

  defp write_knowledge(env, topic) do
    write_file!(
      env,
      ".code_my_spec/knowledge/#{topic}/getting_started.md",
      "# Getting Started with Wallaby\n\nInstall wallaby..."
    )
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with non-empty prompt string", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes topic name in prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ "wallaby"
    end

    test "includes ADR content as decision context", %{scope: scope, task: task} do
      write_decision_record(scope.environment, "wallaby")

      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ "Use Wallaby for Integration Testing"
      assert prompt =~ "browser-based integration tests"
    end

    test "includes research brief when one exists", %{scope: scope, task: task} do
      write_research_brief(scope.environment, "wallaby")

      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ "Research Wallaby for integration testing"
    end

    test "omits research brief section when none exists", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      refute prompt =~ "Research Brief"
    end

    test "includes mix.exs content when available", %{scope: scope, task: task} do
      write_mix_exs(scope.environment)

      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ "phoenix_live_view"
    end

    test "references existing knowledge entries and instructs to update not duplicate", %{
      scope: scope,
      task: task
    } do
      write_knowledge(scope.environment, "wallaby")

      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ "getting_started.md"
      assert prompt =~ ~r/update|extend/i
    end

    test "includes Hex.pm search instructions with specific checks", %{
      scope: scope,
      task: task
    } do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/hex\.pm/i
      assert prompt =~ ~r/download/i
      assert prompt =~ ~r/last release|maintenance/i
    end

    test "includes official documentation fetch instructions", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/hexdocs|official doc|documentation/i
    end

    test "includes project inspection instructions", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ "mix.exs"
      assert prompt =~ "config/"
      assert prompt =~ "lib/"
      assert prompt =~ "test/"
    end

    test "includes alternative comparison instructions", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/alternative|compare/i
    end

    test "includes community health check instructions", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/elixir forum|elixirforum/i
      assert prompt =~ ~r/github/i
    end

    test "includes evaluation criteria: compatibility", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/compat/i
    end

    test "includes evaluation criteria: maintenance", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/mainten/i
    end

    test "includes evaluation criteria: community", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/community/i
    end

    test "includes evaluation criteria: complexity", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/complex/i
    end

    test "includes evaluation criteria: testing", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ~r/testing|test suite/i
    end

    test "includes knowledge entry writing instructions with file-per-subtopic pattern", %{
      scope: scope,
      task: task
    } do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      assert prompt =~ ".code_my_spec/knowledge/wallaby/"
      assert prompt =~ ~r/getting_started\.md|configuration\.md|patterns\.md/
    end

    test "does NOT reference a specific subagent by name", %{scope: scope, task: task} do
      assert {:ok, prompt} = ResearchTopic.command(scope, task)
      refute prompt =~ ~r/@"CodeMySpec:/
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_task]

    test "returns {:ok, :valid} when knowledge entries exist for the topic", %{
      scope: scope,
      task: task
    } do
      write_knowledge(scope.environment, "wallaby")

      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopic.evaluate(scope, task)
      end)
    end

    test "returns {:ok, :invalid, feedback} when no knowledge entries exist", %{
      scope: scope,
      task: task
    } do
      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ResearchTopic.evaluate(scope, task)
        assert is_binary(feedback)
        assert String.length(feedback) > 0
      end)
    end

    test "cleans up research prompt file on successful validation", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_knowledge(env, "wallaby")
      write_research_brief(env, "wallaby")

      prompt_path = Path.join(env.cwd, ".code_my_spec/tasks/research/wallaby.md")
      assert File.exists?(prompt_path)

      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopic.evaluate(scope, task)
      end)

      refute File.exists?(prompt_path)
    end

    test "does not clean up research prompt when validation fails", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_research_brief(env, "wallaby")

      prompt_path = Path.join(env.cwd, ".code_my_spec/tasks/research/wallaby.md")
      assert File.exists?(prompt_path)

      capture_log(fn ->
        assert {:ok, :invalid, _feedback} = ResearchTopic.evaluate(scope, task)
      end)

      assert File.exists?(prompt_path)
    end

    test "raises when task has no topic", %{scope: scope} do
      task_without_topic = %{state: %{}}

      assert_raise RuntimeError, ~r/topic/i, fn ->
        ResearchTopic.evaluate(scope, task_without_topic)
      end
    end
  end
end
