defmodule CodeMySpec.AgentTasks.QaAppTest do
  @moduledoc false
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaApp
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Issues.IssuesRepository

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

  defp create_story(context) do
    story =
      story_fixture(context.scope, %{
        title: "User Authentication",
        description: "Users can log in and out of the application"
      })

    %{story: story}
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

  defp write_qa_plan(env) do
    write_file!(env, ".code_my_spec/qa/plan.md", """
    # QA Plan

    ## App Overview

    Phoenix app with session-based auth on port 4000.

    ## Tools Registry

    ### web tool
    Use for LiveView pages.

    ## Seed Strategy

    - `mix run priv/repo/qa_seeds.exs`
    """)

    write_file!(env, ".code_my_spec/qa/scripts/start-qa.sh", """
    #!/bin/bash
    mix run priv/repo/qa_seeds.exs
    echo "QA setup complete"
    """)
  end

  defp write_qa_summary(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/summary.md",
      content || "# QA Summary\n\nAll stories tested. No critical issues."
    )
  end

  defp write_story_brief(env, story_id, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/#{story_id}/brief.md",
      content ||
        """
        # QA Brief: Story #{story_id}

        ## Tool

        web

        ## Auth

        Login as admin@example.com / password123

        ## Seeds

        mix run priv/repo/qa_seeds.exs

        ## What To Test

        - Visit /users/log_in
        - Enter credentials
        - Verify redirect to dashboard

        ## Result Path

        .code_my_spec/qa/#{story_id}/result.md
        """
    )
  end

  defp write_story_result(env, story_id, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/#{story_id}/result.md",
      content ||
        """
        # QA Result: Story #{story_id}

        ## Status

        pass

        ## Scenarios

        ### Login flow
        - Visited /users/log_in
        - Entered credentials
        - Redirected to dashboard
        - **Pass**

        ## Evidence

        - `.code_my_spec/qa/#{story_id}/screenshots/login.png` — login page

        ## Issues

        None
        """
    )
  end

  # ============================================================================
  # command/2 Tests
  # ============================================================================

  describe "command/2" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaApp.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes project name", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ scope.active_project.name
    end

    test "includes router content when router exists", %{scope: scope, task: task} do
      write_mix_exs(scope.environment)
      write_router(scope.environment)

      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ "PageController"
      assert prompt =~ "DashboardLive"
    end

    test "handles missing router gracefully", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ "mix phx.routes"
    end

    test "includes server startup instructions", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ "mix phx.server"
    end

    test "instructs agent to dispatch qa subagent", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ "qa (agent)"
    end

    test "instructs agent to write summary", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ ".code_my_spec/qa/summary.md"
    end

    test "lists existing issues to avoid duplicates", %{scope: scope, task: task} do
      IssuesRepository.create_issue(scope, %{
        title: "login-form-broken",
        severity: :high,
        description: "Login form is broken",
        status: :incoming
      })

      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ "login-form-broken"
    end

    test "includes BDD coverage section", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaApp.command(scope, task)
      assert prompt =~ "BDD Spec Coverage"
    end

    test "generates per-story prompt files", %{scope: scope} do
      %{story: story} = create_story(%{scope: scope})
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: nil}

      assert {:ok, _prompt} = QaApp.command(scope, task)

      # Prompt file should be written for the story
      prompt_path = Path.join(scope.environment.cwd, ".code_my_spec/qa/#{story.id}/prompt.md")
      assert File.exists?(prompt_path)

      content = File.read!(prompt_path)
      assert content =~ "User Authentication"
    end

    test "includes prompt file paths in orchestration prompt", %{scope: scope} do
      %{story: story} = create_story(%{scope: scope})
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: nil}

      assert {:ok, prompt} = QaApp.command(scope, task)

      assert prompt =~ ".code_my_spec/qa/#{story.id}/prompt.md"
    end
  end

  # ============================================================================
  # evaluate/2 Tests
  # ============================================================================

  describe "evaluate/2" do
    setup [:create_scope, :create_task]

    test "returns {:ok, :valid} when no stories and summary exists", %{
      scope: scope,
      task: task
    } do
      write_qa_summary(scope.environment)

      assert {:ok, :valid} = QaApp.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when summary is missing", %{
      scope: scope,
      task: task
    } do
      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, task)
      assert feedback =~ "summary"
    end

    test "delegates story validation to QaStory.evaluate", %{scope: scope} do
      %{story: story} = create_story(%{scope: scope})
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: nil}
      write_qa_plan(scope.environment)

      # No brief or result — QaStory.evaluate should report brief missing
      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, task)
      assert feedback =~ "Story #{story.id}"
      assert feedback =~ "Brief"
    end

    test "returns invalid demanding submit_qa_result when stories have file artifacts but no DB attempts", %{scope: scope} do
      # Per issue 3dd4ec46: file-based artifacts alone don't satisfy
      # qa_complete. submit_qa_result lands the DB attempt that the
      # requirement graph reads. QaApp delegates to QaStory.evaluate;
      # without a DB attempt, QaStory returns invalid + submit demand,
      # and QaApp aggregates that into its own invalid response.
      %{story: story} = create_story(%{scope: scope})
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: nil}

      write_qa_plan(scope.environment)
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)
      write_qa_summary(scope.environment)

      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, task)
      assert feedback =~ "submit_qa_result"
    end

    test "returns invalid demanding submit_qa_result when story has brief but no result and no DB attempt", %{scope: scope} do
      %{story: story} = create_story(%{scope: scope})
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: nil}

      write_qa_plan(scope.environment)
      write_story_brief(scope.environment, story.id)
      write_qa_summary(scope.environment)

      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, task)
      assert feedback =~ "submit_qa_result"
    end

    test "returns invalid when stories pass but summary missing", %{scope: scope} do
      %{story: story} = create_story(%{scope: scope})
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: nil}

      write_qa_plan(scope.environment)
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)

      assert {:ok, :invalid, feedback} = QaApp.evaluate(scope, task)
      assert feedback =~ "summary"
    end
  end
end
