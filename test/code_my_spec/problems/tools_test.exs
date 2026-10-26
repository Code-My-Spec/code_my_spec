defmodule CodeMySpec.Problems.ToolsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.CodeMode
  alias CodeMySpec.Problems
  alias CodeMySpec.ToolLibrary

  setup do
    %{scope: full_scope_fixture()}
  end

  test "both tools retain their original MCP contracts" do
    original =
      "test/fixtures/tool_contracts/problems.json"
      |> File.read!()
      |> Jason.decode!()

    actual =
      ToolLibrary.registrations()
      |> Enum.filter(&(&1.name in ~w(clear_problems list_problems)))
      |> Enum.map(&Map.take(&1, [:name, :description, :input_schema]))
      |> Enum.sort_by(& &1.name)
      |> Jason.encode!()
      |> Jason.decode!()

    assert actual == original
  end

  test "pagination tells the caller how to retrieve the next page", %{scope: scope} do
    for filename <- ~w(a.ex b.ex c.ex) do
      problem_fixture(scope, %{file_path: filename, message: "First line\nMore detail"})
    end

    assert {:ok, text} =
             ToolLibrary.run("list_problems", %{page: 2, per_page: 1}, %{scope: scope})

    assert text =~ "(1 of 3) — page 2/3"
    assert text =~ "b.ex:42 — First line"
    refute text =~ "More detail"
    refute text =~ "a.ex:42"
    assert text =~ "call again with `page: 3`"
  end

  test "page size is capped at 100", %{scope: scope} do
    problem_list_fixture(scope, 101)

    assert {:ok, text} =
             ToolLibrary.run("list_problems", %{per_page: 1000}, %{scope: scope})

    assert text =~ "(100 of 101)"
    assert text =~ "page 1/2"
  end

  test "nonpositive pagination arguments use the first page and at least one row", %{scope: scope} do
    problem_fixture(scope)

    assert {:ok, text} =
             ToolLibrary.run("list_problems", %{page: 0, per_page: 0}, %{scope: scope})

    assert text =~ "(1 of 1) — page 1/1"
  end

  test "source filtering affects both the rows and the total", %{scope: scope} do
    problem_fixture(scope, %{source: "compiler", file_path: "compile.ex"})
    problem_fixture(scope, %{source: "credo", file_path: "style.ex"})

    assert {:ok, text} =
             ToolLibrary.run("list_problems", %{source: "compiler"}, %{scope: scope})

    assert text =~ "(1 of 1)"
    assert text =~ "compile.ex"
    refute text =~ "style.ex"
  end

  test "a failed compile's Boundary finding appears in error-filtered results", %{scope: scope} do
    assert {:ok, %{problems: [finding]}} =
             CodeMySpec.Analysis.Runners.from_raw("compiler", %{
               "exit_status" => 1,
               "diagnostics" => [
                 %{
                   "file" => "test/spex/setup_spex.exs",
                   "line" => 12,
                   "severity" => "warning",
                   "message" => "forbidden reference to CmsHarness.Setup"
                 }
               ]
             })

    assert {:ok, [_]} = Problems.create_problems(scope, [finding])

    assert {:ok, [row]} =
             CodeMode.catalog(scope)["list_problems"].invoke.(%{"severity" => "error"})

    assert row["severity"] == "error"
    assert row["message"] == "forbidden reference to CmsHarness.Setup"
  end

  test "code mode preserves structured finding rows", %{scope: scope} do
    problem = problem_fixture(scope)

    assert {:ok, [row]} = CodeMode.catalog(scope)["list_problems"].invoke.(%{})

    assert row == %{
             "id" => problem.id,
             "severity" => "error",
             "source" => "credo",
             "file_path" => "lib/my_app/example.ex",
             "line" => 42,
             "message" => "Modules should have a @moduledoc tag",
             "category" => "readability",
             "rule" => "Credo.Check.Readability.ModuleDoc"
           }
  end

  test "code mode retains an unquoted invalid-severity error", %{scope: scope} do
    assert {:error, reason} =
             CodeMode.catalog(scope)["list_problems"].invoke.(%{"severity" => "critical"})

    assert String.starts_with?(reason, "Unknown severity")
  end

  test "listing and clearing cannot affect another project's findings", %{scope: scope} do
    own = problem_fixture(scope, %{file_path: "own.ex"})
    other_scope = full_scope_fixture()
    other = problem_fixture(other_scope, %{file_path: "private.ex"})

    assert {:ok, text} = ToolLibrary.run("list_problems", %{}, %{scope: scope})
    assert text =~ own.file_path
    refute text =~ other.file_path

    assert {:ok, _summary} = ToolLibrary.run("clear_problems", %{}, %{scope: scope})
    assert Problems.list_project_problems(scope) == []
    assert Enum.map(Problems.list_project_problems(other_scope), & &1.id) == [other.id]
  end

  test "missing scope and malformed arguments are refused" do
    assert {:error, missing_scope} = ToolLibrary.run("list_problems", %{}, %{})
    assert missing_scope =~ "Active project is not set"

    assert {:error, invalid} = ToolLibrary.run("clear_problems", %{file_paths: 42}, %{})
    assert invalid =~ "invalid arguments"
  end
end
