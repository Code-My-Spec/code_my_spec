defmodule CodeMySpec.Requirements.StaleAnalysisTest do
  @moduledoc """
  What a `no_problems` check says when the analysis behind it is out of date.

  `tests_passing` has guarded this for a while, against a stale *zero*: no
  recorded failures for yesterday's code is not evidence today's code passes.
  The same staleness runs the other way for credo and the compiler, and that
  direction had no guard at all — a stale *non-zero* count is a false failure,
  handed to the agent as a list of problems to fix.

  A drill hit it. The agent fixed four credo findings and got the same four
  back, at the same line numbers, against code it had already corrected;
  `mix credo --strict` said clean and so did `await_analysis`. It refused to
  re-fix and filed the friction, which was right — for "nesting too deep" or
  "alias order" there is no idempotent second fix, so satisfying a stale list
  means inventing a different refactor of correct code, and each such edit
  produces the next stale snapshot. The loop has no exit and every turn makes
  the code worse.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, UsersFixtures}

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Requirements.RequirementCalculator

  setup do
    scope = full_scope_fixture()

    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      harness_id: scope.active_harness_id,
      path: "lib/my_app/accounts.ex",
      role: :implementation,
      valid: true,
      validation_errors: %{}
    })

    %{scope: scope}
  end

  defp credo_check,
    do: %{name: "credo_clean", check_type: :no_problems, config: %{"source" => "credo"}}

  defp evaluate(scope, definition) do
    ctx = CodeMySpec.Requirements.Preloader.load(scope)
    result = RequirementCalculator.compute_one(scope, scope.active_project, definition, [], ctx)
    {result.satisfied, result.details}
  end

  describe "credo problems against a stale run" do
    test "with no run at all, says pending rather than passing", %{scope: scope} do
      assert {false, %{reason: reason}} = evaluate(scope, credo_check())

      assert reason =~ "not current",
             "no analysis has run, so zero recorded problems is not evidence of anything"
    end

    test "a fresh run with no problems passes", %{scope: scope} do
      fresh_analysis_runs_fixture(scope, ["credo"])

      assert {true, %{status: status}} = evaluate(scope, credo_check())
      assert status =~ "No credo problems"
    end

    test "a run stamped before the file changed no longer counts", %{scope: scope} do
      fresh_analysis_runs_fixture(scope, ["credo"])

      # The agent's edit. The fingerprint covers the files, so touching one is
      # exactly what the drill did between the analyzer running and the hook
      # reading its result.
      Repo.update_all(
        from(f in FileRecord, where: f.project_id == ^scope.active_project_id),
        set: [fingerprint: "after-the-agent-edited-it"]
      )

      assert {false, %{reason: reason}} = evaluate(scope, credo_check())

      assert reason =~ "not current",
             "this is the moment that mattered: the run completed against the " <>
               "old bytes, so neither its problems nor its silence describe " <>
               "what is on disk now"

      refute reason =~ "problem(s)",
             "naming a count here is what sends the agent back to re-fix code " <>
               "that is already correct — the reply has to say wait, not what " <>
               "to change"
    end
  end
end
