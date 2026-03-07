defmodule CodeMySpec.Problems.ProblemAssignerTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemAssigner

  @component_id_a "aaaa-1111"
  @component_id_b "bbbb-2222"

  @path_index %{
    "lib/my_app/accounts.ex" => @component_id_a,
    "test/my_app/accounts_test.exs" => @component_id_a,
    "lib/my_app/users.ex" => @component_id_b,
    "test/my_app/users_test.exs" => @component_id_b
  }

  describe "assign/2" do
    test "assigns component_id to problems with exact path match" do
      problems = [
        %{file_path: "lib/my_app/accounts.ex", message: "issue"},
        %{file_path: "lib/my_app/users.ex", message: "issue"}
      ]

      result = ProblemAssigner.assign(problems, @path_index)

      assert Enum.at(result, 0).component_id == @component_id_a
      assert Enum.at(result, 1).component_id == @component_id_b
    end

    test "assigns nil for unmatched paths" do
      problems = [%{file_path: "lib/unknown/thing.ex", message: "issue"}]

      result = ProblemAssigner.assign(problems, @path_index)

      assert Enum.at(result, 0).component_id == nil
    end

    test "assigns nil when file_path is nil" do
      problems = [%{file_path: nil, message: "generic error"}]

      result = ProblemAssigner.assign(problems, @path_index)

      assert Enum.at(result, 0).component_id == nil
    end

    test "works with Problem structs" do
      problems = [
        %Problem{file_path: "lib/my_app/accounts.ex", message: "issue", severity: :error,
                 source: "credo", source_type: :static_analysis, category: "readability"}
      ]

      [assigned] = ProblemAssigner.assign(problems, @path_index)

      assert %Problem{} = assigned
      assert assigned.component_id == @component_id_a
    end

    test "fuzzy matches when path is a suffix" do
      problems = [%{file_path: "/full/path/to/lib/my_app/accounts.ex", message: "issue"}]

      result = ProblemAssigner.assign(problems, @path_index)

      assert Enum.at(result, 0).component_id == @component_id_a
    end

    test "handles empty problems list" do
      assert ProblemAssigner.assign([], @path_index) == []
    end

    test "handles empty path index" do
      problems = [%{file_path: "lib/my_app/accounts.ex", message: "issue"}]

      [assigned] = ProblemAssigner.assign(problems, %{})

      assert assigned.component_id == nil
    end
  end
end
