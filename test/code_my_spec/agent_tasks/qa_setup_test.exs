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

  defp create_task(context) do
    task = %{project_id: context.scope.active_project.id, component_id: nil, story_id: nil}
    Map.put(context, :task, task)
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
  # command/2 Tests
  # ============================================================================

  describe "command/2" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with non-empty prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes document spec projection", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ "Required Sections"
      assert prompt =~ "App Overview"
      assert prompt =~ "Tools Registry"
      assert prompt =~ "Seed Strategy"
    end

    test "includes router content when router exists", %{scope: scope, task: task} do
      write_mix_exs(scope.environment)
      write_router(scope.environment)

      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ "PageController"
      assert prompt =~ "DashboardLive"
    end

    test "includes mix phx.routes fallback when router not found", %{
      scope: scope,
      task: task
    } do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ "mix phx.routes"
    end

    test "includes existing plan reference when plan.md exists", %{
      scope: scope,
      task: task
    } do
      write_qa_plan(scope.environment)

      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ ~r/existing plan/i
      assert prompt =~ ~r/patch|update/i
    end

    test "does not include existing plan section when no plan", %{
      scope: scope,
      task: task
    } do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      refute prompt =~ ~r/existing plan/i
    end

    test "points at the qa-tooling playbook for shell-script details", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ "priv/knowledge/qa-tooling"
    end

    test "includes plan output path", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ ".code_my_spec/qa/plan.md"
    end

  end

  # ============================================================================
  # evaluate/2 Tests
  # ============================================================================

  describe "evaluate/2" do
    setup [:create_scope, :create_task]

    test "returns {:ok, :valid} when plan has all required sections", %{
      scope: scope,
      task: task
    } do
      write_qa_plan(scope.environment)

      assert {:ok, :valid} = QaSetup.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when plan.md doesn't exist", %{
      scope: scope,
      task: task
    } do
      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, task)
      assert feedback =~ "QA plan not found"
      assert feedback =~ ".code_my_spec/qa/plan.md"
    end

    test "returns {:ok, :invalid, feedback} when plan is missing required sections", %{
      scope: scope,
      task: task
    } do
      write_qa_plan(scope.environment, """
      # QA Plan

      ## App Overview

      Some overview content.
      """)

      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, task)
      assert feedback =~ "missing required section"
      assert feedback =~ "Tools Registry"
      assert feedback =~ "Seed Strategy"
    end

    test "returns {:ok, :invalid, feedback} when plan is missing one section", %{
      scope: scope,
      task: task
    } do
      write_qa_plan(scope.environment, """
      # QA Plan

      ## App Overview

      Overview here.

      ## Tools Registry

      Tools here.
      """)

      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, task)
      assert feedback =~ "Seed Strategy"
    end

  end
end
