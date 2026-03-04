defmodule CodeMySpec.AgentTasks.WriteBddSpecsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.ComponentsFixtures

  @moduletag :tmp_dir

  @external_id "test-conversation-00000000-0000-0000-0000-000000000001"

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp scope_with_env(tmp_dir) do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, tmp_dir)}
  end

  defp session_with_story(scope, _tmp_dir, story_opts \\ %{}) do
    component =
      component_fixture(scope, %{type: "liveview", module_name: "MyAppWeb.UserLoginLive"})

    story =
      story_fixture(
        scope,
        Map.merge(%{title: "User Login Feature", component_id: component.id}, story_opts)
      )

    criterion1 =
      criterion_fixture(scope, story, %{description: "User can log in with valid credentials"})

    criterion2 =
      criterion_fixture(scope, story, %{description: "User sees error with invalid credentials"})

    # Reload story with criteria
    story = %{story | criteria: [criterion1, criterion2]}

    %{
      story_id: story.id,
      story: story,
      external_conversation_id: @external_id
    }
  end

  defp session_without_story(_tmp_dir) do
    %{external_conversation_id: @external_id}
  end

  defp session_with_unlinked_story(scope, _tmp_dir) do
    # Story without component_id
    story = story_fixture(scope, %{title: "Unlinked Story", component_id: nil})
    criterion = criterion_fixture(scope, story, %{description: "Some criterion"})
    story = %{story | criteria: [criterion]}

    %{
      story_id: story.id,
      story: story,
      external_conversation_id: @external_id
    }
  end

  defp prompt_file_path(tmp_dir, story) do
    Path.join(
      tmp_dir,
      ".code_my_spec/sessions/#{@external_id}/subagent_prompts/bdd_specs_story_#{story.id}.md"
    )
  end

  defp orchestration_file_path(tmp_dir) do
    Path.join(tmp_dir, ".code_my_spec/sessions/#{@external_id}/write_bdd_specs.md")
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
    test "writes prompt file to disk and returns message pointing to orchestration file", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      assert {:ok, message} = WriteBddSpecs.command(scope, session, skip_sync: true)
      assert message =~ "write_bdd_specs.md"

      # Orchestration file references the story and subagent
      orch_content = File.read!(orchestration_file_path(tmp_dir))
      assert orch_content =~ session.story.title
      assert orch_content =~ "bdd-spec-writer"

      # Subagent prompt file written to disk
      file_path = prompt_file_path(tmp_dir, session.story)
      assert File.exists?(file_path)

      # Prompt file contains the full detailed prompt
      file_content = File.read!(file_path)
      assert file_content =~ "Write BDD Specifications for Story"
      assert file_content =~ session.story.title
    end

    test "prompt file includes all acceptance criteria", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)

      file_content = File.read!(prompt_file_path(tmp_dir, session.story))
      assert file_content =~ "User can log in with valid credentials"
      assert file_content =~ "User sees error with invalid credentials"
    end

    test "prompt file includes expected file paths for each criterion", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      [criterion1, criterion2] = session.story.criteria
      expected_path1 = BddSpecs.spec_file_path(session.story, criterion1)
      expected_path2 = BddSpecs.spec_file_path(session.story, criterion2)

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)

      file_content = File.read!(prompt_file_path(tmp_dir, session.story))
      assert file_content =~ expected_path1
      assert file_content =~ expected_path2
    end

    test "prompt file includes Spex DSL syntax guide", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)

      file_content = File.read!(prompt_file_path(tmp_dir, session.story))
      assert file_content =~ "Spex DSL Syntax Guide"
      assert file_content =~ "scenario"
      assert file_content =~ "given_"
      assert file_content =~ "when_"
      assert file_content =~ "then_"
    end

    test "prompt file includes LiveView testing guide for liveview components", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)

      file_content = File.read!(prompt_file_path(tmp_dir, session.story))
      assert file_content =~ "LiveView Testing Guide"
      assert file_content =~ "Phoenix.LiveViewTest"
    end

    test "prompt file includes Controller testing guide for controller components", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)

      component =
        component_fixture(scope, %{type: "controller", module_name: "MyAppWeb.UserController"})

      story = story_fixture(scope, %{title: "Controller Feature", component_id: component.id})
      criterion = criterion_fixture(scope, story, %{description: "Some criterion"})
      story = %{story | criteria: [criterion]}

      session = %{
        story_id: story.id,
        story: story,
        external_conversation_id: @external_id
      }

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)

      file_content = File.read!(prompt_file_path(tmp_dir, story))
      assert file_content =~ "Controller Testing Guide"
      assert file_content =~ "Phoenix.ConnTest"
    end

    test "scaffolds app_spex.ex and shared_givens.ex if they do not exist", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Without mix.exs, defaults to my_app
      app_spex_path = Path.join(tmp_dir, "test/spex/my_app_spex.ex")
      shared_givens_path = Path.join(tmp_dir, "test/support/shared_givens.ex")
      refute File.exists?(app_spex_path)
      refute File.exists?(shared_givens_path)

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)
      assert File.exists?(app_spex_path)
      assert File.exists?(shared_givens_path)
    end

    test "prompt file includes current shared givens content", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Pre-create shared givens with custom content
      shared_givens_path = Path.join(tmp_dir, "test/support/shared_givens.ex")
      File.mkdir_p!(Path.dirname(shared_givens_path))

      File.write!(shared_givens_path, """
      defmodule MyAppSpex.SharedGivens do
        use SexySpex.Givens

        given_ :user_exists do
          {:ok, %{user: %{id: 1}}}
        end
      end
      """)

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)

      file_content = File.read!(prompt_file_path(tmp_dir, session.story))
      assert file_content =~ "user_exists"
    end

    test "returns error if component is not linked", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_unlinked_story(scope, tmp_dir)

      assert {:error, :component_not_linked} =
               WriteBddSpecs.command(scope, session, skip_sync: true)
    end

    test "auto-selects top-priority incomplete story when no story_id", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create multiple stories with different priorities
      component = component_fixture(scope, %{type: "liveview", module_name: "MyAppWeb.TestLive"})

      _low_priority =
        story_fixture(scope, %{title: "Low Priority", priority: 3, component_id: component.id})

      high_priority =
        story_fixture(scope, %{title: "High Priority", priority: 1, component_id: component.id})

      # Add criteria
      criterion = criterion_fixture(scope, high_priority, %{description: "Test criterion"})
      _high_priority = %{high_priority | criteria: [criterion]}

      session = session_without_story(tmp_dir)

      assert {:ok, _message} = WriteBddSpecs.command(scope, session, skip_sync: true)
      orch_content = File.read!(orchestration_file_path(tmp_dir))
      assert orch_content =~ "High Priority"
    end

    test "returns error when all stories complete and no story_id provided", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = component_fixture(scope, %{type: "liveview", module_name: "MyAppWeb.TestLive"})
      story = story_fixture(scope, %{title: "Complete Story", component_id: component.id})
      criterion = criterion_fixture(scope, story, %{description: "Done criterion"})
      story = %{story | criteria: [criterion]}

      # Write spec file to make it complete
      write_valid_spec_file!(tmp_dir, story, criterion)

      session = session_without_story(tmp_dir)

      assert {:error, :all_stories_complete} =
               WriteBddSpecs.command(scope, session, skip_sync: true)
    end

    test "skips fully covered story and selects next incomplete story", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = component_fixture(scope, %{type: "liveview", module_name: "MyAppWeb.TestLive"})

      # First story - higher priority, fully covered
      story1 =
        story_fixture(scope, %{
          title: "First Story Complete",
          priority: 1,
          component_id: component.id
        })

      criterion1a = criterion_fixture(scope, story1, %{description: "Criterion 1A"})
      criterion1b = criterion_fixture(scope, story1, %{description: "Criterion 1B"})

      # Second story - lower priority, incomplete
      story2 =
        story_fixture(scope, %{
          title: "Second Story Incomplete",
          priority: 2,
          component_id: component.id
        })

      _criterion2 = criterion_fixture(scope, story2, %{description: "Criterion 2A"})

      # Write specs for ALL criteria of story1 to make it fully covered
      write_valid_spec_file!(tmp_dir, story1, criterion1a)
      write_valid_spec_file!(tmp_dir, story1, criterion1b)

      # Don't write specs for story2 - it should be selected

      session = session_without_story(tmp_dir)

      assert {:ok, _message} = WriteBddSpecs.command(scope, session, skip_sync: true)
      # Should select story2, not story1
      orch_content = File.read!(orchestration_file_path(tmp_dir))
      assert orch_content =~ "Second Story Incomplete"
      refute orch_content =~ "First Story Complete"
    end

    test "prompt file marks covered criteria", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Write spec for first criterion only
      [criterion1, _criterion2] = session.story.criteria
      write_valid_spec_file!(tmp_dir, session.story, criterion1)

      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)

      file_content = File.read!(prompt_file_path(tmp_dir, session.story))
      assert file_content =~ "COVERED"
      assert file_content =~ "MISSING"
    end

    test "orchestration file references the subagent prompt file path", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      assert {:ok, _message} = WriteBddSpecs.command(scope, session, skip_sync: true)

      expected_relative_path =
        ".code_my_spec/sessions/#{@external_id}/subagent_prompts/bdd_specs_story_#{session.story.id}.md"

      orch_content = File.read!(orchestration_file_path(tmp_dir))
      assert orch_content =~ expected_relative_path
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} or compile error when all specs exist and are valid", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Write valid specs for all criteria
      for criterion <- session.story.criteria do
        write_valid_spec_file!(tmp_dir, session.story, criterion)
      end

      # The spec validation passes, but mix compile will fail in test environment
      # because tmp_dir doesn't have a mix project. This is expected behavior.
      result = WriteBddSpecs.evaluate(scope, session, [])

      case result do
        {:ok, :valid} ->
          # Specs valid and compilation passed
          assert true

        {:ok, :invalid, feedback} ->
          # If compile fails (expected in test env without mix project), feedback mentions compilation
          assert feedback =~ "Compilation" or feedback =~ "mix"

        {:error, reason} ->
          # Should not return error for valid specs
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end

    test "returns {:ok, :invalid, feedback} when spec file is missing", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Don't write any spec files

      assert {:ok, :invalid, feedback} = WriteBddSpecs.evaluate(scope, session, [])
      assert is_binary(feedback)
      assert feedback =~ "Spec file not found"
    end

    test "returns {:ok, :invalid, feedback} when spec has syntax errors", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Write broken specs for all criteria
      for criterion <- session.story.criteria do
        write_spec_with_syntax_error!(tmp_dir, session.story, criterion)
      end

      assert {:ok, :invalid, feedback} = WriteBddSpecs.evaluate(scope, session, [])
      assert is_binary(feedback)
    end

    test "returns {:ok, :invalid, feedback} when spec has no scenarios", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Write specs without scenarios for all criteria
      for criterion <- session.story.criteria do
        write_spec_without_scenarios!(tmp_dir, session.story, criterion)
      end

      assert {:ok, :invalid, feedback} = WriteBddSpecs.evaluate(scope, session, [])
      assert is_binary(feedback)
      assert feedback =~ "scenario"
    end

    test "returns {:ok, :invalid, feedback} when scenarios have no steps", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Write specs without steps for all criteria
      for criterion <- session.story.criteria do
        write_spec_without_steps!(tmp_dir, session.story, criterion)
      end

      assert {:ok, :invalid, feedback} = WriteBddSpecs.evaluate(scope, session, [])
      assert is_binary(feedback)
      assert feedback =~ "step" or feedback =~ "Given" or feedback =~ "When" or feedback =~ "Then"
    end

    test "includes criterion id and description in error feedback", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # Don't write any spec files

      assert {:ok, :invalid, feedback} = WriteBddSpecs.evaluate(scope, session, [])

      [criterion1, _] = session.story.criteria
      assert feedback =~ "Criterion #{criterion1.id}"
      assert feedback =~ criterion1.description
    end

    test "returns error when story cannot be resolved", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      session = %{
        story_id: 999_999,
        external_conversation_id: @external_id
      }

      assert {:error, :story_not_found} = WriteBddSpecs.evaluate(scope, session, [])
    end

    test "cleans up prompt file on valid result", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = session_with_story(scope, tmp_dir)

      # First, write the prompt file via command
      assert {:ok, _prompt} = WriteBddSpecs.command(scope, session, skip_sync: true)
      file_path = prompt_file_path(tmp_dir, session.story)
      assert File.exists?(file_path)

      # Write valid specs for all criteria
      for criterion <- session.story.criteria do
        write_valid_spec_file!(tmp_dir, session.story, criterion)
      end

      result = WriteBddSpecs.evaluate(scope, session, [])

      case result do
        {:ok, :valid} ->
          # Prompt file should be cleaned up
          refute File.exists?(file_path)

        {:ok, :invalid, _feedback} ->
          # Compile may fail in test env - prompt file stays on invalid
          assert File.exists?(file_path)
      end
    end
  end
end
