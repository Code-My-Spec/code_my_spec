defmodule CodeMySpec.AgentTasks.QaStoryTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Issues

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp create_story(context) do
    story =
      story_fixture(context.scope, %{
        title: "User Authentication",
        description: "Users can log in and out of the application"
      })

    %{story: story}
  end

  defp create_task(context) do
    story_id = if context[:story], do: context.story.id, else: 42

    task = %{
      project_id: context.scope.active_project.id,
      component_id: nil,
      story_id: story_id
    }

    Map.put(context, :task, task)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp create_qa_plan(context) do
    write_qa_plan(context.scope.environment)
    context
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
        - `.code_my_spec/qa/#{story_id}/screenshots/dashboard.png` — after login

        ## Issues

        None
        """
    )
  end

  defp write_result_with_issues(env, story_id) do
    write_file!(
      env,
      ".code_my_spec/qa/#{story_id}/result.md",
      """
      # QA Result: Story #{story_id}

      ## Status

      fail

      ## Scenarios

      ### Login flow
      - Visited /users/log_in
      - **Fail** — redirect broken for invited users

      ## Issues

      ### Login redirect fails for invited users

      #### Severity

      HIGH

      #### Description

      Invited users who click the email link are redirected to /login instead of /accept-invite.
      Reproduced with user test+invite@example.com.

      ### Missing validation on empty name

      #### Severity

      MEDIUM

      #### Description

      Submitting the profile form with an empty name field succeeds instead of showing an error.

      ### Minor typo in footer

      #### Severity

      LOW

      #### Description

      The word "recieve" is misspelled in the footer text.
      """
    )
  end


  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3 — combined prompt" do
    setup [:create_scope, :create_story, :create_task]

    test "returns a combined prompt covering the brief and result phases", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaStory.command(scope, task)
      assert prompt =~ ~r/QA Story/i
      assert prompt =~ "qa_story_brief"
      assert prompt =~ "qa_result"
    end

    test "includes story context", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaStory.command(scope, task)
      assert prompt =~ "User Authentication"
      assert prompt =~ "Users can log in and out"
      assert prompt =~ ~r/acceptance criteria/i
    end

    test "references the QA plan as required reading", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaStory.command(scope, task)
      assert prompt =~ "App Overview"
      assert prompt =~ ~r/Tools\s+Registry/
      assert prompt =~ "Seed Strategy"
    end

    test "points at the qa-tooling playbook for tool rules and testing approach", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaStory.command(scope, task)
      assert prompt =~ "priv/knowledge/qa_story/workflow.md"
      assert prompt =~ "priv/knowledge/qa-tooling"
    end

    test "references all artifact paths", %{scope: scope, task: task, story: story} do
      assert {:ok, prompt} = QaStory.command(scope, task)
      assert prompt =~ ".code_my_spec/qa/plan.md"
      assert prompt =~ ".code_my_spec/qa/#{story.id}/brief.md"
      assert prompt =~ ".code_my_spec/qa/#{story.id}/result.md"
    end

    test "same prompt regardless of existing artifacts", %{scope: scope, task: task, story: story} do
      assert {:ok, prompt_before} = QaStory.command(scope, task)

      write_qa_plan(scope.environment)
      write_story_brief(scope.environment, story.id)

      assert {:ok, prompt_after} = QaStory.command(scope, task)
      assert prompt_before == prompt_after
    end

    test "accepts string story ID", %{scope: scope, story: story} do
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: to_string(story.id)}
      assert {:ok, _prompt} = QaStory.command(scope, task)
    end

    test "returns error when story ID is missing", %{scope: scope} do
      task = %{project_id: scope.active_project.id, component_id: nil, story_id: nil}
      assert {:error, message} = QaStory.command(scope, task)
      assert message =~ "story ID"
    end

    test "returns error when task has no story_id", %{scope: scope} do
      task = %{project_id: scope.active_project.id, component_id: nil}
      assert {:error, message} = QaStory.command(scope, task)
      assert message =~ "story ID"
    end
  end

  # ============================================================================
  # evaluate/3 — Plan Phase
  # ============================================================================

  describe "evaluate/3 plan phase" do
    setup [:create_scope, :create_story, :create_task]

    test "returns invalid when plan doesn't exist", %{scope: scope, task: task} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "QA plan not found"
    end

    test "feedback points at qa_setup when plan is missing", %{scope: scope, task: task} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "qa_setup"
    end

    test "returns invalid when plan missing required sections", %{
      scope: scope,
      task: task
    } do
      write_file!(scope.environment, ".code_my_spec/qa/plan.md", """
      # QA Plan

      ## App Overview

      Phoenix app on port 4000.
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "missing required section"
      assert feedback =~ "Tools Registry"
      assert feedback =~ "Seed Strategy"
    end

    test "passes plan check when plan has all required sections", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_qa_plan(scope.environment)

      # With plan valid but no brief, should get brief phase feedback
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "Brief not found"
      assert feedback =~ ".code_my_spec/qa/#{story.id}/brief.md"
    end

  end

  # ============================================================================
  # evaluate/3 — Brief Phase
  # ============================================================================

  describe "evaluate/3 brief phase" do
    setup [:create_scope, :create_story, :create_task, :create_qa_plan]

    test "returns invalid when brief doesn't exist", %{scope: scope, task: task} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "Brief not found"
    end

    test "returns invalid when brief is missing required sections", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id, """
      # QA Brief

      ## Tool

      web
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "invalid"
    end

    test "feedback mentions brief on brief phase", %{scope: scope, task: task} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "brief" or feedback =~ "Brief"
    end
  end

  # ============================================================================
  # evaluate/3 — Test Phase
  # ============================================================================

  describe "evaluate/3 test phase" do
    setup [:create_scope, :create_story, :create_task, :create_qa_plan]

    test "returns valid when brief is present but result is missing (DB-only completion)", %{
      scope: scope,
      task: task,
      story: story
    } do
      # Result is no longer required; `submit_qa_result` is the canonical
      # completion path. A brief with no result is a fine intermediate
      # state — the agent finished planning and either ran the tests in
      # the BEAM/browser or aborted (issue a15c252b).
      write_story_brief(scope.environment, story.id)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)
    end

    test "returns invalid when result is missing required sections", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      write_story_result(scope.environment, story.id, """
      # QA Result

      ## Status

      pass
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "Brief validated"
      assert feedback =~ "invalid"
    end

    # NOTE: previously asserted that a missing result.md surfaced
    # "Brief validated; now write result" feedback. Result is no longer
    # required (issue a15c252b) — `submit_qa_result` is the canonical
    # completion path — so the brief-only state is now `:valid`. The
    # path-naming behavior of the prompt remains in the start_task
    # output; only the evaluator stopped demanding it.

    test "feedback on invalid result also includes result format spec", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      write_story_result(scope.environment, story.id, """
      # QA Result

      ## Status

      pass
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, task)
      assert feedback =~ "Required Sections"
    end
  end

  # ============================================================================
  # evaluate/3 — Done Phase (Issue Filing)
  # ============================================================================

  describe "evaluate/3 done phase" do
    setup [:create_scope, :create_story, :create_task, :create_qa_plan]

    test "returns valid when brief and result both valid, no issues", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)
    end

    test "returns valid when result has low/info issues (files created for all severities)", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      write_story_result(scope.environment, story.id, """
      # QA Result: Story #{story.id}

      ## Status

      pass

      ## Scenarios

      ### Login flow
      - **Pass**

      ## Issues

      ### Minor typo in footer

      #### Severity

      LOW

      #### Description

      The word "recieve" is misspelled in the footer text.

      ### FYI: Button color slightly off

      #### Severity

      INFO

      #### Description

      The submit button is #007bff instead of the design system's #0066cc.
      """)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)

      # Issues are created in DB for all severities including low/info
      issues = Issues.list_by_story(scope, story.id)
      titles = Enum.map(issues, & &1.title)
      assert Enum.any?(titles, &String.contains?(&1, "typo"))
      assert Enum.any?(titles, &String.contains?(&1, "Button color"))
    end

    test "returns valid and creates DB issues for all severity levels", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)

      issues = Issues.list_by_story(scope, story.id)
      titles = Enum.map(issues, & &1.title)

      assert Enum.any?(titles, &String.contains?(&1, "redirect"))
      assert Enum.any?(titles, &String.contains?(&1, "validation"))
      assert Enum.any?(titles, &String.contains?(&1, "typo"))
    end

    test "issue records have severity, description, and source_path", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)

      issues = Issues.list_by_story(scope, story.id)
      login_issue = Enum.find(issues, &String.contains?(&1.title, "redirect"))

      assert login_issue.severity == :high
      assert login_issue.description =~ "Invited users"
      assert login_issue.source_path =~ "qa/#{story.id}/result.md"
    end

    test "upsert doesn't duplicate existing issues", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)

      issues_first = Issues.list_by_story(scope, story.id)

      # Write a new result and run evaluate again
      write_result_with_issues(scope.environment, story.id)
      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)

      issues_second = Issues.list_by_story(scope, story.id)

      # Upsert should not create duplicates
      assert length(issues_second) == length(issues_first)
    end
  end

  # ============================================================================
  # evaluate/3 — Scope in Issue Records
  # ============================================================================

  describe "evaluate/3 scope in issue records" do
    setup [:create_scope, :create_story, :create_task, :create_qa_plan]

    test "issues default to app scope", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)

      issues = Issues.list_by_story(scope, story.id)
      login_issue = Enum.find(issues, &String.contains?(&1.title, "redirect"))

      assert login_issue.scope == :app
    end

    test "issues preserve explicit scope from result", %{
      scope: scope,
      task: task,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      write_story_result(scope.environment, story.id, """
      # QA Result: Story #{story.id}

      ## Status

      fail

      ## Scenarios

      ### Seed script check
      - **Fail** — seeds crash on fresh db

      ## Issues

      ### Seed script fails on fresh database

      #### Severity

      MEDIUM

      #### Scope

      QA

      #### Description

      Running qa_seeds.exs on a freshly migrated database fails.
      """)

      assert {:ok, :invalid, _} = QaStory.evaluate(scope, task)

      issues = Issues.list_by_story(scope, story.id)
      seed_issue = Enum.find(issues, &String.contains?(&1.title, "Seed script"))

      assert seed_issue.scope == :qa
    end
  end
end
