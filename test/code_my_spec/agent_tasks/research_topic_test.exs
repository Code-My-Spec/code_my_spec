defmodule CodeMySpec.AgentTasks.ResearchTopicTest do
  @moduledoc false
  use CodeMySpec.DataCase

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

  defp create_session(context) do
    session = %{
      project: context.scope.active_project,
      state: %{"topic" => "wallaby"}
    }

    Map.put(context, :session, session)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_research_brief(env, topic, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/status/research/#{topic}.md",
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

  defp write_decisions_index(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/architecture/decisions.md",
      content ||
        """
        # Architecture Decisions

        | Topic | Decision | Status |
        |---|---|---|
        | wallaby | Use Wallaby for integration testing | Accepted |
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
    setup [:create_scope, :create_session]

    test "returns ok tuple with prompt containing topic name", %{scope: scope, session: session} do
      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert is_binary(prompt)
      assert prompt =~ "wallaby"
    end

    test "includes research brief when prompt file exists", %{scope: scope, session: session} do
      write_research_brief(scope.environment, "wallaby")

      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert prompt =~ "Research Wallaby for integration testing"
    end

    test "includes deps context when mix.exs exists", %{scope: scope, session: session} do
      write_mix_exs(scope.environment)

      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert prompt =~ "mix.exs" or prompt =~ "phoenix"
    end

    test "references existing knowledge when present", %{scope: scope, session: session} do
      write_knowledge(scope.environment, "wallaby")

      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert prompt =~ "Existing Knowledge" or prompt =~ "knowledge"
    end

    test "references existing decision record when present", %{scope: scope, session: session} do
      write_decision_record(scope.environment, "wallaby")

      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert prompt =~ "Existing Decision" or prompt =~ "decision"
    end

    test "instructs agent to use researcher subagent", %{scope: scope, session: session} do
      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert prompt =~ "researcher"
    end

    test "instructs agent to write decision record", %{scope: scope, session: session} do
      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert prompt =~ ".code_my_spec/architecture/decisions/wallaby.md"
    end

    test "instructs agent to update decisions index", %{scope: scope, session: session} do
      assert {:ok, prompt} = ResearchTopic.command(scope, session)
      assert prompt =~ ".code_my_spec/architecture/decisions.md"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when decision record and index reference exist", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decision_record(env, "wallaby")
      write_decisions_index(env)

      assert {:ok, :valid} = ResearchTopic.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when decision record is missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decisions_index(env)

      assert {:ok, :invalid, feedback} = ResearchTopic.evaluate(scope, session)
      assert feedback =~ "decision record"
    end

    test "returns {:ok, :invalid, feedback} when decisions index is missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decision_record(env, "wallaby")

      assert {:ok, :invalid, feedback} = ResearchTopic.evaluate(scope, session)
      assert feedback =~ "index"
    end

    test "returns {:ok, :invalid, feedback} when index does not reference topic", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decision_record(env, "wallaby")

      write_decisions_index(env, """
      # Architecture Decisions

      | Topic | Decision | Status |
      |---|---|---|
      | pwa | Use service workers | Accepted |
      """)

      assert {:ok, :invalid, feedback} = ResearchTopic.evaluate(scope, session)
      assert feedback =~ "index" and feedback =~ "wallaby"
    end

    test "returns {:ok, :invalid, feedback} when decision record is empty", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decision_record(env, "wallaby", "")
      write_decisions_index(env)

      assert {:ok, :invalid, feedback} = ResearchTopic.evaluate(scope, session)
      assert feedback =~ "empty"
    end

    test "cleans up research prompt file on success", %{scope: scope, session: session} do
      env = scope.environment
      write_research_brief(env, "wallaby")
      write_decision_record(env, "wallaby")
      write_decisions_index(env)

      prompt_path = Path.join(env.cwd, ".code_my_spec/status/research/wallaby.md")
      assert File.exists?(prompt_path)

      assert {:ok, :valid} = ResearchTopic.evaluate(scope, session)
      refute File.exists?(prompt_path)
    end
  end
end
