defmodule CodeMySpec.AgentTasks.QaSetupTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaSetup
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
    session = %{project: context.scope.active_project}
    Map.put(context, :session, session)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_router(env, app_name \\ "my_app") do
    write_file!(env, "lib/#{app_name}_web/router.ex", """
    defmodule #{Macro.camelize(app_name)}Web.Router do
      use #{Macro.camelize(app_name)}Web, :router

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
      end

      pipeline :require_authenticated_user do
        plug :fetch_current_user
        plug :require_authenticated_user
      end

      scope "/", #{Macro.camelize(app_name)}Web do
        pipe_through :browser

        get "/", PageController, :home
        live "/dashboard", DashboardLive
        live "/settings", SettingsLive
      end
    end
    """)
  end

  defp write_mix_exs(env, app_name \\ "my_app") do
    write_file!(env, "mix.exs", """
    defmodule #{Macro.camelize(app_name)}.MixProject do
      use Mix.Project
      def project do
        [app: :#{app_name}, version: "0.1.0", deps: deps()]
      end
      defp deps do
        [{:phoenix, "~> 1.7"}, {:phoenix_live_view, "~> 1.0"}]
      end
    end
    """)
  end

  defp write_qa_plan(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/plan.md",
      content ||
        """
        # QA Plan

        ## App Overview

        Phoenix app with session-based auth on port 4000.

        ## Tools Registry

        ### web tool
        Use for LiveView pages.

        ### curl
        Use for API endpoints.

        ## Seed Strategy

        - `mix run -e "MyApp.Seeds.run()"`
        """
    )
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with non-empty prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaSetup.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes document spec projection", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaSetup.command(scope, session)
      assert prompt =~ "Required Sections"
      assert prompt =~ "App Overview"
      assert prompt =~ "Tools Registry"
      assert prompt =~ "Seed Strategy"
    end

    test "includes router content when router exists", %{scope: scope, session: session} do
      write_mix_exs(scope.environment)
      write_router(scope.environment)

      assert {:ok, prompt} = QaSetup.command(scope, session)
      assert prompt =~ "PageController"
      assert prompt =~ "DashboardLive"
    end

    test "includes mix phx.routes fallback when router not found", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = QaSetup.command(scope, session)
      assert prompt =~ "mix phx.routes"
    end

    test "includes existing plan reference when plan.md exists", %{
      scope: scope,
      session: session
    } do
      write_qa_plan(scope.environment)

      assert {:ok, prompt} = QaSetup.command(scope, session)
      assert prompt =~ "Existing Plan"
      assert prompt =~ "update rather than"
    end

    test "does not include existing plan section when no plan", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = QaSetup.command(scope, session)
      refute prompt =~ "Existing Plan"
    end

    test "includes shell scripts instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaSetup.command(scope, session)
      assert prompt =~ "qa/scripts"
      assert prompt =~ "authenticated_curl"
    end

    test "includes plan output path", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaSetup.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/plan.md"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when plan has all required sections", %{
      scope: scope,
      session: session
    } do
      write_qa_plan(scope.environment)

      assert {:ok, :valid} = QaSetup.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when plan.md doesn't exist", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, session)
      assert feedback =~ "QA plan not found"
      assert feedback =~ ".code_my_spec/qa/plan.md"
    end

    test "returns {:ok, :invalid, feedback} when plan is missing required sections", %{
      scope: scope,
      session: session
    } do
      write_qa_plan(scope.environment, """
      # QA Plan

      ## App Overview

      Some overview content.
      """)

      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, session)
      assert feedback =~ "missing required section"
      assert feedback =~ "Tools Registry"
      assert feedback =~ "Seed Strategy"
    end

    test "returns {:ok, :invalid, feedback} when plan is missing one section", %{
      scope: scope,
      session: session
    } do
      write_qa_plan(scope.environment, """
      # QA Plan

      ## App Overview

      Overview here.

      ## Tools Registry

      Tools here.
      """)

      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, session)
      assert feedback =~ "Seed Strategy"
    end
  end
end
