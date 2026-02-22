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

  defp write_knowledge(env, topic) do
    write_file!(
      env,
      "docs/knowledge/#{topic}/overview.md",
      "# #{topic}\n\nKnowledge about #{topic}."
    )
  end

  defp write_all_premade_decisions(env) do
    for d <- TechnicalStrategy.premade_decisions() do
      write_existing_decision(env, d.topic)
    end
  end

  defp premade_topics do
    Enum.map(TechnicalStrategy.premade_decisions(), & &1.topic)
  end

  # ============================================================================
  # premade_decisions/0 Tests
  # ============================================================================

  describe "premade_decisions/0" do
    test "returns a list of decisions" do
      assert [_ | _] = TechnicalStrategy.premade_decisions()
    end

    test "each decision has required fields" do
      for d <- TechnicalStrategy.premade_decisions() do
        assert is_binary(d.topic)
        assert is_binary(d.title)
        assert is_binary(d.context)
        assert is_binary(d.decision)
      end
    end

    test "includes core stack decisions" do
      topics = premade_topics()
      assert "elixir" in topics
      assert "phoenix" in topics
      assert "liveview" in topics
      assert "tailwind" in topics
      assert "daisyui" in topics
      assert "phx-gen-auth" in topics
      assert "exvcr" in topics
      assert "bdd-testing" in topics
      assert "dotenvy" in topics
      assert "ngrok" in topics
    end
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

    test "includes pre-made decisions section when none are written yet", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "Pre-made Decisions to Write"
      assert prompt =~ "elixir"
      assert prompt =~ "phoenix"
      assert prompt =~ "daisyui"
      assert prompt =~ "Accepted (pre-made)"
    end

    test "excludes pre-made decisions that already have ADRs", %{scope: scope, session: session} do
      env = scope.environment
      write_existing_decision(env, "elixir")
      write_existing_decision(env, "phoenix")

      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      # Should still show remaining pre-made decisions
      assert prompt =~ "Pre-made Decisions to Write"
      assert prompt =~ "daisyui"
    end

    test "omits pre-made decisions section when all are written", %{
      scope: scope,
      session: session
    } do
      write_all_premade_decisions(scope.environment)

      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      # The section heading is "## Pre-made Decisions to Write" — when no
      # missing pre-made decisions exist, this section should be absent.
      refute prompt =~ "## Pre-made Decisions to Write"
      refute prompt =~ "Accepted (pre-made)"
    end

    test "includes knowledge base building step", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "Build Knowledge Base"
      assert prompt =~ "knowledge"
    end

    test "includes bootstrap step", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "Bootstrap"
      assert prompt =~ "Add libraries"
      assert prompt =~ "Configure"
      assert prompt =~ "Smoke test"
    end

    test "instructs to skip knowledge for pre-made decisions", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "not" or prompt =~ "Do **not**"
      assert prompt =~ "pre-made"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when all checks pass", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_all_premade_decisions(env)
      write_decisions_index(env)

      assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when pre-made decisions are missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decisions_index(env)
      # Don't write pre-made decisions

      assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
      assert feedback =~ "pre-made" or feedback =~ "Pre-made"
    end

    test "returns {:ok, :invalid, feedback} when research prompts exist but topic is incomplete",
         %{
           scope: scope,
           session: session
         } do
      env = scope.environment
      write_all_premade_decisions(env)
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
      write_all_premade_decisions(env)
      write_research_prompt(env, "wallaby")

      write_existing_decision(env, "wallaby", """
      # Use Wallaby

      ## Status
      Accepted

      ## Decision
      Use Wallaby for integration testing.
      """)

      write_knowledge(env, "wallaby")

      index_content =
        """
        # Architecture Decisions

        | Topic | Decision | Status |
        |---|---|---|
        | wallaby | Use Wallaby for integration testing | Accepted |
        """ <>
          Enum.map_join(premade_topics(), "\n", fn t ->
            "| #{t} | Pre-made | Accepted |"
          end)

      write_decisions_index(env, index_content)

      assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when decisions index is missing", %{
      scope: scope,
      session: session
    } do
      write_all_premade_decisions(scope.environment)

      assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
      assert feedback =~ "index"
    end

    test "reports multiple incomplete topics", %{scope: scope, session: session} do
      env = scope.environment
      write_all_premade_decisions(env)
      write_research_prompt(env, "wallaby")
      write_research_prompt(env, "pwa")
      write_decisions_index(env)

      assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
      assert feedback =~ "wallaby"
      assert feedback =~ "pwa"
    end

    test "returns {:ok, :invalid, feedback} when non-pre-made topics lack knowledge entries", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_all_premade_decisions(env)
      # A researched topic with decision but no knowledge
      write_existing_decision(env, "wallaby")

      index_content =
        """
        # Architecture Decisions

        | Topic | Decision | Status |
        |---|---|---|
        | wallaby | Use Wallaby | Accepted |
        """ <>
          Enum.map_join(premade_topics(), "\n", fn t ->
            "| #{t} | Pre-made | Accepted |"
          end)

      write_decisions_index(env, index_content)

      assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
      assert feedback =~ "wallaby"
      assert feedback =~ "knowledge"
    end

    test "does not require knowledge entries for pre-made decisions", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_all_premade_decisions(env)

      index_content =
        """
        # Architecture Decisions

        | Topic | Decision | Status |
        |---|---|---|
        """ <>
          Enum.map_join(premade_topics(), "\n", fn t ->
            "| #{t} | Pre-made | Accepted |"
          end)

      write_decisions_index(env, index_content)

      assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
    end
  end
end
