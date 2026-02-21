defmodule CodeMySpec.Requirements.SpecTestAlignmentCheckerTest do
  @moduledoc false
  use CodeMySpec.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Requirements.SpecTestAlignmentChecker

  @moduletag :tmp_dir

  @requirement_definition %RequirementDefinition{
    name: "test_spec_alignment",
    artifact_type: :tests,
    description: "Test file implements all spec test assertions",
    checker: SpecTestAlignmentChecker,
    satisfied_by: CodeMySpec.AgentTasks.ComponentTest
  }

  defp setup_scope(%{tmp_dir: tmp_dir}) do
    scope = full_scope_fixture()
    scope = %{scope | cwd: tmp_dir}
    %{scope: scope}
  end

  defp write_spec_file(tmp_dir, module_name, content) do
    relative_path =
      module_name |> String.split(".") |> Enum.map(&Macro.underscore/1) |> Path.join()

    spec_path = Path.join([tmp_dir, "docs", "spec", "#{relative_path}.spec.md"])
    File.mkdir_p!(Path.dirname(spec_path))
    File.write!(spec_path, content)
    spec_path
  end

  defp write_impl_file(tmp_dir, module_name, content) do
    relative_path =
      module_name |> String.split(".") |> Enum.map(&Macro.underscore/1) |> Path.join()

    impl_path = Path.join([tmp_dir, "lib", "#{relative_path}.ex"])
    File.mkdir_p!(Path.dirname(impl_path))
    File.write!(impl_path, content)
    impl_path
  end

  defp write_test_file(tmp_dir, module_name, content) do
    relative_path =
      module_name |> String.split(".") |> Enum.map(&Macro.underscore/1) |> Path.join()

    test_path = Path.join([tmp_dir, "test", "#{relative_path}_test.exs"])
    File.mkdir_p!(Path.dirname(test_path))
    File.write!(test_path, content)
    test_path
  end

  describe "check/4" do
    setup [:setup_scope]

    test "returns satisfied when spec assertions match test file", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      module_name = "TestApp.Aligned"
      component = %Component{module_name: module_name, type: "module"}

      write_spec_file(tmp_dir, module_name, """
      # #{module_name}

      ## Functions

      ### greet/1

      Greets a user.

      ```elixir
      @spec greet(String.t()) :: String.t()
      ```

      **Test Assertions**:
      - returns greeting with name
      - handles empty string
      """)

      write_impl_file(tmp_dir, module_name, """
      defmodule #{module_name} do
        @spec greet(String.t()) :: String.t()
        def greet(name), do: "Hello, \#{name}!"
      end
      """)

      write_test_file(tmp_dir, module_name, """
      defmodule #{module_name}Test do
        use ExUnit.Case

        describe "greet/1" do
          test "returns greeting with name" do
            assert #{module_name}.greet("World") == "Hello, World!"
          end

          test "handles empty string" do
            assert #{module_name}.greet("") == "Hello, !"
          end
        end
      end
      """)

      result = SpecTestAlignmentChecker.check(scope, @requirement_definition, component)

      assert result.satisfied == true
      assert result.name == "test_spec_alignment"
      assert result.artifact_type == :tests
    end

    test "returns unsatisfied when tests are missing", %{scope: scope, tmp_dir: tmp_dir} do
      module_name = "TestApp.MissingTests"
      component = %Component{module_name: module_name, type: "module"}

      write_spec_file(tmp_dir, module_name, """
      # #{module_name}

      ## Functions

      ### compute/1

      Computes something.

      ```elixir
      @spec compute(integer()) :: integer()
      ```

      **Test Assertions**:
      - returns computed value
      - handles negative numbers
      - handles zero
      """)

      write_impl_file(tmp_dir, module_name, """
      defmodule #{module_name} do
        @spec compute(integer()) :: integer()
        def compute(n), do: n * 2
      end
      """)

      write_test_file(tmp_dir, module_name, """
      defmodule #{module_name}Test do
        use ExUnit.Case

        describe "compute/1" do
          test "returns computed value" do
            assert #{module_name}.compute(5) == 10
          end
        end
      end
      """)

      result = SpecTestAlignmentChecker.check(scope, @requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason == "Test alignment issues"
      assert is_list(result.details.problems)
      assert result.details.problems != []
    end

    test "returns unsatisfied when extra tests exist", %{scope: scope, tmp_dir: tmp_dir} do
      module_name = "TestApp.ExtraTests"
      component = %Component{module_name: module_name, type: "module"}

      write_spec_file(tmp_dir, module_name, """
      # #{module_name}

      ## Functions

      ### hello/0

      Says hello.

      ```elixir
      @spec hello() :: String.t()
      ```

      **Test Assertions**:
      - returns hello string
      """)

      write_impl_file(tmp_dir, module_name, """
      defmodule #{module_name} do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """)

      write_test_file(tmp_dir, module_name, """
      defmodule #{module_name}Test do
        use ExUnit.Case

        describe "hello/0" do
          test "returns hello string" do
            assert #{module_name}.hello() == "hello"
          end

          test "extra test not in spec" do
            assert is_binary(#{module_name}.hello())
          end
        end
      end
      """)

      result = SpecTestAlignmentChecker.check(scope, @requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason == "Test alignment issues"
      assert Enum.any?(result.details.problems, &(&1 =~ "Extra test"))
    end

    test "returns unsatisfied when no cwd available" do
      scope = full_scope_fixture()
      # scope.cwd is nil by default from full_scope_fixture
      component = %Component{module_name: "TestApp.NoCwd", type: "module"}

      result = SpecTestAlignmentChecker.check(scope, @requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason =~ "Could not check alignment"
    end

    test "returns unsatisfied when spec dir does not exist", %{scope: scope, tmp_dir: tmp_dir} do
      # tmp_dir exists but has no docs/spec directory
      module_name = "TestApp.NoSpecDir"
      component = %Component{module_name: module_name, type: "module"}

      # Verify no spec dir
      refute File.dir?(Path.join(tmp_dir, "docs/spec"))

      result = SpecTestAlignmentChecker.check(scope, @requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason =~ "Could not check alignment"
    end

    test "includes all required result fields", %{scope: scope} do
      component = %Component{module_name: "TestApp.Fields", type: "module"}

      result = SpecTestAlignmentChecker.check(scope, @requirement_definition, component)

      assert Map.has_key?(result, :name)
      assert Map.has_key?(result, :artifact_type)
      assert Map.has_key?(result, :description)
      assert Map.has_key?(result, :checker_module)
      assert Map.has_key?(result, :satisfied_by)
      assert Map.has_key?(result, :satisfied)
      assert Map.has_key?(result, :score)
      assert Map.has_key?(result, :checked_at)
      assert Map.has_key?(result, :details)
      assert result.checker_module == SpecTestAlignmentChecker
    end
  end
end
