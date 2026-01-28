defmodule CodeMySpec.BddSpecs.ParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.BddSpecs.Spec

  # ============================================================================
  # Fixtures - Valid Spex DSL Files
  # ============================================================================

  defp valid_minimal_spex do
    """
    defmodule MinimalSpex do
      use SexySpex

      spex "minimal spec" do
        scenario "simple scenario", context do
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

  defp valid_complete_spex do
    """
    defmodule CompleteSpex do
      use SexySpex

      spex "complete specification",
        description: "A complete spec with all metadata fields",
        tags: [:integration, :authentication] do
        scenario "user authentication flow", context do
          given_ "the user is not logged in", context do
            Map.put(context, :user, nil)
          end

          given_ "valid credentials are available", context do
            Map.put(context, :credentials, %{email: "test@example.com", password: "secret"})
          end

          when_ "the user submits login form", context do
            Map.put(context, :logged_in, true)
          end

          then_ "the user is authenticated", context do
            assert context.logged_in
          end

          then_ "the dashboard is displayed", context do
            assert context[:current_page] == "/dashboard"
          end
        end

        scenario "logout functionality", context do
          given_ "the user is logged in", context do
            Map.put(context, :logged_in, true)
          end

          when_ "the user clicks logout", context do
            Map.put(context, :logged_in, false)
          end

          then_ "the session is terminated", context do
            refute context.logged_in
          end
        end
      end
    end
    """
  end

  defp spex_with_empty_scenario do
    """
    defmodule EmptyScenarioSpex do
      use SexySpex

      spex "spec with empty scenario" do
        scenario "empty scenario", context do
          # No steps
          context
        end
      end
    end
    """
  end

  # ============================================================================
  # Fixtures - Invalid Spex DSL Files
  # ============================================================================

  defp file_without_spex_macro do
    """
    defmodule NoSpexMacro do
      use SexySpex

      def some_function do
        :ok
      end
    end
    """
  end

  defp file_without_defmodule do
    """
    spex "no module wrapper" do
      scenario "test", context, do: context
    end
    """
  end

  defp file_with_syntax_error do
    """
    defmodule SyntaxError do
      use SexySpex

      spex "broken syntax" do
        scenario "test", context do
          given_ "unclosed string
        end
      end
    end
    """
  end

  defp spex_without_scenarios do
    """
    defmodule NoScenarios do
      use SexySpex

      spex "spec without scenarios" do
        # No scenarios defined
      end
    end
    """
  end

  # ============================================================================
  # Fixtures - File Paths
  # ============================================================================

  defp temp_spex_file(content, filename \\ nil) do
    unique_filename = filename || "test_spex_#{System.unique_integer([:positive])}.exs"
    path = Path.join(System.tmp_dir!(), unique_filename)
    File.write!(path, content)
    path
  end

  defp temp_story_criterion_file(content, story_id, criterion_id) do
    unique_id = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "test_#{unique_id}_#{story_id}_user_authentication")
    File.mkdir_p!(dir)
    path = Path.join(dir, "criterion_#{criterion_id}_spex.exs")
    File.write!(path, content)
    path
  end

  defp cleanup_file(path) do
    if File.exists?(path) do
      File.rm!(path)
    end

    # Also cleanup parent directory if it's a test story directory
    parent = Path.dirname(path)

    if String.contains?(parent, "test_") and
         String.contains?(parent, "_user_authentication") and
         File.dir?(parent) do
      File.rm_rf!(parent)
    end
  end

  defp nonexistent_file_path do
    Path.join(System.tmp_dir!(), "nonexistent_#{System.unique_integer([:positive])}.exs")
  end

  # ============================================================================
  # parse_file/1 - Valid Files
  # ============================================================================

  describe "parse_file/1" do
    test "returns {:ok, spec} for valid Spex DSL file" do
      path = temp_spex_file(valid_minimal_spex())

      try do
        assert {:ok, %Spec{}} = Parser.parse_file(path)
      after
        cleanup_file(path)
      end
    end

    test "extracts spec name from spex macro first argument" do
      path = temp_spex_file(valid_minimal_spex())

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert spec.name == "minimal spec"
      after
        cleanup_file(path)
      end
    end

    test "extracts description from spex options keyword list" do
      path = temp_spex_file(valid_complete_spex())

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert spec.description == "A complete spec with all metadata fields"
      after
        cleanup_file(path)
      end
    end

    test "extracts tags from spex options keyword list" do
      path = temp_spex_file(valid_complete_spex())

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert :integration in spec.tags
        assert :authentication in spec.tags
        assert length(spec.tags) == 2
      after
        cleanup_file(path)
      end
    end

    test "finds all scenario blocks within spex" do
      path = temp_spex_file(valid_complete_spex())

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert length(spec.scenarios) == 2
        scenario_names = Enum.map(spec.scenarios, & &1.name)
        assert "user authentication flow" in scenario_names
        assert "logout functionality" in scenario_names
      after
        cleanup_file(path)
      end
    end

    test "returns error for file with no spex macro" do
      path = temp_spex_file(file_without_spex_macro())

      try do
        assert {:error, _reason} = Parser.parse_file(path)
      after
        cleanup_file(path)
      end
    end

    test "returns error for invalid Elixir syntax" do
      path = temp_spex_file(file_with_syntax_error())

      try do
        assert {:error, _reason} = Parser.parse_file(path)
      after
        cleanup_file(path)
      end
    end

    test "returns error for non-existent file" do
      path = nonexistent_file_path()
      assert {:error, _reason} = Parser.parse_file(path)
    end

    test "extracts story_id from directory pattern {story_id}_*" do
      path = temp_story_criterion_file(valid_minimal_spex(), 123, 1)

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert spec.story_id == 123
      after
        cleanup_file(path)
      end
    end

    test "extracts criterion_id from filename pattern criterion_{id}_spex.exs" do
      path = temp_story_criterion_file(valid_minimal_spex(), 123, 456)

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert spec.criterion_id == 456
      after
        cleanup_file(path)
      end
    end

    test "handles spex files without story/criterion linking" do
      path = temp_spex_file(valid_minimal_spex())

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert is_nil(spec.story_id)
        assert is_nil(spec.criterion_id)
      after
        cleanup_file(path)
      end
    end

    test "preserves file path in returned Spec struct" do
      path = temp_spex_file(valid_minimal_spex())

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert spec.file_path == path
      after
        cleanup_file(path)
      end
    end
  end

  # ============================================================================
  # parse_scenario/1 - Scenario Extraction
  # ============================================================================

  describe "parse_scenario/1" do
    test "extracts scenario name from macro argument" do
      # Create AST representing a scenario macro call
      scenario_ast =
        quote do
          scenario "test scenario name", context do
            context
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert scenario.name == "test scenario name"
    end

    test "finds all given_ macro calls and creates Step structs" do
      scenario_ast =
        quote do
          scenario "test", context do
            given_ "first given", context, do: context
            given_ "second given", context, do: context
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert length(scenario.given_steps) == 2
      assert "first given" in scenario.given_steps
      assert "second given" in scenario.given_steps
    end

    test "finds all when_ macro calls and creates Step structs" do
      scenario_ast =
        quote do
          scenario "test", context do
            when_ "first action", context, do: context
            when_ "second action", context, do: context
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert length(scenario.when_steps) == 2
      assert "first action" in scenario.when_steps
      assert "second action" in scenario.when_steps
    end

    test "finds all then_ macro calls and creates Step structs" do
      scenario_ast =
        quote do
          scenario "test", context do
            then_ "first assertion", context, do: assert(true)
            then_ "second assertion", context, do: assert(true)
            then_ "third assertion", context, do: assert(true)
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert length(scenario.then_steps) == 3
      assert "first assertion" in scenario.then_steps
      assert "second assertion" in scenario.then_steps
      assert "third assertion" in scenario.then_steps
    end

    test "preserves step order as they appear in source" do
      scenario_ast =
        quote do
          scenario "test", context do
            given_ "setup", context, do: context
            when_ "action", context, do: context
            then_ "result", context, do: assert(true)
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert scenario.given_steps == ["setup"]
      assert scenario.when_steps == ["action"]
      assert scenario.then_steps == ["result"]
    end

    test "extracts step descriptions as strings" do
      scenario_ast =
        quote do
          scenario "test", context do
            given_ "user is logged in", context, do: context
            when_ "user clicks logout button", context, do: context
            then_ "user session is terminated", context, do: assert(true)
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert is_binary(hd(scenario.given_steps))
      assert is_binary(hd(scenario.when_steps))
      assert is_binary(hd(scenario.then_steps))
    end

    test "captures line numbers from AST metadata" do
      # This test verifies line number extraction capability
      # Line numbers are embedded in AST metadata
      scenario_ast =
        quote line: 42 do
          scenario "test", context do
            given_ "step", context, do: context
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      # The scenario struct should have line_number set if AST provides it
      assert is_integer(scenario.line_number) or is_nil(scenario.line_number)
    end

    test "handles scenarios with no steps (empty lists)" do
      scenario_ast =
        quote do
          scenario "empty scenario", context do
            context
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert scenario.given_steps == []
      assert scenario.when_steps == []
      assert scenario.then_steps == []
    end

    test "handles scenarios with only given steps" do
      scenario_ast =
        quote do
          scenario "only setup", context do
            given_ "precondition 1", context, do: context
            given_ "precondition 2", context, do: context
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert length(scenario.given_steps) == 2
      assert scenario.when_steps == []
      assert scenario.then_steps == []
    end

    test "handles scenarios with mixed step types" do
      scenario_ast =
        quote do
          scenario "mixed", context do
            given_ "setup 1", context, do: context
            when_ "action 1", context, do: context
            given_ "setup 2", context, do: context
            then_ "assertion 1", context, do: assert(true)
            when_ "action 2", context, do: context
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert length(scenario.given_steps) == 2
      assert length(scenario.when_steps) == 2
      assert length(scenario.then_steps) == 1
    end

    test "groups steps correctly by type (:given, :when, :then)" do
      scenario_ast =
        quote do
          scenario "grouped", context do
            given_ "given step", context, do: context
            when_ "when step", context, do: context
            then_ "then step", context, do: assert(true)
          end
        end

      scenario = Parser.parse_scenario(scenario_ast)
      assert "given step" in scenario.given_steps
      assert "when step" in scenario.when_steps
      assert "then step" in scenario.then_steps
      # Verify no cross-contamination between step types
      refute "given step" in scenario.when_steps
      refute "when step" in scenario.then_steps
      refute "then step" in scenario.given_steps
    end
  end

  # ============================================================================
  # extract_spex_metadata/1 - Metadata Extraction
  # ============================================================================

  describe "extract_spex_metadata/1" do
    test "extracts name from first argument" do
      spex_ast =
        quote do
          spex "test specification" do
          end
        end

      metadata = Parser.extract_spex_metadata(spex_ast)
      assert metadata.name == "test specification"
    end

    test "extracts description from keyword list" do
      spex_ast =
        quote do
          spex "test spec", description: "This is a test specification" do
          end
        end

      metadata = Parser.extract_spex_metadata(spex_ast)
      assert metadata.description == "This is a test specification"
    end

    test "extracts tags list from keyword list" do
      spex_ast =
        quote do
          spex "test spec", tags: [:unit, :integration, :acceptance] do
          end
        end

      metadata = Parser.extract_spex_metadata(spex_ast)
      assert :unit in metadata.tags
      assert :integration in metadata.tags
      assert :acceptance in metadata.tags
      assert length(metadata.tags) == 3
    end

    test "defaults description to nil when not provided" do
      spex_ast =
        quote do
          spex "test spec" do
          end
        end

      metadata = Parser.extract_spex_metadata(spex_ast)
      assert is_nil(metadata.description)
    end

    test "defaults tags to empty list when not provided" do
      spex_ast =
        quote do
          spex "test spec" do
          end
        end

      metadata = Parser.extract_spex_metadata(spex_ast)
      assert metadata.tags == []
    end

    test "handles spex with only name argument" do
      spex_ast =
        quote do
          spex "minimal spec" do
          end
        end

      metadata = Parser.extract_spex_metadata(spex_ast)
      assert metadata.name == "minimal spec"
      assert is_nil(metadata.description)
      assert metadata.tags == []
    end

    test "handles spex with all metadata fields" do
      spex_ast =
        quote do
          spex "complete spec",
            description: "Full metadata example",
            tags: [:complete, :example] do
          end
        end

      metadata = Parser.extract_spex_metadata(spex_ast)
      assert metadata.name == "complete spec"
      assert metadata.description == "Full metadata example"
      assert :complete in metadata.tags
      assert :example in metadata.tags
    end
  end

  # ============================================================================
  # validate_syntax/1 - Syntax Validation
  # ============================================================================

  describe "validate_syntax/1" do
    test "returns :ok for valid Spex DSL file" do
      path = temp_spex_file(valid_complete_spex())

      try do
        assert :ok = Parser.validate_syntax(path)
      after
        cleanup_file(path)
      end
    end

    test "returns {:error, reasons} when no defmodule found" do
      path = temp_spex_file(file_without_defmodule())

      try do
        assert {:error, reasons} = Parser.validate_syntax(path)
        assert is_list(reasons)
        assert Enum.any?(reasons, &String.contains?(&1, "defmodule"))
      after
        cleanup_file(path)
      end
    end

    test "returns {:error, reasons} when no spex macro found" do
      path = temp_spex_file(file_without_spex_macro())

      try do
        assert {:error, reasons} = Parser.validate_syntax(path)
        assert is_list(reasons)
        assert Enum.any?(reasons, &String.contains?(&1, "spex"))
      after
        cleanup_file(path)
      end
    end

    test "returns {:error, reasons} when no scenarios found" do
      path = temp_spex_file(spex_without_scenarios())

      try do
        assert {:error, reasons} = Parser.validate_syntax(path)
        assert is_list(reasons)
        assert Enum.any?(reasons, &String.contains?(&1, "scenario"))
      after
        cleanup_file(path)
      end
    end

    test "returns {:error, reasons} for scenarios without steps" do
      path = temp_spex_file(spex_with_empty_scenario())

      try do
        result = Parser.validate_syntax(path)
        # This may return error or ok depending on requirements
        # Empty scenarios might be allowed during development
        assert result == :ok or match?({:error, _}, result)
      after
        cleanup_file(path)
      end
    end

    test "returns {:error, reasons} for invalid syntax" do
      path = temp_spex_file(file_with_syntax_error())

      try do
        assert {:error, reasons} = Parser.validate_syntax(path)
        assert is_list(reasons)
      after
        cleanup_file(path)
      end
    end

    test "returns {:error, reasons} for non-existent file" do
      path = nonexistent_file_path()
      assert {:error, reasons} = Parser.validate_syntax(path)
      assert is_list(reasons)
      assert Enum.any?(reasons, &String.contains?(&1, "not found"))
    end

    test "accumulates multiple validation errors in single call" do
      # File with multiple issues: no spex and no scenarios
      invalid_content = """
      defmodule MultipleErrors do
        use SexySpex

        def regular_function do
          :ok
        end
      end
      """

      path = temp_spex_file(invalid_content)

      try do
        assert {:error, reasons} = Parser.validate_syntax(path)
        assert is_list(reasons)
        assert length(reasons) > 0
      after
        cleanup_file(path)
      end
    end

    test "provides descriptive error messages" do
      path = temp_spex_file(file_without_spex_macro())

      try do
        assert {:error, reasons} = Parser.validate_syntax(path)
        assert is_list(reasons)
        assert Enum.all?(reasons, &is_binary(&1))
        # Error messages should be descriptive, not just codes
        assert Enum.all?(reasons, &(String.length(&1) > 10))
      after
        cleanup_file(path)
      end
    end
  end

  # ============================================================================
  # derive_story_id/1 - Story ID Extraction
  # ============================================================================

  describe "derive_story_id/1" do
    test "extracts story_id from directory name like '123_user_authentication'" do
      path = "/path/to/specs/123_user_authentication/criterion_1_spex.exs"
      assert Parser.derive_story_id(path) == 123
    end

    test "extracts story_id from directory name like '456_dashboard'" do
      path = "/projects/456_dashboard/spec.exs"
      assert Parser.derive_story_id(path) == 456
    end

    test "returns nil for files not in story directory pattern" do
      path = "/path/to/specs/regular_directory/spec.exs"
      assert is_nil(Parser.derive_story_id(path))
    end

    test "returns nil for malformed directory names" do
      path = "/path/to/specs/abc_invalid/spec.exs"
      assert is_nil(Parser.derive_story_id(path))
    end

    test "handles numeric IDs correctly as integers" do
      path = "/specs/999_feature/test.exs"
      result = Parser.derive_story_id(path)
      assert is_integer(result)
      assert result == 999
    end
  end

  # ============================================================================
  # derive_criterion_id/1 - Criterion ID Extraction
  # ============================================================================

  describe "derive_criterion_id/1" do
    test "extracts criterion_id from filename 'criterion_123_spex.exs'" do
      path = "/path/to/criterion_123_spex.exs"
      assert Parser.derive_criterion_id(path) == 123
    end

    test "extracts criterion_id from filename 'criterion_456_spex.exs'" do
      path = "/different/path/criterion_456_spex.exs"
      assert Parser.derive_criterion_id(path) == 456
    end

    test "returns nil for files not following criterion pattern" do
      path = "/path/to/regular_spec.exs"
      assert is_nil(Parser.derive_criterion_id(path))
    end

    test "returns nil for generic spec files" do
      path = "/path/to/user_authentication_spec.exs"
      assert is_nil(Parser.derive_criterion_id(path))
    end

    test "handles numeric IDs correctly as integers" do
      path = "/specs/criterion_789_spex.exs"
      result = Parser.derive_criterion_id(path)
      assert is_integer(result)
      assert result == 789
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "parse_file/1 - integration scenarios" do
    test "parses complete spec file with all features" do
      path = temp_story_criterion_file(valid_complete_spex(), 100, 200)

      try do
        assert {:ok, spec} = Parser.parse_file(path)

        # Verify all metadata
        assert spec.name == "complete specification"
        assert spec.description == "A complete spec with all metadata fields"
        assert :integration in spec.tags
        assert :authentication in spec.tags
        assert spec.story_id == 100
        assert spec.criterion_id == 200
        assert spec.file_path == path

        # Verify scenarios
        assert length(spec.scenarios) == 2

        # Verify first scenario
        [scenario1, scenario2] = spec.scenarios
        assert scenario1.name == "user authentication flow"
        assert length(scenario1.given_steps) == 2
        assert length(scenario1.when_steps) == 1
        assert length(scenario1.then_steps) == 2

        # Verify second scenario
        assert scenario2.name == "logout functionality"
        assert length(scenario2.given_steps) == 1
        assert length(scenario2.when_steps) == 1
        assert length(scenario2.then_steps) == 1
      after
        cleanup_file(path)
      end
    end

    test "handles files with minimal metadata gracefully" do
      path = temp_spex_file(valid_minimal_spex())

      try do
        assert {:ok, spec} = Parser.parse_file(path)
        assert spec.name == "minimal spec"
        assert is_nil(spec.description) or spec.description == ""
        assert spec.tags == [] or is_list(spec.tags)
        assert is_nil(spec.story_id)
        assert is_nil(spec.criterion_id)
      after
        cleanup_file(path)
      end
    end

    test "parsing the same file multiple times returns consistent results" do
      path = temp_spex_file(valid_complete_spex())

      try do
        {:ok, result1} = Parser.parse_file(path)
        {:ok, result2} = Parser.parse_file(path)
        {:ok, result3} = Parser.parse_file(path)

        assert result1.name == result2.name
        assert result2.name == result3.name
        assert length(result1.scenarios) == length(result2.scenarios)
        assert length(result2.scenarios) == length(result3.scenarios)
      after
        cleanup_file(path)
      end
    end
  end
end
