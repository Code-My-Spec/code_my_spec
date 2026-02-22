defmodule CodeMySpec.AgentTasks.QaAppTest do
  @moduledoc false
  use CodeMySpec.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaApp
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

  defp write_qa_report(env, content) do
    write_file!(env, "docs/qa/report.md", content)
  end

  defp write_issue(env, name, content \\ nil) do
    write_file!(
      env,
      "docs/issues/#{name}.md",
      content || "# #{name}\n\nDescription of the issue."
    )
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes project name", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ scope.active_project.name
    end

    test "includes router content when router exists", %{scope: scope, session: session} do
      write_mix_exs(scope.environment)
      write_router(scope.environment)

      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "PageController"
      assert prompt =~ "DashboardLive"
    end

    test "handles missing router gracefully", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "mix phx.routes"
    end

    test "includes server startup instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "lsof -i :4000"
      assert prompt =~ "mix phx.server"
    end

    test "includes web tool instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "web http://localhost:4000"
      assert prompt =~ "--profile qa"
    end

    test "includes issue filing instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "docs/issues/"
    end

    test "includes QA report instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "docs/qa/report.md"
    end

    test "lists existing issues to avoid duplicates", %{scope: scope, session: session} do
      write_issue(scope.environment, "login-form-broken")

      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "login-form-broken"
    end

    test "includes BDD coverage section", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "BDD Spec Coverage"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when report exists and references a story", %{
      scope: scope,
      session: session
    } do
      # Get a real story title from the fixture
      story_titles =
        CodeMySpec.Stories.list_story_titles(scope)
        |> Enum.map(& &1.title)

      # Write report that references one of the fixture story titles
      report_content =
        if Enum.empty?(story_titles) do
          # If no stories, any report will pass (story check is skipped)
          "# QA Report\n\nAll routes tested."
        else
          "# QA Report\n\nTested: #{hd(story_titles)}\n\nAll routes passed."
        end

      write_qa_report(scope.environment, report_content)

      assert {:ok, :valid} = QaApp.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when report is missing", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, session)
      assert feedback =~ "report"
    end

    test "returns {:ok, :invalid, feedback} when report is empty", %{
      scope: scope,
      session: session
    } do
      write_qa_report(scope.environment, "")

      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, session)
      assert feedback =~ "empty"
    end

    test "returns {:ok, :invalid, feedback} when report does not reference any story", %{
      scope: scope,
      session: session
    } do
      # Check if there are stories to test against
      story_titles =
        CodeMySpec.Stories.list_story_titles(scope)
        |> Enum.map(& &1.title)

      if Enum.empty?(story_titles) do
        # No stories — report without references is valid
        write_qa_report(scope.environment, "# QA Report\n\nNo stories to test.")
        assert {:ok, :valid} = QaApp.evaluate(scope, session)
      else
        # Stories exist — report must reference at least one
        write_qa_report(scope.environment, "# QA Report\n\nSome completely unrelated content.")
        assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, session)
        assert feedback =~ "story"
      end
    end
  end
end
