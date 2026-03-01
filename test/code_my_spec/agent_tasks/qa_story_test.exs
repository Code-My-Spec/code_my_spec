defmodule CodeMySpec.AgentTasks.QaStoryTest do
  @moduledoc false
  use CodeMySpec.DataCase

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

  defp delete_plan_updates(env) do
    path = Path.join(env.cwd, ".code_my_spec/qa/plan_updates.md")
    File.rm(path)
  end

  defp plan_updates_path(env) do
    Path.join(env.cwd, ".code_my_spec/qa/plan_updates.md")
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

  defp read_prompt_file(env, story_id) do
    path = Path.join(env.cwd, ".code_my_spec/qa/#{story_id}/prompt.md")
    File.read!(path)
  end

  defp issues_dir(env) do
    Path.join(env.cwd, ".code_my_spec/issues/incoming")
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_story, :create_session]

    test "returns ok tuple with non-empty prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "writes prompt.md to disk", %{scope: scope, session: session, story: story} do
      assert {:ok, _prompt} = QaStory.command(scope, session)

      content = read_prompt_file(scope.environment, story.id)
      assert content =~ "User Authentication"
      assert content =~ "Users can log in and out"
    end

    test "prompt.md includes acceptance criteria", %{scope: scope, story: story} do
      session = %{project: scope.active_project, state: %{"topic" => story.id}}

      assert {:ok, _prompt} = QaStory.command(scope, session)
      content = read_prompt_file(scope.environment, story.id)
      assert content =~ "Acceptance Criteria"
    end

    test "prompt.md includes testing approach", %{scope: scope, session: session, story: story} do
      assert {:ok, _prompt} = QaStory.command(scope, session)

      content = read_prompt_file(scope.environment, story.id)
      assert content =~ "Testing Approach"
      assert content =~ "screenshot"
    end

    test "prompt.md does not include agent-specific instructions", %{scope: scope, session: session, story: story} do
      assert {:ok, _prompt} = QaStory.command(scope, session)

      content = read_prompt_file(scope.environment, story.id)
      refute content =~ "Write the brief"
      refute content =~ "Output"
    end

    test "agent prompt includes brief format spec but not result format spec", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Brief Format"
      refute prompt =~ "Result Format"
    end

    test "agent prompt references prompt.md path", %{scope: scope, session: session, story: story} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/#{story.id}/prompt.md"
    end

    test "agent prompt references plan.md when it exists", %{scope: scope, session: session} do
      write_qa_plan(scope.environment)

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/plan.md"
      refute prompt =~ "Warning"
    end

    test "agent prompt includes setup instructions when plan.md is missing", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "No QA plan found"
      assert prompt =~ "Setup Steps"
      assert prompt =~ "qa_seeds"
    end

    test "agent prompt includes plan doc spec when plan.md is missing", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Required Sections"
      assert prompt =~ "App Overview"
    end

    test "agent prompt references brief output path", %{scope: scope, session: session, story: story} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/#{story.id}/brief.md"
    end

    test "agent prompt tells agent to stop after brief", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Stop after writing the brief"
    end

    test "agent prompt does not include phase 2/3 instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      refute prompt =~ "Phase 2"
      refute prompt =~ "Phase 3"
    end

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

      # Delete plan_updates.md so the plan check passes on re-evaluate
      delete_plan_updates(scope.environment)

      # Run evaluate again
      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      # File should NOT be overwritten
      assert File.read!(Path.join(dir, login_file)) == "MODIFIED"
      refute File.read!(Path.join(dir, login_file)) == original_content
    end
  end

  # ============================================================================
  # evaluate/3 — Plan Updates
  # ============================================================================

  describe "evaluate/3 plan updates" do
    setup [:create_scope, :create_story, :create_session, :create_qa_plan]

    test "writes plan_updates.md after successful evaluate", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)
      assert File.exists?(plan_updates_path(scope.environment))
    end

    test "plan_updates.md contains story section with no issues", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      content = File.read!(plan_updates_path(scope.environment))
      assert content =~ "## Story #{story.id}"
      assert content =~ "No issues found"
    end

    test "plan_updates.md contains issue summaries when issues exist", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_result_with_issues(scope.environment, story.id)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      content = File.read!(plan_updates_path(scope.environment))
      assert content =~ "## Story #{story.id}"
      assert content =~ "Login redirect fails for invited users"
      assert content =~ "high"
    end

    test "pending plan_updates.md gates the plan check", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)

      # First evaluate writes plan_updates.md
      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      # Second evaluate is gated by pending updates
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Plan updates are pending"
      assert feedback =~ "plan_updates.md"
      assert feedback =~ "Incorporate"
    end

    test "evaluate proceeds after plan_updates.md is deleted", %{
      scope: scope,
      session: session,
      story: story
    } do
      write_story_brief(scope.environment, story.id)
      write_story_result(scope.environment, story.id)

      # First evaluate writes plan_updates.md
      assert {:ok, :valid} = QaStory.evaluate(scope, session)

      # Simulate agent incorporating and deleting
      delete_plan_updates(scope.environment)

      # Next evaluate proceeds
      assert {:ok, :valid} = QaStory.evaluate(scope, session)
    end
  end
end
