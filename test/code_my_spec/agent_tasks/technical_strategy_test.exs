defmodule CodeMySpec.AgentTasks.TechnicalStrategyTest do
  @moduledoc false
  use CodeMySpec.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.TechnicalStrategy
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
    %{scope: scope} = context
    session = %{project: scope.active_project}
    Map.put(context, :session, session)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
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

  defp write_existing_decision(env, topic, content \\ nil) do
    write_file!(
      env,
      "docs/architecture/decisions/#{topic}.md",
      content ||
        """
        # Use #{topic}

        ## Status
        Accepted

        ## Decision
        We decided to use #{topic}.
        """
    )
  end

  defp write_decisions_index(env, content \\ nil) do
    write_file!(
      env,
      "docs/architecture/decisions.md",
      content ||
        """
        # Architecture Decisions

        | Topic | Decision | Status |
        |---|---|---|
        """
    )
  end

  defp write_research_prompt(env, topic, content \\ nil) do
    write_file!(
      env,
      "docs/status/research/#{topic}.md",
      content || "Research #{topic} for the project."
    )
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with orchestration prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes project name", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ scope.active_project.name
    end

    test "includes deps context when mix.exs exists", %{scope: scope, session: session} do
      write_mix_exs(scope.environment)

      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "phoenix" or prompt =~ "mix.exs"
    end

    test "lists existing decisions", %{scope: scope, session: session} do
      env = scope.environment
      write_existing_decision(env, "tailwind")

      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "tailwind"
    end

    test "instructs agent to write research prompts", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "docs/status/research/"
    end

    test "instructs agent to use researcher subagent", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "researcher"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when no research prompts remain and index exists", %{
      scope: scope,
      session: session
    } do
      write_decisions_index(scope.environment)

      assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when research prompts exist but topic is incomplete",
         %{
           scope: scope,
           session: session
         } do
      env = scope.environment
      write_research_prompt(env, "wallaby")
      write_decisions_index(env)

      assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
      assert feedback =~ "wallaby"
    end

    test "returns {:ok, :valid} when all research topics pass validation", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_research_prompt(env, "wallaby")

      write_existing_decision(env, "wallaby", """
      # Use Wallaby

      ## Status
      Accepted

      ## Decision
      Use Wallaby for integration testing.
      """)

      write_decisions_index(env, """
      # Architecture Decisions

      | Topic | Decision | Status |
      |---|---|---|
      | wallaby | Use Wallaby for integration testing | Accepted |
      """)

      assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when decisions index is missing", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
      assert feedback =~ "index"
    end

    test "reports multiple incomplete topics", %{scope: scope, session: session} do
      env = scope.environment
      write_research_prompt(env, "wallaby")
      write_research_prompt(env, "pwa")
      write_decisions_index(env)

      assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
      assert feedback =~ "wallaby"
      assert feedback =~ "pwa"
    end
  end
end
