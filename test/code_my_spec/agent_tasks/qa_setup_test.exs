defmodule CodeMySpec.AgentTasks.QaSetupTest do
  @moduledoc false
  use CodeMySpecTest.DataCase, async: true

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

  # `evaluate/2` reads the synced record, not the file — the plan is parsed
  # during the scan, on the machine that holds it, so a server with no working
  # copy can still tell whether it is valid. Syncing here means these tests
  # exercise the classifier and the validator too, not just the checker.
  defp sync!(scope) do
    {:ok, _} = CodeMySpec.Files.FileSync.sync(scope, base_dir: scope.environment.cwd)
    :ok
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
      assert prompt =~ "qa-tooling"
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
      sync!(scope)

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

      sync!(scope)

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

      sync!(scope)

      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, task)
      assert feedback =~ "Seed Strategy"
    end
  end

  describe "the journey plan shares the role but not the schema" do
    setup [:create_scope, :create_task]

    test "a valid journey plan is not marked invalid by the qa_plan spec", %{scope: scope} do
      write_file!(scope.environment, ".code_my_spec/qa/journey_plan.md", """
      # QA Journey Plan

      ## Journeys

      ### Capture a task
      1. Log in
      2. Type a task
      3. See it listed
      """)

      sync!(scope)

      record = CodeMySpec.Files.get_by_path(scope, CodeMySpec.Paths.qa_journey_plan())

      assert record, "journey_plan.md must classify and sync"

      error = record.validation_errors["errors"]["plan"]

      # `qa_plan` requires App Overview / Tools Registry / Seed Strategy. If the
      # journey plan is being judged by that schema, the complaint names them.
      if error do
        refute error =~ "tools registry",
               "the journey plan is being validated against the qa_plan schema, " <>
                 "which tells an agent to fix a file that is already correct"

        refute error =~ "seed strategy"
      end
    end
  end
end
