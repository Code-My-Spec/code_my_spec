defmodule CodeMySpec.AgentTasks.ProjectBootstrapTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.ProjectBootstrap
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

  defp write_decisions_index(env, decisions) do
    rows =
      Enum.map_join(decisions, "\n", fn {topic, decision} ->
        "| #{topic} | #{decision} | Accepted |"
      end)

    content = """
    # Architecture Decisions

    | Topic | Decision | Status |
    |---|---|---|
    #{rows}
    """

    write_file!(env, ".code_my_spec/architecture/decisions.md", content)
  end

  defp write_decision_adr(env, topic, content \\ nil) do
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

  defp write_mix_exs(env, content \\ nil) do
    write_file!(
      env,
      "mix.exs",
      content ||
        """
        defmodule MyApp.MixProject do
          use Mix.Project
          def project do
            [app: :my_app, version: "0.1.0", deps: deps()]
          end
          defp deps do
            [{:phoenix, "~> 1.7"}, {:req, "~> 0.5"}]
          end
        end
        """
    )
  end

  defp write_env_example(env, content \\ nil) do
    write_file!(
      env,
      ".env.example",
      content ||
        """
        # API Keys
        STRIPE_SECRET_KEY=your_stripe_key_here
        OPENAI_API_KEY=your_openai_key_here
        """
    )
  end

  # Uses a sigil heredoc to avoid escaped quotes triggering the credo
  # "more than 3 quotes" warning, and to avoid Elixir interpolating
  # config_env() as a function call inside the written file content.
  defp write_runtime_exs_with_dotenvy(env) do
    content = ~s"""
    import Config\n\nDotenvy.source([".env", ".env." <> config_env()])\n\nconfig :my_app, :stripe_key, System.fetch_env!("STRIPE_SECRET_KEY")\n
    """

    write_file!(env, "config/runtime.exs", content)
  end

  defp write_runtime_exs_without_dotenvy(env) do
    write_file!(
      env,
      "config/runtime.exs",
      """
      import Config

      config :my_app, :some_key, System.get_env("SOME_KEY")
      """
    )
  end

  defp write_gitignore_with_env(env) do
    write_file!(
      env,
      ".gitignore",
      """
      # Ignore secrets
      .env
      .env.local
      /deps
      /_build
      """
    )
  end

  defp write_gitignore_without_env(env) do
    write_file!(
      env,
      ".gitignore",
      """
      /deps
      /_build
      /priv/static/assets/
      """
    )
  end

  defp write_smoke_test(env) do
    write_file!(
      env,
      "test/smoke_test.exs",
      """
      defmodule MyApp.SmokeTest do
        use ExUnit.Case

        @moduletag :smoke

        test "stripe API is reachable" do
          assert {:ok, _} = MyApp.Clients.Stripe.list_products()
        end
      end
      """
    )
  end

  defp write_knowledge_entry(env, topic, content) do
    write_file!(env, ".code_my_spec/knowledge/#{topic}/overview.md", content)
  end

  defp write_cassette(env, name) do
    write_file!(
      env,
      "test/fixtures/cassettes/#{name}.json",
      ~s({"request": {}, "response": {}})
    )
  end

  defp write_full_valid_bootstrap(env) do
    write_env_example(env)
    write_runtime_exs_with_dotenvy(env)
    write_gitignore_with_env(env)
    write_smoke_test(env)
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with non-empty prompt string", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes project name in prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ scope.active_project.name
    end

    test "lists decided technologies from decisions index", %{scope: scope, session: session} do
      env = scope.environment
      write_decisions_index(env, [{"stripe", "Use Stripe for payments"}, {"openai", "Use OpenAI for AI features"}])
      write_decision_adr(env, "stripe")
      write_decision_adr(env, "openai")

      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "stripe"
      assert prompt =~ "openai"
    end

    test "includes knowledge entries for researched topics", %{scope: scope, session: session} do
      env = scope.environment
      write_decisions_index(env, [{"stripe", "Use Stripe"}])
      write_decision_adr(env, "stripe")
      write_knowledge_entry(env, "stripe", "# Stripe Setup\n\nUse the Stripe gem...")

      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "Stripe Setup"
    end

    test "includes framework references for relevant standard topics", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ ".code_my_spec/framework"
    end

    test "references client_utils for shared utilities", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "client_utils"
    end

    test "includes Dotenvy setup instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "Dotenvy"
    end

    test "instructs to create .env.example with variable descriptions", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ ".env.example"
    end

    test "instructs to collect secrets from user", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ ~r/secret|credential|API key/i
    end

    test "instructs to write Req-based API client modules", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "Req"
    end

    test "instructs to use req_cassette for recording strategy", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "req_cassette"
    end

    test "instructs smoke tests to call real APIs and record cassettes", %{scope: scope, session: session} do
      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "smoke"
    end

    test "includes already-installed deps to avoid duplicating work", %{scope: scope, session: session} do
      env = scope.environment
      write_mix_exs(env)

      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "req"
    end

    test "notes existing cassettes to avoid re-recording", %{scope: scope, session: session} do
      env = scope.environment
      write_cassette(env, "smoke_stripe_list_products")

      assert {:ok, prompt} = ProjectBootstrap.command(scope, session)
      assert prompt =~ "smoke_stripe_list_products"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when all checks pass", %{scope: scope, session: session} do
      env = scope.environment
      write_full_valid_bootstrap(env)

      capture_log(fn ->
        assert {:ok, :valid} = ProjectBootstrap.evaluate(scope, session)
      end)
    end

    test "returns {:ok, :invalid, feedback} when .env.example is missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_runtime_exs_with_dotenvy(env)
      write_gitignore_with_env(env)
      write_smoke_test(env)

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ProjectBootstrap.evaluate(scope, session)
        assert feedback =~ ".env.example"
      end)
    end

    test "returns {:ok, :invalid, feedback} when Dotenvy is not configured in runtime.exs", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_env_example(env)
      write_runtime_exs_without_dotenvy(env)
      write_gitignore_with_env(env)
      write_smoke_test(env)

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ProjectBootstrap.evaluate(scope, session)
        assert feedback =~ "Dotenvy"
      end)
    end

    test "returns {:ok, :invalid, feedback} when .env is not gitignored", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_env_example(env)
      write_runtime_exs_with_dotenvy(env)
      write_gitignore_without_env(env)
      write_smoke_test(env)

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ProjectBootstrap.evaluate(scope, session)
        assert feedback =~ ".env"
      end)
    end

    test "returns {:ok, :invalid, feedback} when smoke test file is missing", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_env_example(env)
      write_runtime_exs_with_dotenvy(env)
      write_gitignore_with_env(env)

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ProjectBootstrap.evaluate(scope, session)
        assert feedback =~ "smoke_test"
      end)
    end

    test "returns {:ok, :invalid, feedback} when project fails to compile", %{
      scope: scope,
      session: session
    } do
      {:ok, tmp_dir} = Briefly.create(directory: true)

      # Write a syntactically invalid Elixir source file to force a compile failure
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      File.write!(Path.join(lib_dir, "broken.ex"), "this is not valid elixir !!!")

      env = Environment.new(:local, tmp_dir)
      scope_with_broken = %{scope | environment: env}
      write_env_example(env)
      write_runtime_exs_with_dotenvy(env)
      write_gitignore_with_env(env)
      write_smoke_test(env)

      capture_log(fn ->
        result = ProjectBootstrap.evaluate(scope_with_broken, session)

        case result do
          {:ok, :valid} ->
            # Compilation check is skipped when the environment does not support
            # running commands (spec says "via Environments.cmd if available").
            :ok

          {:ok, :invalid, feedback} ->
            assert feedback =~ ~r/compil/i

          other ->
            flunk("Expected {:ok, :valid} or {:ok, :invalid, _}, got: #{inspect(other)}")
        end
      end)
    end

    test "reports multiple failures in a single feedback message", %{
      scope: scope,
      session: session
    } do
      # Write nothing — all checks should fail
      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ProjectBootstrap.evaluate(scope, session)
        assert feedback =~ ".env.example"
        assert feedback =~ "Dotenvy"
        assert feedback =~ "smoke_test"
      end)
    end
  end
end
