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

  defp write_qa_summary(env, content \\ nil) do
    write_file!(
      env,
      "docs/qa/summary.md",
      content || "# QA Summary\n\nAll stories tested. No critical issues."
    )
  end

  defp write_qa_brief(env, story_slug, content \\ nil) do
    write_file!(
      env,
      "docs/status/qa/#{story_slug}.md",
      content || "Test story #{story_slug}."
    )
  end

  defp write_qa_result(env, story_slug, content \\ nil) do
    write_file!(
      env,
      "docs/qa/#{story_slug}.md",
      content || "# QA: #{story_slug}\n\nAll tests passed."
    )
  end

  defp write_issue(env, name, content \\ nil) do
    write_file!(
      env,
      "docs/issues/#{name}.md",
      content || "# #{name}\n\nDescription of the issue."
    )
  end

  # ============================================================================
  # story_slug/1 Tests
  # ============================================================================

  describe "story_slug/1" do
    test "generates slug from story id and title" do
      story = %{id: 42, title: "User Authentication"}
      assert QaApp.story_slug(story) == "42-user-authentication"
    end

    test "handles special characters" do
      story = %{id: 7, title: "Add OAuth2.0 (Google) Login!"}
      slug = QaApp.story_slug(story)
      assert slug == "7-add-oauth20-google-login"
    end

    test "collapses multiple spaces/dashes" do
      story = %{id: 1, title: "Some   Spaced   Title"}
      assert QaApp.story_slug(story) == "1-some-spaced-title"
    end
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

    test "instructs agent to write per-story QA briefs", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "docs/status/qa/"
    end

    test "instructs agent to dispatch qa-story subagent", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "qa-story"
    end

    test "instructs agent to write summary", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaApp.command(scope, session)
      assert prompt =~ "docs/qa/summary.md"
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

    test "returns {:ok, :valid} when no briefs remain and summary exists", %{
      scope: scope,
      session: session
    } do
      write_qa_summary(scope.environment)

      assert {:ok, :valid} = QaApp.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when briefs exist but story is incomplete", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_qa_brief(env, "42-user-auth")
      write_qa_summary(env)

      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, session)
      assert feedback =~ "42-user-auth"
    end

    test "returns {:ok, :valid} when all story briefs pass validation", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_qa_brief(env, "42-user-auth")
      write_qa_result(env, "42-user-auth")
      write_qa_summary(env)

      assert {:ok, :valid} = QaApp.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when summary is missing", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, session)
      assert feedback =~ "summary"
    end

    test "reports multiple incomplete stories", %{scope: scope, session: session} do
      env = scope.environment
      write_qa_brief(env, "42-user-auth")
      write_qa_brief(env, "43-dashboard")
      write_qa_summary(env)

      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, session)
      assert feedback =~ "42-user-auth"
      assert feedback =~ "43-dashboard"
    end

    test "cleans up brief files when story QA passes", %{scope: scope, session: session} do
      env = scope.environment
      write_qa_brief(env, "42-user-auth")
      write_qa_result(env, "42-user-auth")
      write_qa_summary(env)

      brief_path = Path.join(env.cwd, "docs/status/qa/42-user-auth.md")
      assert File.exists?(brief_path)

      assert {:ok, :valid} = QaApp.evaluate(scope, session)
      refute File.exists?(brief_path)
    end
  end
end
