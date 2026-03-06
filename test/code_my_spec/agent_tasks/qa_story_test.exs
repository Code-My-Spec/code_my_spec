defmodule CodeMySpec.AgentTasks.QaStoryTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaStory
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

  defp create_story(context) do
    story =
      story_fixture(context.scope, %{
        title: "User Authentication",
        description: "Users can log in and out of the application"
      })

    %{story: story}
  end

  defp create_session(context) do
    story_id = if context[:story], do: context.story.id, else: 42

    session = %{
      project: context.scope.active_project,
      state: %{"topic" => story_id}
    }

    Map.put(context, :session, session)
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

  defp issues_dir(env) do
    Path.join(env.cwd, ".code_my_spec/issues/incoming")
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3 — plan phase (no plan.md)" do
    setup [:create_scope, :create_story, :create_session]

    test "returns plan-phase prompt when no plan exists", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Write the QA Plan"
      assert prompt =~ "qa_seeds"
    end

    test "plan prompt includes story context", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "User Authentication"
      assert prompt =~ "Acceptance Criteria"
    end

    test "plan prompt includes plan format spec", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "QA Plan Format"
      assert prompt =~ "App Overview"
      assert prompt =~ "Tools Registry"
    end

    test "plan prompt does not include brief or test content", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      refute prompt =~ "Brief Format"
      refute prompt =~ "Result Format"
      refute prompt =~ "Testing Approach"
    end

    test "plan prompt includes task marker", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "<!-- cms:task type=\"QaStory\""
    end

  end

  describe "command/3 — brief phase (plan exists)" do
    setup [:create_scope, :create_story, :create_session, :create_qa_plan]

    test "returns brief-phase prompt when plan exists", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Write the Brief"
    end

    test "brief prompt includes story context", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "User Authentication"
      assert prompt =~ "Users can log in and out"
      assert prompt =~ "Acceptance Criteria"
    end

    test "brief prompt lists available tools", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "MCP browser tools"
      assert prompt =~ "curl"
    end

    test "brief prompt includes brief format spec", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Brief Format"
      refute prompt =~ "Result Format"
    end

    test "brief prompt references plan.md", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/plan.md"
    end

    test "brief prompt references brief output path", %{scope: scope, session: session, story: story} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/#{story.id}/brief.md"
    end

    test "brief prompt tells agent to stop after brief", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Stop the session after writing the brief"
    end

    test "brief prompt does not include test-phase content", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      refute prompt =~ "Testing Approach"
      refute prompt =~ "Result Format"
    end

  end

  describe "command/3 — test phase (plan + brief exist)" do
    setup [:create_scope, :create_story, :create_session, :create_qa_plan]

    setup %{scope: scope, story: story} do
      write_story_brief(scope.environment, story.id)
      :ok
    end

    test "returns test-phase prompt when brief exists", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Execute Tests"
    end

    test "test prompt includes tool rules and testing approach", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "MCP browser tools"
      assert prompt =~ "Testing Approach"
      assert prompt =~ "screenshot"
    end

    test "test prompt includes result format spec", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Result Format"
      refute prompt =~ "Brief Format"
    end

    test "test prompt references brief path", %{scope: scope, session: session, story: story} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/#{story.id}/brief.md"
    end

  end

  describe "command/3 — shared" do
    setup [:create_scope, :create_story, :create_session]

    test "accepts string story ID", %{scope: scope, story: story} do
      session = %{project: scope.active_project, state: %{"topic" => to_string(story.id)}}
      assert {:ok, _prompt} = QaStory.command(scope, session)
    end

    test "returns error when story ID is missing", %{scope: scope} do
      session = %{project: scope.active_project, state: %{"topic" => nil}}
      assert {:error, message} = QaStory.command(scope, session)
      assert message =~ "story ID"
    end

    test "returns error when session has no topic", %{scope: scope} do
      session = %{project: scope.active_project, state: %{}}
      assert {:error, message} = QaStory.command(scope, session)
      assert message =~ "story ID"
    end
  end

  # ============================================================================
  # evaluate/3 — Plan Phase
  # ============================================================================

  describe "evaluate/3 plan phase" do
    setup [:create_scope, :create_story, :create_session]

    test "returns invalid when plan doesn't exist", %{scope: scope, session: session} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "QA plan not found"
    end

    test "feedback includes doc spec sections", %{scope: scope, session: session} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Required Sections"
      assert feedback =~ "App Overview"
      assert feedback =~ "Tools Registry"
      assert feedback =~ "Seed Strategy"
    end

    test "returns invalid when plan missing required sections", %{
      scope: scope,
      session: session
    } do
      write_file!(scope.environment, ".code_my_spec/qa/plan.md", """
      # QA Plan

      ## App Overview

      Phoenix app on port 4000.
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "missing required section"
      assert feedback =~ "Tools Registry"
      assert feedback =~ "Seed Strategy"
    end

    test "passes plan check when plan has all required sections", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_qa_plan(scope.environment)

      # With plan valid but no brief, should get brief phase feedback
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Brief not found"
      assert feedback =~ ".code_my_spec/qa/#{story.id}/brief.md"
    end

  end

  # ============================================================================
  # evaluate/3 — Brief Phase
  # ============================================================================

  describe "evaluate/3 brief phase" do
    setup [:create_scope, :create_story, :create_session, :create_qa_plan]

    test "returns invalid when brief doesn't exist", %{scope: scope, session: session} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Brief not found"
    end

    test "returns invalid when brief is missing required sections", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id, """
      # QA Brief

      ## Tool

      web
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "invalid"
    end

    test "feedback mentions brief on brief phase", %{scope: scope, session: session} do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "brief" or feedback =~ "Brief"
    end
  end

  # ============================================================================
  # evaluate/3 — Test Phase
  # ============================================================================

  describe "evaluate/3 test phase" do
    setup [:create_scope, :create_story, :create_session, :create_qa_plan]

    test "returns invalid when brief is valid but result doesn't exist", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Brief validated"
      assert feedback =~ "result"
    end

    test "returns invalid when result is missing required sections", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      write_story_result(scope.environment, story.id, """
      # QA Result

      ## Status

      pass
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Brief validated"
      assert feedback =~ "invalid"
    end

    test "feedback includes result format spec", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Required Sections"
      assert feedback =~ "Status"
      assert feedback =~ "Scenarios"
    end

    test "feedback on invalid result also includes result format spec", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)

      write_story_result(scope.environment, story.id, """
      # QA Result

      ## Status

      pass
      """)

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Required Sections"
    end
  end

  # ============================================================================
  # evaluate/3 — Done Phase (Issue Filing)
  # ============================================================================

  describe "evaluate/3 done phase" do
    setup [:create_scope, :create_story, :create_session, :create_qa_plan]

    test "returns valid when brief and result both valid, no issues", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)
    end

    test "returns valid when result has low/info issues (files created for all severities)", %{
      scope: scope,
      session: session,
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

      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      # Issue files are created for all severities including low/info
      dir = issues_dir(scope.environment)
      assert File.exists?(dir)
      files = File.ls!(dir)
      assert Enum.any?(files, &String.contains?(&1, "minor_typo"))
      assert Enum.any?(files, &String.contains?(&1, "fyi_button_color"))
    end

    test "returns valid and creates files for all severity issues", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      # Should create files for all severities
      dir = issues_dir(scope.environment)
      assert File.exists?(dir)
      files = File.ls!(dir)

      assert Enum.any?(files, &String.contains?(&1, "login_redirect"))
      assert Enum.any?(files, &String.contains?(&1, "missing_validation"))
      assert Enum.any?(files, &String.contains?(&1, "typo"))
    end

    test "issue file content has severity, description, source sections", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      dir = issues_dir(scope.environment)
      files = File.ls!(dir)
      login_file = Enum.find(files, &String.contains?(&1, "login_redirect"))

      content = File.read!(Path.join(dir, login_file))
      assert content =~ "## Severity"
      assert content =~ "high"
      assert content =~ "## Description"
      assert content =~ "invited users"
      assert content =~ "## Source"
      assert content =~ "QA Story #{story.id}"
    end

    test "doesn't overwrite existing issue files", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      # Run evaluate to create files
      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      dir = issues_dir(scope.environment)
      files = File.ls!(dir)
      login_file = Enum.find(files, &String.contains?(&1, "login_redirect"))
      original_content = File.read!(Path.join(dir, login_file))

      # Modify the file
      File.write!(Path.join(dir, login_file), "MODIFIED")

      # Run evaluate again
      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      # File should NOT be overwritten
      assert File.read!(Path.join(dir, login_file)) == "MODIFIED"
      refute File.read!(Path.join(dir, login_file)) == original_content
    end
  end

  # ============================================================================
  # evaluate/3 — Scope in Issue Files
  # ============================================================================

  describe "evaluate/3 scope in issue files" do
    setup [:create_scope, :create_story, :create_session, :create_qa_plan]

    test "issue files include default scope of app", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      dir = issues_dir(scope.environment)
      files = File.ls!(dir)
      login_file = Enum.find(files, &String.contains?(&1, "login_redirect"))

      content = File.read!(Path.join(dir, login_file))
      assert content =~ "## Scope\n\napp"
    end

    test "issue files preserve explicit scope from result", %{
      scope: scope,
      session: session,
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

      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      dir = issues_dir(scope.environment)
      files = File.ls!(dir)
      seed_file = Enum.find(files, &String.contains?(&1, "seed_script"))

      content = File.read!(Path.join(dir, seed_file))
      assert content =~ "## Scope\n\nqa"
    end
  end
end
