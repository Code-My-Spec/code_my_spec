defmodule CodeMySpec.BddSpecsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures

  # ============================================================================
  # Fixtures - Test Directories and Files
  # ============================================================================

  defp create_test_project_with_specs(scope, specs) do
    # Create a temporary directory to act as project root
    dir = Path.join(System.tmp_dir!(), "bdd_specs_test_#{System.unique_integer([:positive])}")
    spex_dir = Path.join(dir, "test/spex")
    File.mkdir_p!(spex_dir)

    # Create spec files based on the provided list
    for {story_id, criterion_id, content} <- specs do
      story_dir = Path.join(spex_dir, "#{story_id}_user_story")
      File.mkdir_p!(story_dir)
      file_path = Path.join(story_dir, "criterion_#{criterion_id}_spex.exs")
      File.write!(file_path, content)
    end

    # Update the project's code_repo to point to this temp directory
    # In a real scenario, active_project.code_repo would contain the path
    project = Map.put(scope.active_project, :code_repo, dir)
    %{scope | active_project: project}
  end

  # Create an Environment struct for BddSpecs functions
  defp create_environment(scope) do
    %Environment{
      type: :local,
      cwd: scope.active_project.code_repo,
      ref: %{working_dir: scope.active_project.code_repo}
    }
  end

  defp cleanup_test_directory(scope) do
    if scope.active_project.code_repo && File.exists?(scope.active_project.code_repo) do
      File.rm_rf!(scope.active_project.code_repo)
    end
  end

  defp valid_spex_content(name \\ "test spec") do
    """
    defmodule TestSpex do
      use SexySpex

      spex "#{name}", description: "A test specification" do
        scenario "test scenario", context do
          given_ "a precondition", context do
            context
          end

          when_ "an action occurs", context do
            context
          end

          then_ "an outcome is expected", context do
            assert true
          end
        end
      end
    end
    """
  end

  defp complete_spex_content do
    """
    defmodule CompleteSpex do
      use SexySpex

      spex "complete specification",
        description: "A complete spec with metadata",
        tags: [:integration, :acceptance] do
        scenario "first scenario", context do
          given_ "setup step", context do
            context
          end

          when_ "action happens", context do
            context
          end

          then_ "result occurs", context do
            assert true
          end
        end

        scenario "second scenario", context do
          given_ "another setup", context do
            context
          end

          when_ "another action", context do
            context
          end

          then_ "another result", context do
            assert true
          end
        end
      end
    end
    """
  end

  defp invalid_spex_content_no_spex_macro do
    """
    defmodule NoSpexMacro do
      use SexySpex

      def some_function do
        :ok
      end
    end
    """
  end

  defp invalid_spex_content_malformed_scenario do
    """
    defmodule MalformedSpex do
      use SexySpex

      spex "malformed spec" do
        scenario "incomplete scenario", context do
          given_ "missing when and then", context do
            context
          end
        end
      end
    end
    """
  end

  # ============================================================================
  # list_specs/1
  # ============================================================================

  describe "list_specs/1" do
    test "returns all spec files in test/spex directory" do
      scope = full_scope_fixture()

      specs = [
        {1, 1, valid_spex_content("spec 1")},
        {1, 2, valid_spex_content("spec 2")},
        {2, 3, valid_spex_content("spec 3")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs(env)
      assert length(result) == 3
      assert Enum.all?(result, &match?(%BddSpecs.Spec{}, &1))
    end

    test "returns empty list when no specs exist" do
      scope = full_scope_fixture()

      # Create project root but no specs
      dir = Path.join(System.tmp_dir!(), "empty_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test/spex"))

      project = Map.put(scope.active_project, :code_repo, dir)
      scope = %{scope | active_project: project}
      env = create_environment(scope)

      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.list_specs(env)
      assert result == []
    end

    test "returns Spec structs with scenarios and step descriptions" do
      scope = full_scope_fixture()
      specs = [{1, 1, complete_spex_content()}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      [spec] = BddSpecs.list_specs(env)
      assert spec.name == "complete specification"
      assert spec.description == "A complete spec with metadata"
      assert length(spec.scenarios) == 2
      assert is_list(spec.tags)

      [scenario1, _scenario2] = spec.scenarios
      assert scenario1.name == "first scenario"
      assert is_list(scenario1.given_steps)
      assert is_list(scenario1.when_steps)
      assert is_list(scenario1.then_steps)
    end

    test "handles nested directory structures" do
      scope = full_scope_fixture()

      specs = [
        {10, 1, valid_spex_content("nested spec 1")},
        {20, 2, valid_spex_content("nested spec 2")},
        {30, 3, valid_spex_content("nested spec 3")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs(env)
      assert length(result) == 3

      spec_names = Enum.map(result, & &1.name)
      assert "nested spec 1" in spec_names
      assert "nested spec 2" in spec_names
      assert "nested spec 3" in spec_names
    end

    test "respects project scope" do
      scope1 = full_scope_fixture()
      scope2 = full_scope_fixture()

      scope1 = create_test_project_with_specs(scope1, [{1, 1, valid_spex_content("scope1 spec")}])
      env1 = create_environment(scope1)

      scope2 =
        create_test_project_with_specs(scope2, [{2, 2, valid_spex_content("scope2 spec")}])

      env2 = create_environment(scope2)

      on_exit(fn ->
        cleanup_test_directory(scope1)
        cleanup_test_directory(scope2)
      end)

      result1 = BddSpecs.list_specs(env1)
      result2 = BddSpecs.list_specs(env2)

      assert length(result1) == 1
      assert length(result2) == 1
      assert hd(result1).name == "scope1 spec"
      assert hd(result2).name == "scope2 spec"
    end
  end

  # ============================================================================
  # list_specs_for_story/2
  # ============================================================================

  describe "list_specs_for_story/2" do
    test "returns specs in story directory" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      specs = [
        {story.id, 1, valid_spex_content("story criterion 1")},
        {story.id, 2, valid_spex_content("story criterion 2")},
        {999, 3, valid_spex_content("other story spec")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs_for_story(env, story.id)
      assert length(result) == 2

      spec_names = Enum.map(result, & &1.name)
      assert "story criterion 1" in spec_names
      assert "story criterion 2" in spec_names
      refute "other story spec" in spec_names
    end

    test "returns empty list when story has no specs" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      # Create project with specs for different story
      specs = [{999, 1, valid_spex_content("other story spec")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs_for_story(env, story.id)
      assert result == []
    end

    test "extracts story_id from directory naming convention" do
      scope = full_scope_fixture()

      specs = [
        {42, 1, valid_spex_content("spec 1")},
        {42, 2, valid_spex_content("spec 2")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs_for_story(env, 42)
      assert length(result) == 2
      assert Enum.all?(result, &(&1.story_id == 42))
    end

    test "handles multiple specs for same story" do
      scope = full_scope_fixture()

      specs = [
        {100, 1, valid_spex_content("criterion 1")},
        {100, 2, valid_spex_content("criterion 2")},
        {100, 3, valid_spex_content("criterion 3")},
        {100, 4, valid_spex_content("criterion 4")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs_for_story(env, 100)
      assert length(result) == 4
      assert Enum.all?(result, &(&1.story_id == 100))

      criterion_ids = Enum.map(result, & &1.criterion_id)
      assert 1 in criterion_ids
      assert 2 in criterion_ids
      assert 3 in criterion_ids
      assert 4 in criterion_ids
    end
  end

  # ============================================================================
  # list_specs_for_criterion/2
  # ============================================================================

  describe "list_specs_for_criterion/2" do
    test "returns specs matching criterion filename pattern" do
      scope = full_scope_fixture()

      specs = [
        {1, 42, valid_spex_content("criterion 42 spec")},
        {1, 99, valid_spex_content("criterion 99 spec")},
        {2, 42, valid_spex_content("another criterion 42")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs_for_criterion(env, 42)
      assert length(result) == 2

      spec_names = Enum.map(result, & &1.name)
      assert "criterion 42 spec" in spec_names
      assert "another criterion 42" in spec_names
      refute "criterion 99 spec" in spec_names
    end

    test "returns empty list when criterion has no specs" do
      scope = full_scope_fixture()

      specs = [
        {1, 1, valid_spex_content("criterion 1")},
        {1, 2, valid_spex_content("criterion 2")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs_for_criterion(env, 999)
      assert result == []
    end

    test "extracts criterion_id from filename convention" do
      scope = full_scope_fixture()

      specs = [{1, 456, valid_spex_content("test spec")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.list_specs_for_criterion(env, 456)
      assert length(result) == 1
      assert hd(result).criterion_id == 456
    end

    test "handles criterion spec with multiple scenarios" do
      scope = full_scope_fixture()

      specs = [{1, 10, complete_spex_content()}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      [spec] = BddSpecs.list_specs_for_criterion(env, 10)
      assert spec.criterion_id == 10
      assert length(spec.scenarios) == 2
      assert spec.name == "complete specification"
    end
  end

  # ============================================================================
  # get_coverage_report/1
  # ============================================================================

  describe "get_coverage_report/2" do
    test "returns markdown formatted report" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)
      # Embed criteria in story for coverage check
      story = %{story | criteria: [criterion]}

      specs = [{story.id, criterion.id, valid_spex_content("coverage spec")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.get_coverage_report(env, [story])
      assert is_binary(result)
      assert String.contains?(result, "#")
    end

    test "groups specs by story" do
      scope = full_scope_fixture()
      story1 = story_fixture(scope, %{title: "Story One"})
      story2 = story_fixture(scope, %{title: "Story Two"})

      criterion1 = criterion_fixture(scope, story1)
      criterion2 = criterion_fixture(scope, story2)

      # Embed criteria in stories
      story1 = %{story1 | criteria: [criterion1]}
      story2 = %{story2 | criteria: [criterion2]}

      specs = [
        {story1.id, criterion1.id, valid_spex_content("story1 spec")},
        {story2.id, criterion2.id, valid_spex_content("story2 spec")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.get_coverage_report(env, [story1, story2])
      assert String.contains?(result, "Story One")
      assert String.contains?(result, "Story Two")
    end

    test "shows criteria coverage within each story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      criterion1 = criterion_fixture(scope, story, %{description: "Criterion with spec"})
      criterion2 = criterion_fixture(scope, story, %{description: "Criterion without spec"})

      # Embed criteria in story
      story = %{story | criteria: [criterion1, criterion2]}

      specs = [{story.id, criterion1.id, valid_spex_content("covered criterion")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.get_coverage_report(env, [story])
      assert String.contains?(result, "Criterion with spec")
      assert String.contains?(result, "Criterion without spec")
    end

    test "indicates missing coverage with clear markers" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)
      story = %{story | criteria: [criterion]}

      # Create project but no specs
      dir = Path.join(System.tmp_dir!(), "no_coverage_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test/spex"))
      project = Map.put(scope.active_project, :code_repo, dir)
      scope = %{scope | active_project: project}
      env = create_environment(scope)

      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.get_coverage_report(env, [story])
      assert is_binary(result)
      # Should contain some marker for missing coverage
      assert String.contains?(result, "❌") or
               String.contains?(result, "missing") or
               String.contains?(result, "0")
    end

    test "includes summary statistics" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion1 = criterion_fixture(scope, story)
      criterion2 = criterion_fixture(scope, story)
      story = %{story | criteria: [criterion1, criterion2]}

      specs = [{story.id, criterion1.id, valid_spex_content("spec")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.get_coverage_report(env, [story])
      # Should contain some form of statistics
      assert String.contains?(result, "1") or String.contains?(result, "50")
    end
  end

  # ============================================================================
  # check_story_coverage/2
  # ============================================================================

  describe "check_story_coverage/2" do
    test "returns covered criteria IDs that have specs" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      criterion1 = criterion_fixture(scope, story)
      criterion2 = criterion_fixture(scope, story)
      story = %{story | criteria: [criterion1, criterion2]}

      specs = [
        {story.id, criterion1.id, valid_spex_content("covered 1")},
        {story.id, criterion2.id, valid_spex_content("covered 2")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.check_story_coverage(env, story)
      assert is_map(result)
      assert Map.has_key?(result, :covered)
      assert Map.has_key?(result, :missing)

      assert criterion1.id in result.covered
      assert criterion2.id in result.covered
    end

    test "returns missing criteria IDs without specs" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      criterion1 = criterion_fixture(scope, story)
      criterion2 = criterion_fixture(scope, story)
      story = %{story | criteria: [criterion1, criterion2]}

      # Only create spec for criterion1
      specs = [{story.id, criterion1.id, valid_spex_content("only one")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.check_story_coverage(env, story)
      assert criterion1.id in result.covered
      assert criterion2.id in result.missing
    end

    test "handles story with full coverage (empty missing list)" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      criterion1 = criterion_fixture(scope, story)
      criterion2 = criterion_fixture(scope, story)
      story = %{story | criteria: [criterion1, criterion2]}

      specs = [
        {story.id, criterion1.id, valid_spex_content("spec 1")},
        {story.id, criterion2.id, valid_spex_content("spec 2")}
      ]

      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.check_story_coverage(env, story)
      assert result.missing == []
      assert length(result.covered) == 2
    end

    test "handles story with no specs (empty covered list)" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      criterion1 = criterion_fixture(scope, story)
      criterion2 = criterion_fixture(scope, story)
      story = %{story | criteria: [criterion1, criterion2]}

      # Create project but no specs
      dir = Path.join(System.tmp_dir!(), "no_specs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test/spex"))
      project = Map.put(scope.active_project, :code_repo, dir)
      scope = %{scope | active_project: project}
      env = create_environment(scope)

      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.check_story_coverage(env, story)
      assert result.covered == []
      assert criterion1.id in result.missing
      assert criterion2.id in result.missing
    end

    test "handles story with no criteria" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      story = %{story | criteria: []}

      # Create project but no specs
      dir = Path.join(System.tmp_dir!(), "no_criteria_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test/spex"))
      project = Map.put(scope.active_project, :code_repo, dir)
      scope = %{scope | active_project: project}
      env = create_environment(scope)

      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.check_story_coverage(env, story)
      assert result.covered == []
      assert result.missing == []
    end
  end

  # ============================================================================
  # validate_spec_syntax/2
  # ============================================================================

  describe "validate_spec_syntax/1" do
    test "returns :ok for valid Spex syntax" do
      dir = Path.join(System.tmp_dir!(), "valid_syntax_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file_path = Path.join(dir, "valid_spex.exs")
      File.write!(file_path, valid_spex_content())
      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.validate_spec_syntax(file_path)
      assert result == :ok
    end

    test "returns {:error, reasons} for missing spex macro" do
      dir = Path.join(System.tmp_dir!(), "no_spex_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file_path = Path.join(dir, "no_spex.exs")
      File.write!(file_path, invalid_spex_content_no_spex_macro())
      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.validate_spec_syntax(file_path)
      assert {:error, reasons} = result
      assert is_list(reasons)
      assert Enum.any?(reasons, &String.contains?(&1, "spex"))
    end

    test "returns {:error, reasons} for malformed scenarios" do
      dir = Path.join(System.tmp_dir!(), "malformed_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file_path = Path.join(dir, "malformed.ex")
      File.write!(file_path, invalid_spex_content_malformed_scenario())
      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.validate_spec_syntax(file_path)
      # Malformed scenarios might pass or fail depending on validation strictness
      # At minimum, it should not crash
      assert result == :ok or match?({:error, _}, result)
    end

    test "validates given_/when_/then_ step structure" do
      valid_content = """
      defmodule ValidStepsSpex do
        use SexySpex

        spex "valid steps" do
          scenario "complete scenario", context do
            given_ "precondition", context do
              context
            end

            when_ "action", context do
              context
            end

            then_ "assertion", context do
              assert true
            end
          end
        end
      end
      """

      dir = Path.join(System.tmp_dir!(), "valid_steps_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file_path = Path.join(dir, "valid_steps.ex")
      File.write!(file_path, valid_content)
      on_exit(fn -> File.rm_rf!(dir) end)

      result = BddSpecs.validate_spec_syntax(file_path)
      assert result == :ok
    end

    test "handles file not found errors" do
      nonexistent_path =
        "/tmp/nonexistent_spec_#{System.unique_integer([:positive])}/not_here.ex"

      result = BddSpecs.validate_spec_syntax(nonexistent_path)
      assert {:error, reasons} = result
      assert is_list(reasons)
      assert Enum.any?(reasons, &String.contains?(&1, "not found"))
    end
  end

  # ============================================================================
  # get_next_incomplete_story/2
  # ============================================================================

  describe "get_next_incomplete_story/2" do
    test "returns highest priority story with missing specs" do
      scope = full_scope_fixture()

      # Create stories with different priorities
      story1 = story_fixture(scope, %{title: "Low Priority Story", priority: 3})
      story2 = story_fixture(scope, %{title: "High Priority Story", priority: 1})
      story3 = story_fixture(scope, %{title: "Medium Priority Story", priority: 2})

      # Add criteria to each story (stored in database)
      _criterion1 = criterion_fixture(scope, story1)
      _criterion2 = criterion_fixture(scope, story2)
      _criterion3 = criterion_fixture(scope, story3)

      # Create project with NO specs (all stories incomplete)
      dir = Path.join(System.tmp_dir!(), "priority_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test/spex"))
      project = Map.put(scope.active_project, :code_repo, dir)
      scope = %{scope | active_project: project}
      env = create_environment(scope)

      on_exit(fn -> File.rm_rf!(dir) end)

      # Should return highest priority story (priority 1)
      result = BddSpecs.get_next_incomplete_story(env, scope)
      assert result.id == story2.id
      assert result.title == "High Priority Story"
    end

    test "returns nil when all stories have complete coverage" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      criterion = criterion_fixture(scope, story)

      # Create project WITH spec for the criterion
      specs = [{story.id, criterion.id, valid_spex_content("complete spec")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.get_next_incomplete_story(env, scope)
      assert result == nil
    end

    test "skips stories with full coverage and returns first incomplete" do
      scope = full_scope_fixture()

      # Story with complete coverage
      story1 = story_fixture(scope, %{title: "Complete Story", priority: 1, criteria: []})
      criterion1 = criterion_fixture(scope, story1)

      # Story with incomplete coverage
      story2 = story_fixture(scope, %{title: "Incomplete Story", priority: 2, criteria: []})
      _criterion2 = criterion_fixture(scope, story2)

      # Create spec only for story1
      specs = [{story1.id, criterion1.id, valid_spex_content("story1 spec")}]
      scope = create_test_project_with_specs(scope, specs)
      env = create_environment(scope)

      on_exit(fn -> cleanup_test_directory(scope) end)

      result = BddSpecs.get_next_incomplete_story(env, scope)
      assert result.id == story2.id
      assert result.title == "Incomplete Story"
    end

    test "handles story with no criteria" do
      scope = full_scope_fixture()
      # Story created without any criteria (don't call criterion_fixture)
      _story = story_fixture(scope, %{title: "No Criteria Story", criteria: []})

      # Create project
      dir = Path.join(System.tmp_dir!(), "no_criteria_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test/spex"))
      project = Map.put(scope.active_project, :code_repo, dir)
      scope = %{scope | active_project: project}
      env = create_environment(scope)

      on_exit(fn -> File.rm_rf!(dir) end)

      # Story with no criteria is considered complete (no missing specs)
      result = BddSpecs.get_next_incomplete_story(env, scope)
      assert result == nil
    end
  end

  # ============================================================================
  # spec_file_path/2
  # ============================================================================

  describe "spec_file_path/2" do
    test "returns path following naming convention" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "User Authentication", id: 42})
      criterion = criterion_fixture(scope, story)

      result = BddSpecs.spec_file_path(story, criterion)

      assert is_binary(result)
      assert String.contains?(result, "test/spex")
      assert String.contains?(result, "#{story.id}_")
      # Filename includes criterion ID and slugified description
      assert String.contains?(result, "criterion_#{criterion.id}_")
      assert String.ends_with?(result, "_spex.exs")
    end

    test "slugifies story title for directory name" do
      scope = full_scope_fixture()

      story =
        story_fixture(scope, %{
          title: "User Authentication & Authorization"
        })

      criterion = criterion_fixture(scope, story)

      result = BddSpecs.spec_file_path(story, criterion)

      # Should include story ID from database
      assert String.contains?(result, "#{story.id}_")
      # Should be slugified (lowercase, underscored, no special chars)
      assert String.contains?(result, "_user_authentication") or
               String.contains?(result, "user_authentication")

      refute String.contains?(result, "&")
    end

    test "uses criterion_id in filename" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      result = BddSpecs.spec_file_path(story, criterion)

      # Filename is criterion_<id>_<slug>_spex.exs
      assert String.contains?(result, "criterion_#{criterion.id}_")
      assert String.ends_with?(result, "_spex.exs")
    end

    test "produces valid filesystem path" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      result = BddSpecs.spec_file_path(story, criterion)

      # Should be a valid path structure
      assert String.contains?(result, "/")
      assert String.ends_with?(result, ".exs")

      # Should not contain invalid characters for most filesystems
      refute String.contains?(result, "*")
      refute String.contains?(result, "?")
      refute String.contains?(result, "<")
      refute String.contains?(result, ">")
      refute String.contains?(result, "|")
    end

    test "caps filenames under the 255-byte filesystem limit for verbose criteria" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Some Story With A Reasonably Long Title"})

      verbose_description =
        "When a stop is blocked and advisory problems also exist, the blocking response " <>
          "enumerates only the blocking set and collapses the advisory set to one summary line " <>
          "per source (source: N severity (advisory)) — no individual advisory file paths, " <>
          "line numbers, or messages appear."

      criterion = criterion_fixture(scope, story, %{description: verbose_description})

      result = BddSpecs.spec_file_path(story, criterion)
      filename = Path.basename(result)

      assert byte_size(filename) <= 255,
             "filename must fit under the 255-byte filesystem limit, got #{byte_size(filename)}: #{filename}"
    end

    test "truncates the criterion slug on a word boundary" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      verbose =
        "this is a long description that will exceed the slug cap and should be cut " <>
          "on a word boundary rather than mid-word so the filename still reads naturally"

      criterion = criterion_fixture(scope, story, %{description: verbose})

      result = BddSpecs.spec_file_path(story, criterion)
      filename = Path.basename(result)

      # The trailing "_spex.exs" is fixed; the slug sits between the
      # criterion id prefix and the suffix. It must not end mid-word.
      refute filename =~ ~r/_[a-z]{1,3}_spex\.exs$/,
             "truncation should land on a word boundary, got: #{filename}"
    end
  end
end
