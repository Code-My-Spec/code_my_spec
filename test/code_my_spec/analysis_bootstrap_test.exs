defmodule CodeMySpec.AnalysisBootstrapTest do
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  describe "ensure_stale_runs/3 with only_failed" do
    test "enqueues a source that has never run", %{scope: scope} do
      # The bootstrap case. `only_failed` means "re-run what broke", and a
      # source with no run at all matched no clause — so it was skipped as
      # current, forever, and could never produce the first run that would
      # let it be considered again.
      assert %{enqueued: enqueued} =
               Analysis.ensure_stale_runs(scope, ["compiler", "credo"], only_failed: true)

      assert "compiler" in enqueued
      assert "credo" in enqueued
    end

    test "still enqueues everything when only_failed is not set", %{scope: scope} do
      assert %{enqueued: enqueued} = Analysis.ensure_stale_runs(scope, ["credo"], [])
      assert "credo" in enqueued
    end
  end
end
