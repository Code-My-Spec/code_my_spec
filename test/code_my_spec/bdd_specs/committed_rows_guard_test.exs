defmodule CodeMySpec.BddSpecs.CommittedRowsGuardTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpecSpex.CommittedRowsGuard
  alias CodeMySpecSpex.Fixtures

  test "a committed project outside the sandbox makes the run fail" do
    Fixtures.committed_project_with_deploy_key!(
      "guard-test-#{System.unique_integer([:positive])}"
    )

    error =
      Task.async(fn ->
        assert_raise RuntimeError, fn -> CommittedRowsGuard.check_after_suite!(%{}) end
      end)
      |> Task.await()

    assert Exception.message(error) =~ "spex left committed rows outside the sandbox"
    assert Exception.message(error) =~ "projects="
  end
end
