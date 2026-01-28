defmodule CodeMySpec.Sessions.AgentTasks.WriteBddSpecTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.Sessions.AgentTasks.WriteBddSpec
  alias CodeMySpec.BddSpecs

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures

  @moduletag :tmp_dir

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp session_with_story_and_criterion(scope, tmp_dir) do
    story = story_fixture(scope, %{title: "User Login Feature"})
    criterion = criterion_fixture(scope, story, %{description: "User can log in with valid credentials"})

    %{
      story: story,
      criterion: criterion,
      environment: %CodeMySpec.Environments.Environment{
        type: :local,
        ref: %{working_dir: tmp_dir},
        cwd: tmp_dir,
        metadata: %{}
      }
    }
  end

  defp session_without_story(tmp_dir) do
    %{
      criterion: %{id: 1, description: "Some criterion"},
      environment: %CodeMySpec.Environments.Environment{
        type: :local,
        ref: %{working_dir: tmp_dir},
        cwd: tmp_dir,
        metadata: %{}
      }
    }
  end

  defp session_without_criterion(scope, tmp_dir) do
    story = story_fixture(scope, %{title: "User Login Feature"})

    %{
      story: story,
      environment: %CodeMySpec.Environments.Environment{
        type: :local,
        ref: %{working_dir: tmp_dir},
        cwd: tmp_dir,
        metadata: %{}
      }
    }
  end

  defp write_valid_spec_file!(tmp_dir, story, criterion) do
    spec_path = BddSpecs.spec_file_path(story, criterion)
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    defmodule MyApp.UserLoginSpex do
      use Spex

      spex "user login feature" do
        scenario "valid credentials" do
          given_ "a registered user", _context do
            {:ok, %{user: %{email: "test@example.com"}}}
          end

          when_ "user submits login form", context do
            {:ok, context}
          end

          then_ "user is authenticated", context do
            assert context.user
            :ok
          end
        end
      end
    end
    """

    File.write!(full_path, content)
    full_path
  end

  defp write_spec_with_syntax_error!(tmp_dir, story, criterion) do
    spec_path = BddSpecs.spec_file_path(story, criterion)
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    defmodule MyApp.BrokenSpex do
      use Spex

      spex "broken spec" do
        # Missing closing do/end
        scenario "incomplete"
      end
    """

    File.write!(full_path, content)
    full_path
  end

  defp write_spec_without_scenarios!(tmp_dir, story, criterion) do
    spec_path = BddSpecs.spec_file_path(story, criterion)
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    defmodule MyApp.EmptySpex do
      use Spex

      spex "empty spec" do
        # No scenarios defined
      end
    end
    """

    File.write!(full_path, content)
    full_path
  end

  defp write_spec_without_steps!(tmp_dir, story, criterion) do
    spec_path = BddSpecs.spec_file_path(story, criterion)
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    defmodule MyApp.NoStepsSpex do
      use Spex

      spex "no steps spec" do
        scenario "empty scenario" do
          # No given/when/then steps
        end
      end
    end
    """

    File.write!(full_path, content)
    full_path
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns ok tuple with prompt text for valid session", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)

      assert {:ok, prompt} = WriteBddSpec.command(scope, session, [])
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes story title and description in prompt", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)

      assert {:ok, prompt} = WriteBddSpec.command(scope, session, [])
      assert prompt =~ session.story.title
    end

    test "includes criterion description in prompt", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)

      assert {:ok, prompt} = WriteBddSpec.command(scope, session, [])
      assert prompt =~ session.criterion.description
    end

    test "includes Spex DSL syntax guide in prompt", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)

      assert {:ok, prompt} = WriteBddSpec.command(scope, session, [])
      # Should include Spex DSL keywords
      assert prompt =~ "spex" or prompt =~ "Spex"
      assert prompt =~ "scenario"
    end

    test "includes expected file path from BddSpecs.spec_file_path/2", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)

      expected_path = BddSpecs.spec_file_path(session.story, session.criterion)

      assert {:ok, prompt} = WriteBddSpec.command(scope, session, [])
      assert prompt =~ expected_path
    end

    test "includes Given/When/Then structure guidance", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)

      assert {:ok, prompt} = WriteBddSpec.command(scope, session, [])
      assert prompt =~ "given" or prompt =~ "Given"
      assert prompt =~ "when" or prompt =~ "When"
      assert prompt =~ "then" or prompt =~ "Then"
    end

    test "returns error if story is missing from session", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_without_story(tmp_dir)

      assert {:error, _reason} = WriteBddSpec.command(scope, session, [])
    end

    test "returns error if criterion is missing from session", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_without_criterion(scope, tmp_dir)

      assert {:error, _reason} = WriteBddSpec.command(scope, session, [])
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when spec file is valid Spex DSL", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)
      write_valid_spec_file!(tmp_dir, session.story, session.criterion)

      assert {:ok, :valid} = WriteBddSpec.evaluate(scope, session, [])
    end

    test "returns {:ok, :invalid, feedback} when spec file has syntax errors", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)
      write_spec_with_syntax_error!(tmp_dir, session.story, session.criterion)

      assert {:ok, :invalid, feedback} = WriteBddSpec.evaluate(scope, session, [])
      assert is_binary(feedback)
    end

    test "returns {:ok, :invalid, feedback} when spec has no scenarios", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)
      write_spec_without_scenarios!(tmp_dir, session.story, session.criterion)

      assert {:ok, :invalid, feedback} = WriteBddSpec.evaluate(scope, session, [])
      assert is_binary(feedback)
      assert feedback =~ "scenario" or feedback =~ "Scenario"
    end

    test "returns {:ok, :invalid, feedback} when scenarios have no steps", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)
      write_spec_without_steps!(tmp_dir, session.story, session.criterion)

      assert {:ok, :invalid, feedback} = WriteBddSpec.evaluate(scope, session, [])
      assert is_binary(feedback)
      assert feedback =~ "step" or feedback =~ "Step" or feedback =~ "given" or feedback =~ "when" or feedback =~ "then"
    end

    test "includes parse error details in feedback", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)
      write_spec_with_syntax_error!(tmp_dir, session.story, session.criterion)

      assert {:ok, :invalid, feedback} = WriteBddSpec.evaluate(scope, session, [])
      assert is_binary(feedback)
      assert String.length(feedback) > 0
    end

    test "returns error when spec file does not exist", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_with_story_and_criterion(scope, tmp_dir)
      # Don't create the spec file

      assert {:error, _reason} = WriteBddSpec.evaluate(scope, session, [])
    end

    test "returns error when story or criterion missing from session", %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      session = session_without_story(tmp_dir)

      assert {:error, _reason} = WriteBddSpec.evaluate(scope, session, [])
    end
  end
end
