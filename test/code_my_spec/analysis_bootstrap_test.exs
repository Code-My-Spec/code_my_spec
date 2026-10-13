defmodule CodeMySpec.AnalysisBootstrapTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  # Explicit analysis — `start_analysis`, certification, promotion — always
  # runs what it asks for. The quiet-stop rules that once skipped "current"
  # sources went with the stop's analysis (John, 2026-10-04).
  describe "ensure_stale_runs/3" do
    test "enqueues every requested source and memoizes none", %{scope: scope} do
      assert %{enqueued: enqueued, memoized: []} =
               Analysis.ensure_stale_runs(scope, ["credo", "compiler"], [])

      assert Enum.sort(enqueued) == ["compiler", "credo"]
    end

    test "puts compile first" do
      assert [{"compiler", _}, {"credo", _}] = Analysis.plan_runs(["credo", "compiler"])
    end
  end
end
