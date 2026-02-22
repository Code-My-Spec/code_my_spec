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
        description: "Users can log in and out of the application",
        criteria: [
          %{description: "User can log in with email and password"},
          %{description: "User sees an error for invalid credentials"}
        ]
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

  defp write_mix_exs(env, app_name \\ "my_app") do
    write_file!(env, "mix.exs", """
    defmodule #{Macro.camelize(app_name)}.MixProject do
      use Mix.Project
      def project do
        [app: :#{app_name}, version: "0.1.0"]
      end
    end
    """)
  end

  defp write_qa_result(env, story_id, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/#{story_id}.md",
      content ||
        """
        # QA: Story #{story_id}

        ## Status: PASS

        ## Scenarios Tested
        - User logs in: PASS — login form works

        ## Issues Found
        None

        ## Evidence
        - Visited /login, form renders correctly
        """
    )
  end

  defp write_issue(env, name, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/issues/#{name}.md",
      content || "# #{name}\n\nDescription of the issue."
    )
  end

  defp write_spex_file(env, story_id, criterion_id, content) do
    dir = "test/spex/#{story_id}_test_story"
    filename = "criterion_#{criterion_id}_test_spex.exs"
    write_file!(env, "#{dir}/#{filename}", content)
  end

  @sample_spex """
  defmodule Test.Spex.UserAuth do
    use Spex

    spex "User authentication", story: 42, criterion: 1 do
      scenario "User logs in" do
        given "a registered user"
        when_ "the user submits valid credentials"
        then_ "the user sees the dashboard"
      end
    end
  end
  """

  # ============================================================================
  # load_specs/2 Tests
  # ============================================================================

  describe "load_specs/2" do
    setup [:create_scope]

    test "returns empty tuples when no specs exist", %{scope: scope} do
      assert {[], []} = QaStory.load_specs(scope.environment, 42)
    end

    test "returns projections and file paths when specs exist", %{scope: scope} do
      write_spex_file(scope.environment, 42, 1, @sample_spex)

      {projections, file_paths} = QaStory.load_specs(scope.environment, 42)

      assert length(projections) == 1
      assert length(file_paths) == 1
      assert hd(file_paths) =~ "test/spex/42_test_story/criterion_1_test_spex.exs"
      assert hd(projections) =~ "User authentication"
    end
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_story, :create_session]

    test "returns ok tuple with prompt containing story ID", %{
      scope: scope,
      session: session,
      story: story
    } do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert is_binary(prompt)
      assert prompt =~ to_string(story.id)
    end

    test "includes story title and description in prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "User Authentication"
      assert prompt =~ "Users can log in and out of the application"
    end

    test "includes acceptance criteria in prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "User can log in with email and password"
      assert prompt =~ "User sees an error for invalid credentials"
    end

    test "references web-cli knowledge article", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "web-cli"
    end

    test "includes router path reference", %{scope: scope, session: session} do
      write_mix_exs(scope.environment)

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "router.ex"
    end

    test "includes BDD specs when they exist", %{scope: scope, session: session, story: story} do
      write_spex_file(scope.environment, story.id, 1, @sample_spex)

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "User authentication"
      assert prompt =~ "test/spex/#{story.id}_test_story"
    end

    test "handles missing specs gracefully", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "No BDD specs found"
    end

    test "includes existing result when present", %{scope: scope, session: session, story: story} do
      write_qa_result(scope.environment, story.id)

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "Existing QA Result"
    end

    test "references existing issues when present", %{scope: scope, session: session} do
      write_issue(scope.environment, "login-form-broken")

      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "login-form-broken"
    end

    test "includes structured output format", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ "## Status:"
      assert prompt =~ "## Scenarios Tested"
      assert prompt =~ "## Issues Found"
    end

    test "instructs agent to write QA result", %{scope: scope, session: session, story: story} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/#{story.id}.md"
    end

    test "includes issue filing instructions", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ ".code_my_spec/issues/"
    end

    test "accepts string story ID", %{scope: scope, story: story} do
      session = %{project: scope.active_project, state: %{"topic" => to_string(story.id)}}
      assert {:ok, prompt} = QaStory.command(scope, session)
      assert prompt =~ to_string(story.id)
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when QA result exists with status line", %{
      scope: scope,
      session: session
    } do
      write_qa_result(scope.environment, 42)

      assert {:ok, :valid} = QaStory.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when QA result is missing", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "No QA result found"
    end

    test "returns {:ok, :invalid, feedback} when QA result is empty", %{
      scope: scope,
      session: session
    } do
      write_qa_result(scope.environment, 42, "")

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "empty"
    end

    test "returns {:ok, :invalid, feedback} when QA result missing status line", %{
      scope: scope,
      session: session
    } do
      write_qa_result(scope.environment, 42, "# QA Result\n\nSome content without status.")

      assert {:ok, :invalid, feedback} = QaStory.evaluate(scope, session)
      assert feedback =~ "Status:"
    end
  end
end
