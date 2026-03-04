defmodule CodeMySpec.AgentTasks.TechnicalStrategyTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import ExUnit.CaptureLog
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
      ".code_my_spec/architecture/decisions/#{topic}.md",
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
      ".code_my_spec/architecture/decisions.md",
      content ||
        """
        # Architecture Decisions

        | Topic | Decision | Status |
        |---|---|---|
        """
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
    test "returns a non-empty list of decisions" do
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
    end

    test "does not include ngrok as a pre-made decision" do
      topics = premade_topics()
      refute "ngrok" in topics
    end

    test "returns exactly 10 decisions" do
      assert length(TechnicalStrategy.premade_decisions()) == 10
    end
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with non-empty prompt string", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes project name in prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ scope.active_project.name
    end

    test "includes deps context when mix.exs exists", %{scope: scope, session: session} do
      write_mix_exs(scope.environment)

      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "Current Dependencies"
    end

    test "lists existing decisions in prompt", %{scope: scope, session: session} do
      env = scope.environment
      write_existing_decision(env, "wallaby")

      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "wallaby"
    end

    test "instructs to research and write ADRs for identified topics", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ ".code_my_spec/architecture/decisions/"
    end

    test "writes missing pre-made decision ADR files to the environment", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_existing_decision(env, "elixir")
      write_existing_decision(env, "phoenix")

      assert {:ok, _prompt} = TechnicalStrategy.command(scope, session)

      for d <- TechnicalStrategy.premade_decisions() do
        path = Path.join(env.cwd, ".code_my_spec/architecture/decisions/#{d.topic}.md")
        assert File.exists?(path), "Expected ADR file for #{d.topic}"
      end
    end

    test "does not overwrite pre-existing decision files", %{scope: scope, session: session} do
      env = scope.environment
      write_existing_decision(env, "elixir")

      assert {:ok, _prompt} = TechnicalStrategy.command(scope, session)

      elixir_content =
        File.read!(Path.join(env.cwd, ".code_my_spec/architecture/decisions/elixir.md"))

      assert elixir_content =~ "We decided to use elixir"
    end

    test "does not include a Pre-made Decisions to Write section in prompt", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      refute prompt =~ "Pre-made Decisions to Write"
    end

    test "lists pre-made decisions as existing decisions after writing them", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "Existing Decisions"
      assert prompt =~ "elixir"
      assert prompt =~ "phoenix"
      assert prompt =~ "daisyui"
    end

    test "does NOT include knowledge base building steps (handled by ResearchTopics)", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      refute prompt =~ "Build Knowledge Base"
    end

    test "does NOT include bootstrap/library installation steps (handled by ProjectBootstrap)", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      refute prompt =~ "Bootstrap"
      refute prompt =~ "Add libraries"
      refute prompt =~ "Smoke test"
    end

    test "does NOT reference a specific subagent by name", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      refute prompt =~ ~r/@"CodeMySpec:/
    end

    test "instructs to update the decisions index", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ ".code_my_spec/architecture/decisions.md"
    end

    test "instructs to stop after completing the work", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      assert prompt =~ "Stop"
    end

    test "omits architecture section when project has no components", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      refute prompt =~ "Architecture Overview"
    end

    test "omits deps section when mix.exs is absent", %{scope: scope, session: session} do
      assert {:ok, prompt} = TechnicalStrategy.command(scope, session)
      refute prompt =~ "Current Dependencies"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when all pre-made decisions and index exist", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_all_premade_decisions(env)
      write_decisions_index(env)

      capture_log(fn ->
        assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
      end)
    end

    test "returns {:ok, :invalid, feedback} when pre-made decisions are missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decisions_index(env)

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
        assert feedback =~ "Pre-made decision"
      end)
    end

    test "feedback names the missing pre-made topic", %{scope: scope, session: session} do
      env = scope.environment
      write_decisions_index(env)

      for d <- TechnicalStrategy.premade_decisions(), d.topic != "elixir" do
        write_existing_decision(env, d.topic)
      end

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
        assert feedback =~ "elixir"
      end)
    end

    test "returns {:ok, :invalid, feedback} when decisions index is missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_all_premade_decisions(env)

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
        assert feedback =~ "index"
      end)
    end

    test "feedback references the expected index path when index is missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_all_premade_decisions(env)

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
        assert feedback =~ ".code_my_spec/architecture/decisions.md"
      end)
    end

    test "returns {:ok, :invalid, feedback} when both index and pre-made decisions are missing",
         %{scope: scope, session: session} do
      capture_log(fn ->
        assert {:ok, :invalid, feedback} = TechnicalStrategy.evaluate(scope, session)
        assert feedback =~ "index"
        assert feedback =~ "Pre-made decision"
      end)
    end

    test "does NOT check for knowledge entries (handled by ResearchTopics)", %{scope: scope, session: session} do
      env = scope.environment
      write_all_premade_decisions(env)
      write_existing_decision(env, "wallaby")
      write_decisions_index(env)

      capture_log(fn ->
        assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
      end)
    end

    test "does NOT check for research prompt files", %{scope: scope, session: session} do
      env = scope.environment
      write_all_premade_decisions(env)
      write_decisions_index(env)

      write_file!(
        env,
        ".code_my_spec/status/research/wallaby.md",
        "Research wallaby for the project."
      )

      capture_log(fn ->
        assert {:ok, :valid} = TechnicalStrategy.evaluate(scope, session)
      end)
    end
  end
end
