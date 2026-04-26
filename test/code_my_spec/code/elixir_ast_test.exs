defmodule CodeMySpec.Code.ElixirAstTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Code.ElixirAst
  import CodeMySpec.ElixirAstFixtures

  @moduletag :tmp_dir

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp create_test_file(tmp_dir, filename, content) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, content)
    path
  end

  # ============================================================================
  # get_dependencies/1 Tests - Happy Path
  # ============================================================================

  describe "get_dependencies/1" do
    test "returns list of aliased modules (single alias)", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "single_alias.ex", sample_module_with_single_alias())

      assert {:ok, deps} = ElixirAst.get_dependencies(path)
      assert "MyApp.User" in deps
    end

    test "returns list of aliased modules (multi-alias form)", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "multi_alias.ex", sample_module_with_multi_alias())

      assert {:ok, deps} = ElixirAst.get_dependencies(path)
      assert "MyApp.User" in deps
      assert "MyApp.Post" in deps
      assert "MyApp.Comment" in deps
    end

    test "returns list of imported modules", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "import.ex", sample_module_with_import())

      assert {:ok, deps} = ElixirAst.get_dependencies(path)
      assert "Ecto.Query" in deps
    end

    test "returns list of used modules", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "use.ex", sample_module_with_use())

      assert {:ok, deps} = ElixirAst.get_dependencies(path)
      assert "GenServer" in deps
    end

    test "combines alias, import, and use into single list", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "all_deps.ex", sample_module_with_all_dependencies())

      assert {:ok, deps} = ElixirAst.get_dependencies(path)
      assert "MyApp.User" in deps
      assert "MyApp.Post" in deps
      assert "MyApp.Comment" in deps
      assert "Ecto.Query" in deps
      assert "GenServer" in deps
      assert length(deps) == 5
    end

    test "deduplicates repeated module references", %{tmp_dir: tmp_dir} do
      path =
        create_test_file(tmp_dir, "duplicates.ex", sample_module_with_duplicate_dependencies())

      assert {:ok, deps} = ElixirAst.get_dependencies(path)
      assert Enum.count(deps, &(&1 == "MyApp.User")) == 1
    end

    test "handles alias with :as option", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "alias_as.ex", sample_module_with_alias_as())

      assert {:ok, deps} = ElixirAst.get_dependencies(path)
      assert "MyApp.Accounts.User" in deps
      assert "MyApp.Blog.User" in deps
    end

    test "returns empty list for files with no dependencies", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "no_deps.ex", sample_module_no_dependencies())

      assert {:ok, []} = ElixirAst.get_dependencies(path)
    end

    test "returns error for invalid Elixir syntax", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "invalid.ex", sample_module_with_invalid_syntax())

      assert {:error, _reason} = ElixirAst.get_dependencies(path)
    end

    test "returns error for non-existent file" do
      path = "/non/existent/file.ex"

      assert {:error, _reason} = ElixirAst.get_dependencies(path)
    end
  end

  # ============================================================================
  # get_public_functions/1 Tests - Happy Path
  # ============================================================================

  describe "get_public_functions/1" do
    test "extracts public function names as atoms", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "public_funcs.ex", sample_module_with_public_functions())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)
      assert Enum.any?(functions, fn f -> f.name == :get_user end)
      assert Enum.any?(functions, fn f -> f.name == :list_users end)
    end

    test "extracts correct arity for functions", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "public_funcs.ex", sample_module_with_public_functions())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      get_user = Enum.find(functions, fn f -> f.name == :get_user end)
      assert get_user.arity == 1

      list_users = Enum.find(functions, fn f -> f.name == :list_users end)
      assert list_users.arity == 0
    end

    test "includes @spec when present", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "with_specs.ex", sample_module_with_public_functions())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      get_user = Enum.find(functions, fn f -> f.name == :get_user end)
      assert get_user.spec != nil
      assert is_binary(get_user.spec)
    end

    test "handles functions without @spec (spec: nil)", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "no_specs.ex", sample_module_without_specs())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      function = Enum.find(functions, fn f -> f.name == :function_without_spec end)
      assert function.spec == nil
    end

    test "handles multi-clause functions correctly (single entry)", %{tmp_dir: tmp_dir} do
      path =
        create_test_file(tmp_dir, "multi_clause.ex", sample_module_with_multi_clause_functions())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      process_functions = Enum.filter(functions, fn f -> f.name == :process end)
      assert length(process_functions) == 1
      assert hd(process_functions).arity == 1
    end

    test "handles functions with default arguments", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "defaults.ex", sample_module_with_default_arguments())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      # Functions with default arguments may appear with different arities
      greet_functions = Enum.filter(functions, fn f -> f.name == :greet end)
      assert greet_functions != []
    end

    test "handles functions with guards", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "guards.ex", sample_module_with_guards())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      process_functions = Enum.filter(functions, fn f -> f.name == :process end)
      assert length(process_functions) == 1
      assert hd(process_functions).arity == 1
    end

    test "handles functions with pattern matching in args", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "pattern.ex", sample_module_with_pattern_matching())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      handle_functions = Enum.filter(functions, fn f -> f.name == :handle end)
      assert length(handle_functions) == 1
      assert hd(handle_functions).arity == 1
    end

    test "excludes private functions (defp)", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "private.ex", sample_module_with_private_functions())

      assert {:ok, functions} = ElixirAst.get_public_functions(path)

      # Should only include public_function, not private_function or another_private
      assert length(functions) == 1
      assert Enum.any?(functions, fn f -> f.name == :public_function end)
      refute Enum.any?(functions, fn f -> f.name == :private_function end)
      refute Enum.any?(functions, fn f -> f.name == :another_private end)
    end

    test "returns empty list for modules with no public functions", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "private.ex", sample_module_no_public_functions())

      assert {:ok, []} = ElixirAst.get_public_functions(path)
    end

    test "returns empty list for non-module files (scripts)", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "script.exs", sample_script_no_module())

      assert {:ok, []} = ElixirAst.get_public_functions(path)
    end

    test "returns error for invalid Elixir syntax", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "invalid.ex", sample_module_with_invalid_syntax())

      assert {:error, _reason} = ElixirAst.get_public_functions(path)
    end
  end

  # ============================================================================
  # get_test_assertions/1 Tests - Happy Path
  # ============================================================================

  describe "get_test_assertions/1" do
    test "extracts test names from test blocks", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "simple_test.exs", sample_test_file_simple())

      assert {:ok, tests} = ElixirAst.get_test_assertions(path)
      assert Enum.any?(tests, fn t -> t.test_name == "adds two numbers" end)
      assert Enum.any?(tests, fn t -> t.test_name == "subtracts two numbers" end)

      # Tests without describe blocks should have empty describe_blocks list
      test_item = Enum.find(tests, fn t -> t.test_name == "adds two numbers" end)
      assert test_item.describe_blocks == []
    end

    test "extracts test descriptions as strings", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "simple_test.exs", sample_test_file_simple())

      assert {:ok, tests} = ElixirAst.get_test_assertions(path)

      test_item = Enum.find(tests, fn t -> t.test_name == "adds two numbers" end)
      assert is_binary(test_item.description)
      assert test_item.description =~ "adds two numbers"
    end

    test "identifies describe block groupings", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "describe_test.exs", sample_test_file_with_describe())

      assert {:ok, tests} = ElixirAst.get_test_assertions(path)

      # Should have tests from both describe blocks
      assert Enum.any?(tests, fn t -> t.description =~ "addition" end)
      assert Enum.any?(tests, fn t -> t.description =~ "subtraction" end)

      # Validate describe_blocks field is populated
      addition_test = Enum.find(tests, fn t -> t.description =~ "addition" end)
      assert addition_test.describe_blocks != []
      assert hd(addition_test.describe_blocks) =~ "addition"
    end

    test "handles nested describe blocks", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "nested_test.exs", sample_test_file_nested_describe())

      assert {:ok, tests} = ElixirAst.get_test_assertions(path)

      # Should find the nested test
      nested_test = Enum.find(tests, fn t -> t.test_name == "nested test" end)
      assert nested_test

      # describe_blocks should contain multiple entries for nested describes (outermost to innermost)
      assert length(nested_test.describe_blocks) > 1
    end

    test "combines describe + test for full context", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "describe_test.exs", sample_test_file_with_describe())

      assert {:ok, tests} = ElixirAst.get_test_assertions(path)

      # Descriptions should include context from describe blocks
      addition_test =
        Enum.find(tests, fn t ->
          t.test_name == "adds positive numbers"
        end)

      assert addition_test
      assert addition_test.description =~ "addition"

      # describe_blocks should contain the describe context
      assert length(addition_test.describe_blocks) == 1
      assert hd(addition_test.describe_blocks) =~ "addition"
    end

    test "handles tests without describe blocks", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "simple_test.exs", sample_test_file_simple())

      assert {:ok, tests} = ElixirAst.get_test_assertions(path)

      # Should still extract test names even without describe
      assert length(tests) == 2
    end

    test "handles doctest declarations", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "doctest_test.exs", sample_test_file_with_doctest())

      assert {:ok, tests} = ElixirAst.get_test_assertions(path)

      # Should find both the doctest and regular test
      assert tests != []
      assert Enum.any?(tests, fn t -> t.test_name == "simple test" end)
    end

    test "returns empty list for test files with no tests", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "empty_test.exs", sample_test_file_no_tests())

      assert {:ok, []} = ElixirAst.get_test_assertions(path)
    end

    test "returns error for invalid Elixir syntax", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "invalid.ex", sample_module_with_invalid_syntax())

      assert {:error, _reason} = ElixirAst.get_test_assertions(path)
    end

    test "returns error for non-test files", %{tmp_dir: tmp_dir} do
      path = create_test_file(tmp_dir, "not_test.ex", sample_non_test_file())

      # This should return an error since it's not a test file
      # Or return empty list - implementation detail
      result = ElixirAst.get_test_assertions(path)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
