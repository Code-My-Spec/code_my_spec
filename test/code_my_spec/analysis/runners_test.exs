defmodule CodeMySpec.Analysis.RunnersTest do
  use CodeMySpecTest.DataCase, async: false
  use ExCliVcr

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Runners

  setup do
    %{scope: full_scope_fixture() |> Map.put(:cwd, File.cwd!())}
  end

  describe "a tool that never ran" do
    # Regression guard. An analyzer that exits nonzero without reporting a
    # single failure has produced no verdict about the code — but an empty
    # failure list is indistinguishable from a clean sweep by shape alone, and
    # the nonzero exit is the only thing separating them.
    #
    # Reporting `{:ok, problems: []}` was actively harmful: the Reconciler
    # clears a source's Problems wholesale before inserting, so the empty
    # result wiped every real exunit Problem and then finished the run
    # `:completed` at the current fingerprint. `tests_passing` asks for exactly
    # those two things — a fresh completed run and zero problems — so a suite
    # that never executed reported the component's tests as passing.
    test "exunit fails the run instead of reporting a clean sweep", %{scope: scope} do
      use_cmd_cassette "exunit_suite_did_not_run", record: :none do
        assert {:error, {:test_suite_did_not_run, 1, excerpt}} =
                 Runners.run("exunit", scope, [], [])

        # The excerpt carries mix's own explanation through to the run's
        # stats["error"], so a failed run says why rather than just "failed".
        assert excerpt =~ "Could not find a Mix.Project"
      end
    end
  end
end
