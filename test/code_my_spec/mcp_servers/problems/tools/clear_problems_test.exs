defmodule CodeMySpec.McpServers.Problems.Tools.ClearProblemsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.ProblemsFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Problems.Tools.ClearProblems
  alias CodeMySpec.Problems

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    %{scope: scope}
  end

  describe "execute/2" do
    test "with no file_paths clears ALL persisted problems for the project", %{scope: scope} do
      problem_fixture(scope, %{file_path: "test/a_test.exs", message: "stale exunit failure"})
      problem_fixture(scope, %{file_path: "lib/b.ex", message: "stale credo warning"})
      assert length(Problems.list_project_problems(scope)) == 2

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ClearProblems.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == false
      assert response_text(response) =~ "Cleared 2 persisted problem"

      assert Problems.list_project_problems(scope) == []
    end

    test "with file_paths clears only those files' problems", %{scope: scope} do
      problem_fixture(scope, %{file_path: "test/rate_limiter_test.exs", message: "stale"})
      problem_fixture(scope, %{file_path: "lib/keep.ex", message: "still real"})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ClearProblems.execute(%{file_paths: ["test/rate_limiter_test.exs"]}, frame)

      assert response.isError == false
      assert response_text(response) =~ "test/rate_limiter_test.exs"

      remaining = Problems.list_project_problems(scope)
      assert length(remaining) == 1
      assert hd(remaining).file_path == "lib/keep.ex"
    end

    test "empty file_paths list falls back to clearing all", %{scope: scope} do
      problem_fixture(scope, %{file_path: "lib/x.ex", message: "stale"})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ClearProblems.execute(%{file_paths: []}, frame)
      assert response.isError == false
      assert Problems.list_project_problems(scope) == []
    end

    test "errors cleanly when no project scope can be resolved" do
      frame = %Frame{assigns: %{current_scope: nil, working_dir: nil}}

      assert {:reply, response, ^frame} = ClearProblems.execute(%{}, frame)
      assert response.isError == true
      assert response_text(response) =~ "Could not clear problems"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
