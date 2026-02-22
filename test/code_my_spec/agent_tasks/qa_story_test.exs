defmodule CodeMySpec.AgentTasks.QaStoryTest do
  @moduledoc false
  use CodeMySpec.DataCase

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

  defp create_session(context) do
    session = %{
      project: context.scope.active_project,
      state: %{"topic" => "42-user-authentication"}
    }

    Map.put(context, :session, session)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_qa_brief(env, story_slug, content \\ nil) do
    write_file!(
      env,
      "docs/status/qa/#{story_slug}.md",
      content ||
        """
        ## Story: User Authentication

        Test the login page at /login. Verify:
        - Form renders with email and password fields
        - Successful login redirects to dashboard
        - Invalid credentials show error message
        """
    )
  end

  defp write_qa_result(env, story_slug, content \\ nil) do
    write_file!(
      env,
      "docs/qa/#{story_slug}.md",
      content ||
        """
        # QA Result: User Authentication

        ## Routes Tested
        - GET /login
        - POST /login

        ## Results
        - Login form renders correctly
        - Successful login redirects to /dashboard
        - Invalid credentials show flash error

        ## Issues
        None found.
        """
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
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with prompt containing story slug", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert is_binary(prompt)
      assert prompt =~ "42-user-authentication"
    end

    test "includes QA brief when brief file exists", %{scope: scope, session: session} do
      write_qa_brief(scope.environment, "42-user-authentication")

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Test the login page"
    end

    test "includes existing result when present", %{scope: scope, session: session} do
      write_qa_result(scope.environment, "42-user-authentication")

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Existing QA Result"
    end

    test "references existing issues when present", %{scope: scope, session: session} do
      write_issue(scope.environment, "login-form-broken")

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "login-form-broken"
    end

    test "includes web tool instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "web http://localhost:4000"
      assert prompt =~ "--profile qa"
    end

    test "includes issue filing instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "docs/issues/"
    end

    test "instructs agent to write QA result", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "docs/qa/42-user-authentication.md"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when QA result exists and is non-empty", %{
      scope: scope,
      session: session
    } do
      write_qa_result(scope.environment, "42-user-authentication")

      assert {:ok, :valid} = QaStory.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when QA result is missing", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "QA result"
    end

    test "returns {:ok, :invalid, feedback} when QA result is empty", %{
      scope: scope,
      session: session
    } do
      write_qa_result(scope.environment, "42-user-authentication", "")

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "empty"
    end

    test "cleans up QA brief file on success", %{scope: scope, session: session} do
      env = scope.environment
      write_qa_brief(env, "42-user-authentication")
      write_qa_result(env, "42-user-authentication")

      brief_path = Path.join(env.cwd, "docs/status/qa/42-user-authentication.md")
      assert File.exists?(brief_path)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)
      refute File.exists?(brief_path)
    end
  end
end
