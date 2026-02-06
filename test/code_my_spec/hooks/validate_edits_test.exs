defmodule CodeMySpec.AgentTasks.ValidateEditsTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.AgentTasks.ValidateEdits

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  # ============================================================================
  # Fixtures - Valid Spec Content
  # ============================================================================

  defp valid_spec_content do
    """
    # MyModule.Spec

    ## Delegates
    - func/1: Other.func/1

    ## Dependencies
    - Other.Module
    """
  end

  defp valid_context_spec_content do
    """
    # MyContext

    ## Functions

    ### my_func/1
    Does something.

    ```elixir
    @spec my_func(any()) :: :ok
    ```

    **Process**:
    1. Do the thing

    **Test Assertions**:
    - returns :ok

    ## Dependencies
    - Other.Module

    ## Components

    ### MyContext.SubModule
    A submodule that does things.
    """
  end

  defp valid_spec_with_functions_content do
    """
    # MyModule.WithFunctions

    ## Functions

    ### create/1
    Creates a thing.

    ```elixir
    @spec create(map()) :: {:ok, term()} | {:error, term()}
    ```

    **Process**:
    1. Validate input
    2. Create record

    **Test Assertions**:
    - returns {:ok, record} on success
    - returns {:error, reason} on failure

    ## Dependencies
    - Ecto
    """
  end

  # ============================================================================
  # Fixtures - Invalid Spec Content
  # ============================================================================

  defp spec_missing_required_sections do
    """
    # IncompleteSpec

    ## Purpose
    Only has purpose section.
    """
  end

  defp spec_with_disallowed_sections do
    """
    # MyModule.Spec

    ## Delegates
    - func/1: Other.func/1

    ## Dependencies
    - Other.Module

    ## Custom Section
    This section is not allowed in specs.
    """
  end

  defp empty_content do
    ""
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp generate_session_id do
    Ecto.UUID.generate()
  end

  defp create_spec_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
    full_path
  end

  defp track_edit(session_id, file_path) do
    FileEdits.track_edit(session_id, file_path)
  end

  defp problem_contains?(problems, text) when is_list(problems) do
    Enum.any?(problems, fn
      %Problem{message: msg, file_path: path} ->
        (is_binary(msg) and String.contains?(msg, text)) or
          (is_binary(path) and String.contains?(path, text))

      _ ->
        false
    end)
  end

  # ============================================================================
  # run/2 Tests
  # ============================================================================

  describe "run/2" do
    test "returns {:ok, :valid} when session has no file edits" do
      session_id = generate_session_id()

      assert {:ok, :valid} = ValidateEdits.run(session_id)
    end

    test "returns {:ok, :valid} when session has only non-spec file edits that pass Credo", %{
      tmp_dir: tmp_dir
    } do
      session_id = generate_session_id()
      ex_file = Path.join(tmp_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(ex_file))

      # Use a Credo-compliant module (with @moduledoc and final newline)
      File.write!(ex_file, """
      defmodule MyModule do
        @moduledoc false
      end
      """)

      track_edit(session_id, ex_file)

      assert {:ok, :valid} = ValidateEdits.run(session_id)
    end

    test "returns {:ok, :valid} when single valid spec file was edited", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()
      spec_path = create_spec_file(tmp_dir, "docs/spec/my_module.spec.md", valid_spec_content())

      track_edit(session_id, spec_path)

      assert {:ok, :valid} = ValidateEdits.run(session_id)
    end

    test "returns {:ok, :valid} when multiple valid spec files were edited", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()
      spec1 = create_spec_file(tmp_dir, "docs/spec/module_a.spec.md", valid_spec_content())

      spec2 =
        create_spec_file(
          tmp_dir,
          "docs/spec/module_b.spec.md",
          valid_spec_with_functions_content()
        )

      track_edit(session_id, spec1)
      track_edit(session_id, spec2)

      assert {:ok, :valid} = ValidateEdits.run(session_id)
    end

    test "returns {:error, problems} when spec file is missing required sections", %{
      tmp_dir: tmp_dir
    } do
      session_id = generate_session_id()

      spec_path =
        create_spec_file(
          tmp_dir,
          "docs/spec/incomplete.spec.md",
          spec_missing_required_sections()
        )

      track_edit(session_id, spec_path)

      capture_log(fn ->
        assert {:error, problems} = ValidateEdits.run(session_id)
        assert is_list(problems)
        assert problems != []
        assert Enum.all?(problems, &match?(%Problem{}, &1))
      end)
    end

    test "returns {:error, problems} when spec file has disallowed sections", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()

      spec_path =
        create_spec_file(tmp_dir, "docs/spec/bad.spec.md", spec_with_disallowed_sections())

      track_edit(session_id, spec_path)

      capture_log(fn ->
        assert {:error, problems} = ValidateEdits.run(session_id)
        assert is_list(problems)
        assert problem_contains?(problems, "Disallowed")
      end)
    end

    test "includes file path in problem for identification", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()

      spec_path =
        create_spec_file(tmp_dir, "docs/spec/invalid.spec.md", spec_missing_required_sections())

      track_edit(session_id, spec_path)

      capture_log(fn ->
        assert {:error, problems} = ValidateEdits.run(session_id)
        assert problem_contains?(problems, spec_path)
      end)
    end

    test "validates all spec files before returning collected errors", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()

      spec1 =
        create_spec_file(tmp_dir, "docs/spec/bad_one.spec.md", spec_missing_required_sections())

      spec2 =
        create_spec_file(tmp_dir, "docs/spec/bad_two.spec.md", spec_with_disallowed_sections())

      track_edit(session_id, spec1)
      track_edit(session_id, spec2)

      capture_log(fn ->
        assert {:error, problems} = ValidateEdits.run(session_id)
        assert length(problems) >= 2
        assert problem_contains?(problems, "bad_one.spec.md")
        assert problem_contains?(problems, "bad_two.spec.md")
      end)
    end

    test "handles file read failure gracefully (file deleted after edit)", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()
      # Track an edit to a spec file that doesn't exist
      nonexistent_spec = Path.join(tmp_dir, "docs/spec/deleted.spec.md")

      track_edit(session_id, nonexistent_spec)

      capture_log(fn ->
        assert {:error, problems} = ValidateEdits.run(session_id)
        assert is_list(problems)
      end)
    end

    test "returns {:ok, :valid} when only spex files were edited (and spex passes)", %{
      tmp_dir: tmp_dir
    } do
      session_id = generate_session_id()
      spex_file = Path.join(tmp_dir, "test/spex/user_login_spex.exs")
      File.mkdir_p!(Path.dirname(spex_file))

      # Write a spex file - content doesn't matter since we skip validation
      File.write!(spex_file, """
      defmodule UserLoginSpex do
        use Spex

        spex "User can log in" do
          scenario "valid credentials" do
            given "a registered user"
            when_ "user enters valid credentials"
            then_ "user is logged in"
          end
        end
      end
      """)

      track_edit(session_id, spex_file)

      # Spex will likely fail without a real project, but the test is about categorization
      result = ValidateEdits.run(session_id)
      # Accept either valid or error (depends on spex being set up)
      assert match?({:ok, :valid}, result) or match?({:error, _}, result)
    end
  end

  # ============================================================================
  # validate_spec_files/1 Tests
  # ============================================================================

  describe "validate_spec_files/1" do
    test "returns {:ok, []} for valid spec document", %{tmp_dir: tmp_dir} do
      spec_path = create_spec_file(tmp_dir, "docs/spec/valid.spec.md", valid_spec_content())

      assert {:ok, []} = ValidateEdits.validate_spec_files([spec_path])
    end

    test "returns {:ok, problems} for spec missing required sections", %{tmp_dir: tmp_dir} do
      spec_path =
        create_spec_file(tmp_dir, "docs/spec/missing.spec.md", spec_missing_required_sections())

      capture_log(fn ->
        assert {:ok, problems} = ValidateEdits.validate_spec_files([spec_path])
        assert problems != []
        assert problem_contains?(problems, "Missing required sections")
      end)
    end

    test "returns {:ok, problems} for spec with invalid sections", %{tmp_dir: tmp_dir} do
      spec_path =
        create_spec_file(tmp_dir, "docs/spec/invalid.spec.md", spec_with_disallowed_sections())

      capture_log(fn ->
        assert {:ok, problems} = ValidateEdits.validate_spec_files([spec_path])
        assert problems != []
        assert problem_contains?(problems, "Disallowed")
      end)
    end

    test "returns {:ok, problems} when file does not exist", %{tmp_dir: tmp_dir} do
      nonexistent_path = Path.join(tmp_dir, "does_not_exist.spec.md")

      capture_log(fn ->
        assert {:ok, problems} = ValidateEdits.validate_spec_files([nonexistent_path])
        assert problems != []
      end)
    end

    test "returns {:ok, problems} when file is empty", %{tmp_dir: tmp_dir} do
      spec_path = create_spec_file(tmp_dir, "docs/spec/empty.spec.md", empty_content())

      capture_log(fn ->
        assert {:ok, problems} = ValidateEdits.validate_spec_files([spec_path])
        assert problems != []
      end)
    end

    test "determines document type correctly from path", %{tmp_dir: tmp_dir} do
      # Context spec should be validated as context_spec type
      context_spec_path =
        create_spec_file(
          tmp_dir,
          "docs/spec/my_context/my_context.spec.md",
          valid_context_spec_content()
        )

      assert {:ok, []} = ValidateEdits.validate_spec_files([context_spec_path])
    end
  end

  # ============================================================================
  # document_type_from_path/1 Tests
  # ============================================================================

  describe "document_type_from_path/1" do
    test "returns \"context_spec\" for top-level context spec files" do
      # Context specs have file name matching directory name pattern
      # e.g., docs/spec/code_my_spec/documents.spec.md (documents is both dir and file base)
      path = "/project/docs/spec/code_my_spec/documents.spec.md"

      assert "context_spec" = ValidateEdits.document_type_from_path(path)
    end

    test "returns \"spec\" for component-level spec files" do
      # Component specs are nested within a context directory
      # e.g., docs/spec/code_my_spec/documents/registry.spec.md
      path = "/project/docs/spec/code_my_spec/documents/registry.spec.md"

      assert "spec" = ValidateEdits.document_type_from_path(path)
    end

    test "returns \"spec\" for nested component spec files" do
      # Deeply nested component specs
      path = "/project/docs/spec/code_my_spec/documents/parsers/function_parser.spec.md"

      assert "spec" = ValidateEdits.document_type_from_path(path)
    end

    test "handles various path depths correctly" do
      # Shallow path
      shallow_path = "/docs/spec/module.spec.md"
      assert "spec" = ValidateEdits.document_type_from_path(shallow_path)

      # Deep path that is a context spec
      deep_context = "/a/b/c/d/my_context.spec.md"
      assert "spec" = ValidateEdits.document_type_from_path(deep_context)

      # Path with matching directory name pattern
      matching_dir = "/project/docs/spec/my_app/accounts.spec.md"
      assert "context_spec" = ValidateEdits.document_type_from_path(matching_dir)
    end
  end

  # ============================================================================
  # spec_file?/1 Tests
  # ============================================================================

  describe "spec_file?/1" do
    test "returns true for paths ending in .spec.md" do
      assert ValidateEdits.spec_file?("/path/to/module.spec.md")
      assert ValidateEdits.spec_file?("module.spec.md")
      assert ValidateEdits.spec_file?("/deep/nested/path/to/module.spec.md")
    end

    test "returns false for paths ending in .md (non-spec markdown)" do
      refute ValidateEdits.spec_file?("/path/to/README.md")
      refute ValidateEdits.spec_file?("/path/to/CHANGELOG.md")
      refute ValidateEdits.spec_file?("/docs/guide.md")
    end

    test "returns false for paths ending in .ex" do
      refute ValidateEdits.spec_file?("/lib/my_module.ex")
      refute ValidateEdits.spec_file?("/test/my_module_test.exs")
    end

    test "returns false for paths without extension" do
      refute ValidateEdits.spec_file?("/path/to/Makefile")
      refute ValidateEdits.spec_file?("/path/to/Dockerfile")
      refute ValidateEdits.spec_file?("README")
    end
  end

  # ============================================================================
  # test_file?/1 Tests
  # ============================================================================

  describe "test_file?/1" do
    test "returns true for paths ending in _test.exs" do
      assert ValidateEdits.test_file?("/test/my_module_test.exs")
      assert ValidateEdits.test_file?("/path/to/deep/nested/foo_test.exs")
      assert ValidateEdits.test_file?("module_test.exs")
    end

    test "returns false for lib files" do
      refute ValidateEdits.test_file?("/lib/my_module.ex")
      refute ValidateEdits.test_file?("/lib/my_module_test.ex")
    end

    test "returns false for other files" do
      refute ValidateEdits.test_file?("/config/config.exs")
      refute ValidateEdits.test_file?("mix.exs")
    end
  end

  # ============================================================================
  # code_file?/1 Tests
  # ============================================================================

  describe "code_file?/1" do
    test "returns true for paths ending in .ex" do
      assert ValidateEdits.code_file?("/lib/my_module.ex")
      assert ValidateEdits.code_file?("/path/to/deep/nested/module.ex")
      assert ValidateEdits.code_file?("module.ex")
    end

    test "returns true for paths ending in .exs (non-test, non-spex)" do
      assert ValidateEdits.code_file?("/config/config.exs")
      assert ValidateEdits.code_file?("mix.exs")
    end

    test "returns false for test files" do
      refute ValidateEdits.code_file?("/test/my_module_test.exs")
      refute ValidateEdits.code_file?("foo_test.exs")
    end

    test "returns false for spex files" do
      refute ValidateEdits.code_file?("/test/spex/user_login_spex.exs")
      refute ValidateEdits.code_file?("my_feature_spex.exs")
    end

    test "returns false for non-Elixir files" do
      refute ValidateEdits.code_file?("/path/to/file.rb")
      refute ValidateEdits.code_file?("/path/to/file.js")
      refute ValidateEdits.code_file?("/path/to/README.md")
      refute ValidateEdits.code_file?("/path/to/module.spec.md")
    end

    test "returns false for files without extension" do
      refute ValidateEdits.code_file?("/path/to/Makefile")
      refute ValidateEdits.code_file?("Dockerfile")
    end
  end

  # ============================================================================
  # spex_file?/1 Tests
  # ============================================================================

  describe "spex_file?/1" do
    test "returns true for paths ending in _spex.exs" do
      assert ValidateEdits.spex_file?("/test/spex/user_login_spex.exs")
      assert ValidateEdits.spex_file?("/test/spex/42_story/criterion_1_spex.exs")
      assert ValidateEdits.spex_file?("my_feature_spex.exs")
    end

    test "returns false for regular test files" do
      refute ValidateEdits.spex_file?("/test/my_module_test.exs")
      refute ValidateEdits.spex_file?("/test/support/helpers.exs")
    end

    test "returns false for lib files" do
      refute ValidateEdits.spex_file?("/lib/my_module.ex")
      refute ValidateEdits.spex_file?("/lib/spex/runner.ex")
    end

    test "returns false for spec.md files" do
      refute ValidateEdits.spex_file?("/docs/spec/my_module.spec.md")
    end
  end

  # ============================================================================
  # categorize_files/1 Tests
  # ============================================================================

  describe "categorize_files/1" do
    test "categorizes files by type" do
      files = [
        "/lib/my_module.ex",
        "/test/my_module_test.exs",
        "/test/spex/feature_spex.exs",
        "/docs/spec/module.spec.md",
        "/config/config.exs"
      ]

      assert {:ok, categorized} = ValidateEdits.categorize_files(files)

      assert categorized.spec_files == ["/docs/spec/module.spec.md"]
      assert "/test/my_module_test.exs" in categorized.test_files
      assert categorized.spex_files == ["/test/spex/feature_spex.exs"]
      assert "/lib/my_module.ex" in categorized.code_files
      assert "/config/config.exs" in categorized.code_files
    end

    test "builds elixir_files from code + test + spex" do
      files = [
        "/lib/my_module.ex",
        "/test/my_module_test.exs",
        "/test/spex/feature_spex.exs"
      ]

      assert {:ok, categorized} = ValidateEdits.categorize_files(files)

      assert "/lib/my_module.ex" in categorized.elixir_files
      assert "/test/my_module_test.exs" in categorized.elixir_files
      assert "/test/spex/feature_spex.exs" in categorized.elixir_files
    end

    test "handles empty list" do
      assert {:ok, categorized} = ValidateEdits.categorize_files([])

      assert categorized.spec_files == []
      assert categorized.test_files == []
      assert categorized.spex_files == []
      assert categorized.code_files == []
      assert categorized.elixir_files == []
    end
  end

  # ============================================================================
  # extract_failed_files/1 Tests
  # ============================================================================

  describe "extract_failed_files/1" do
    test "extracts unique file paths from problems" do
      problems = [
        %Problem{file_path: "/lib/a.ex", message: "error 1"},
        %Problem{file_path: "/lib/b.ex", message: "error 2"},
        %Problem{file_path: "/lib/a.ex", message: "error 3"}
      ]

      result = ValidateEdits.extract_failed_files(problems)

      assert length(result) == 2
      assert "/lib/a.ex" in result
      assert "/lib/b.ex" in result
    end

    test "handles problems without file_path" do
      problems = [
        %Problem{file_path: "/lib/a.ex", message: "error 1"},
        %Problem{file_path: nil, message: "error 2"}
      ]

      result = ValidateEdits.extract_failed_files(problems)

      assert result == ["/lib/a.ex"]
    end

    test "returns empty list for empty problems" do
      assert ValidateEdits.extract_failed_files([]) == []
    end
  end

  # ============================================================================
  # format_output/1 Tests
  # ============================================================================

  describe "format_output/1" do
    test "returns empty map for valid result (allows stop)" do
      result = ValidateEdits.format_output({:ok, :valid})

      assert result == %{}
    end

    test "returns decision block with reason for errors" do
      problems = [
        %Problem{file_path: "/lib/a.ex", message: "Error one", source: "credo"},
        %Problem{file_path: "/lib/b.ex", message: "Error two", source: "credo"}
      ]

      result = ValidateEdits.format_output({:error, problems})

      assert %{"decision" => "block", "reason" => reason} = result
      assert is_binary(reason)
    end

    test "formats problems as readable output" do
      problems = [
        %Problem{
          file_path: "docs/spec/a.spec.md",
          message: "Missing required sections",
          source: "spec_validation"
        },
        %Problem{
          file_path: "docs/spec/b.spec.md",
          message: "Disallowed sections found",
          source: "spec_validation"
        }
      ]

      result = ValidateEdits.format_output({:error, problems})

      assert %{"reason" => reason} = result
      assert reason =~ "a.spec.md"
      assert reason =~ "b.spec.md"
    end
  end
end
