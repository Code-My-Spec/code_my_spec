defmodule Mix.Tasks.Cms.GraphVerifyTest do
  use CodeMySpecTest.DataCase, async: true

  import ExUnit.CaptureIO
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Requirements
  alias Mix.Tasks.Cms.GraphVerify

  test "a seeded checkout passes and identifies its vantage" do
    scope = full_scope_fixture()
    Requirements.recompute(scope)

    output = capture_io(fn -> GraphVerify.run(arguments(scope)) end)
    report = Jason.decode!(output)
    assert report["agrees"]
    assert report["project_id"] == scope.active_project_id
    assert report["working_copy_id"] == scope.active_working_copy_id
    assert report["computed"] > 0
  end

  test "missing served rows fail without being repaired" do
    scope = full_scope_fixture()
    Requirements.recompute(scope)

    # The stored record verdicts: a copy's file verdicts are read, not stored.
    CodeMySpec.Repo.delete_all("project_requirements")

    output =
      capture_io(fn -> assert catch_exit(GraphVerify.run(arguments(scope))) == {:shutdown, 1} end)

    report = Jason.decode!(output)
    refute report["agrees"]
    assert report["missing"] > 0
    assert CodeMySpec.Repo.aggregate("project_requirements", :count) == 0
  end

  test "a checkout from another project is rejected" do
    scope = full_scope_fixture()
    other = full_scope_fixture()

    assert_raise Mix.Error, ~r/must belong/, fn ->
      GraphVerify.run([
        "--project",
        scope.active_project_id,
        "--working-copy",
        other.active_working_copy_id
      ])
    end
  end

  test "a project is required" do
    assert_raise Mix.Error, ~r/--project requires/, fn -> GraphVerify.run([]) end
  end

  defp arguments(scope),
    do: ["--project", scope.active_project_id, "--working-copy", scope.active_working_copy_id]
end
