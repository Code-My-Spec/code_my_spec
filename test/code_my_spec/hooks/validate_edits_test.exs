defmodule CodeMySpec.Sessions.AgentTasks.ValidateEditsTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Sessions.AgentTasks.ValidateEdits

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

  # ============================================================================
  # run/1 Tests
  # ============================================================================

  describe "run/1" do
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

    test "returns {:error, [errors]} when spec file is missing required sections", %{
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
        assert {:error, errors} = ValidateEdits.run(session_id)
        assert is_list(errors)
        assert length(errors) > 0
      end)
    end

    test "returns {:error, [errors]} when spec file has disallowed sections", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()

      spec_path =
        create_spec_file(tmp_dir, "docs/spec/bad.spec.md", spec_with_disallowed_sections())

      track_edit(session_id, spec_path)

      capture_log(fn ->
        assert {:error, errors} = ValidateEdits.run(session_id)
        assert is_list(errors)
        assert Enum.any?(errors, &String.contains?(&1, "Disallowed"))
      end)
    end

    test "includes file path in error message for identification", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()

      spec_path =
        create_spec_file(tmp_dir, "docs/spec/invalid.spec.md", spec_missing_required_sections())

      track_edit(session_id, spec_path)

      capture_log(fn ->
        assert {:error, errors} = ValidateEdits.run(session_id)
        assert Enum.any?(errors, &String.contains?(&1, spec_path))
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
        assert {:error, errors} = ValidateEdits.run(session_id)
        assert length(errors) >= 2
        assert Enum.any?(errors, &String.contains?(&1, "bad_one.spec.md"))
        assert Enum.any?(errors, &String.contains?(&1, "bad_two.spec.md"))
      end)
    end

    test "handles file read failure gracefully (file deleted after edit)", %{tmp_dir: tmp_dir} do
      session_id = generate_session_id()
      # Track an edit to a spec file that doesn't exist
      nonexistent_spec = Path.join(tmp_dir, "docs/spec/deleted.spec.md")

      track_edit(session_id, nonexistent_spec)

      capture_log(fn ->
        assert {:error, errors} = ValidateEdits.run(session_id)
        assert is_list(errors)
      end)
    end

    test "returns {:ok, :valid} when only spex files were edited (not validated yet)", %{
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

      assert {:ok, :valid} = ValidateEdits.run(session_id)
    end
  end

  # ============================================================================
  # validate_spec_file/1 Tests
  # ============================================================================

  describe "validate_spec_file/1" do
    test "returns :ok for valid spec document", %{tmp_dir: tmp_dir} do
      spec_path = create_spec_file(tmp_dir, "docs/spec/valid.spec.md", valid_spec_content())

      assert :ok = ValidateEdits.validate_spec_file(spec_path)
    end

    test "returns {:error, reason} for spec missing required sections", %{tmp_dir: tmp_dir} do
      spec_path =
        create_spec_file(tmp_dir, "docs/spec/missing.spec.md", spec_missing_required_sections())

      capture_log(fn ->
        assert {:error, reason} = ValidateEdits.validate_spec_file(spec_path)
        assert is_binary(reason)
        assert reason =~ "Missing required sections"
      end)
    end

    test "returns {:error, reason} for spec with invalid sections", %{tmp_dir: tmp_dir} do
      spec_path =
        create_spec_file(tmp_dir, "docs/spec/invalid.spec.md", spec_with_disallowed_sections())

      capture_log(fn ->
        assert {:error, reason} = ValidateEdits.validate_spec_file(spec_path)
        assert is_binary(reason)
        assert reason =~ "Disallowed"
      end)
    end

    test "returns {:error, reason} when file does not exist", %{tmp_dir: tmp_dir} do
      nonexistent_path = Path.join(tmp_dir, "does_not_exist.spec.md")

      capture_log(fn ->
        assert {:error, reason} = ValidateEdits.validate_spec_file(nonexistent_path)
        assert is_binary(reason)
      end)
    end

    test "returns {:error, reason} when file is empty", %{tmp_dir: tmp_dir} do
      spec_path = create_spec_file(tmp_dir, "docs/spec/empty.spec.md", empty_content())

      capture_log(fn ->
        assert {:error, reason} = ValidateEdits.validate_spec_file(spec_path)
        assert is_binary(reason)
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

      assert :ok = ValidateEdits.validate_spec_file(context_spec_path)
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

    test "returns true for paths in test directory" do
      assert ValidateEdits.test_file?("/test/my_module.exs")
      assert ValidateEdits.test_file?("/project/test/support/helpers.ex")
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
  # elixir_file?/1 Tests
  # ============================================================================

  describe "elixir_file?/1" do
    test "returns true for paths ending in .ex" do
      assert ValidateEdits.elixir_file?("/lib/my_module.ex")
      assert ValidateEdits.elixir_file?("/path/to/deep/nested/module.ex")
      assert ValidateEdits.elixir_file?("module.ex")
    end

    test "returns true for paths ending in .exs" do
      assert ValidateEdits.elixir_file?("/test/my_module_test.exs")
      assert ValidateEdits.elixir_file?("/config/config.exs")
      assert ValidateEdits.elixir_file?("mix.exs")
    end

    test "returns false for non-Elixir files" do
      refute ValidateEdits.elixir_file?("/path/to/file.rb")
      refute ValidateEdits.elixir_file?("/path/to/file.js")
      refute ValidateEdits.elixir_file?("/path/to/README.md")
      refute ValidateEdits.elixir_file?("/path/to/module.spec.md")
    end

    test "returns false for files without extension" do
      refute ValidateEdits.elixir_file?("/path/to/Makefile")
      refute ValidateEdits.elixir_file?("Dockerfile")
    end

    test "returns false for spex files (BDD specs)" do
      refute ValidateEdits.elixir_file?("/test/spex/user_login_spex.exs")
      refute ValidateEdits.elixir_file?("/test/spex/42_story/criterion_1_spex.exs")
      refute ValidateEdits.elixir_file?("my_feature_spex.exs")
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
  # format_output/1 Tests
  # ============================================================================

  describe "format_output/1" do
    test "returns empty map for valid result (allows stop)" do
      result = ValidateEdits.format_output({:ok, :valid})

      assert result == %{}
    end

    test "returns decision block with reason for errors" do
      result = ValidateEdits.format_output({:error, ["Error one", "Error two"]})

      assert %{"decision" => "block", "reason" => reason} = result
      assert is_binary(reason)
    end

    test "formats multiple errors as readable list in reason" do
      errors = [
        "docs/spec/a.spec.md: Missing required sections",
        "docs/spec/b.spec.md: Disallowed sections found"
      ]

      result = ValidateEdits.format_output({:error, errors})

      assert %{"reason" => reason} = result
      assert reason =~ "a.spec.md"
      assert reason =~ "b.spec.md"
    end

    test "single error returns concise message" do
      result = ValidateEdits.format_output({:error, ["Single validation error"]})

      assert %{"reason" => reason} = result
      assert reason =~ "Single validation error"
    end
  end
end
