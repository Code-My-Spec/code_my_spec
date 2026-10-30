defmodule CodeMySpecSpex.Story1163.Criterion2489Spex do
  @moduledoc """
  Story 1163: Analysis runs keep their failures and problems for a configurable period.
  Criterion 2489: A test missing from a full run's failures counts as passed in it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Analysis.History
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A test absent from a full run's failures passed at that commit", criterion: 2489 do
    scenario "a full exunit run fails test A but passes test B" do
      given_ "a full exunit run at commit X records a failure only in test A", context do
        Fixtures.finished_analysis_run_with_findings(context.scope,
          source: "exunit",
          full: true,
          commit: "commit-X",
          failures: [%{file: "test/a_test.exs", name: "test A"}]
        )

        {:ok, context}
      end

      when_ "history is asked whether test B passed at commit X", context do
        passed = History.test_passed?(context.scope, "commit-X", "test/b_test.exs", "test B")
        failed = History.test_passed?(context.scope, "commit-X", "test/a_test.exs", "test A")
        {:ok, Map.merge(context, %{passed: passed, failed: failed})}
      end

      then_ "test B counts as passed and test A does not", context do
        assert context.passed == true
        assert context.failed == false
        {:ok, context}
      end
    end
  end
end
