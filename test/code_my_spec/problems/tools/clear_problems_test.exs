defmodule CodeMySpec.Problems.Tools.ClearProblemsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.ProblemsFixtures

  alias CodeMySpec.Problems
  alias CodeMySpec.ToolLibrary

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    %{scope: scope}
  end

  describe "library execution" do
    test "with no file_paths clears ALL persisted problems for the project", %{scope: scope} do
      problem_fixture(scope, %{file_path: "test/a_test.exs", message: "stale exunit failure"})
      problem_fixture(scope, %{file_path: "lib/b.ex", message: "stale credo warning"})
      assert length(Problems.list_project_problems(scope)) == 2

      assert {:ok, response} = ToolLibrary.run("clear_problems", %{}, %{scope: scope})
      assert response =~ "Cleared 2 persisted problem"

      assert Problems.list_project_problems(scope) == []
    end

    test "with file_paths clears only those files' problems", %{scope: scope} do
      problem_fixture(scope, %{file_path: "test/rate_limiter_test.exs", message: "stale"})
      problem_fixture(scope, %{file_path: "lib/keep.ex", message: "still real"})

      assert {:ok, response} =
               ToolLibrary.run("clear_problems", %{file_paths: ["test/rate_limiter_test.exs"]}, %{
                 scope: scope
               })

      assert response =~ "test/rate_limiter_test.exs"

      remaining = Problems.list_project_problems(scope)
      assert length(remaining) == 1
      assert hd(remaining).file_path == "lib/keep.ex"
    end

    test "empty file_paths list falls back to clearing all", %{scope: scope} do
      problem_fixture(scope, %{file_path: "lib/x.ex", message: "stale"})

      assert {:ok, _summary} =
               ToolLibrary.run("clear_problems", %{file_paths: []}, %{scope: scope})

      assert Problems.list_project_problems(scope) == []
    end

    test "errors cleanly when no project scope can be resolved" do
      assert {:error, response} = ToolLibrary.run("clear_problems", %{}, %{})
      assert response =~ "Could not clear problems"
    end
  end
end
