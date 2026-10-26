defmodule CodeMySpec.BddSpecs.CommittedRowsGuardTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpecSpex.CommittedRowsGuard
  alias CodeMySpecSpex.Fixtures

  test "a committed project outside the sandbox makes the run fail" do
    Fixtures.committed_project_with_deploy_key!(
      "guard-test-#{System.unique_integer([:positive])}"
    )

    result =
      Task.async(fn ->
        try do
          CommittedRowsGuard.check_after_suite!(%{})
          :clean
        rescue
          error -> {:dirty, Exception.message(error)}
        end
      end)
      |> Task.await()

    assert {:dirty, message} = result
    assert message =~ "spex left committed rows outside the sandbox"
    assert message =~ "projects="
  end
end
