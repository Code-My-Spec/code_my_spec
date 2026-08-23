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

  ## The rule is asymmetric now

  Refusing on any staleness fixed that loop and bought a worse one: a source
  whose analyzer takes longer than the gap between edits is *never* fresh, so
  its requirement never answers at all — permanently "pending" (issue
  7a7eed33). Absent information rendered as a blocked requirement.

  So the two directions are separated. A stale count above zero is served, with
  the reason saying which run it came from: those findings were true of code
  that existed recently, and naming their vintage is what keeps the drill above
  from repeating. A stale zero still refuses, because reporting clean from a run
  that never read the current code is a false pass — work skipped and nobody
  the wiser, which is the failure this whole area keeps producing.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ComponentsFixtures, ProblemsFixtures, UsersFixtures}

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementCalculator

  setup do
    scope = full_scope_fixture()

    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
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
    {:ok, ctx} = Preloader.load(scope)
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

  # The other half of the rule, and the half that took a decision.
  #
  # Refusing on every stale source left anything slower than the edit cadence
  # permanently "pending" — it never answered at all (7a7eed33). So staleness is
  # asymmetric now: findings are served, clean is refused. A count above zero
  # was true of code that existed recently and is worth acting on; a zero from a
  # run that never saw the current code is a false pass, which is the direction
  # that lets work be skipped and never noticed.
  describe "a stale run that found something" do
    # Problems are counted per component (`problems_by_component`), so these
    # evaluate against one rather than the project. The tests above pass either
    # way only because their count is zero.
    setup %{scope: scope} do
      %{component: component_fixture(scope, %{type: "context"})}
    end

    defp go_stale(scope) do
      Repo.update_all(
        from(f in FileRecord, where: f.project_id == ^scope.active_project_id),
        set: [fingerprint: "after-the-agent-edited-it"]
      )
    end

    defp evaluate_component(scope, component) do
      {:ok, ctx} = Preloader.load(scope)
      result = RequirementCalculator.compute_one(scope, component, credo_check(), [], ctx)
      {result.satisfied, result.details}
    end

    defp found(scope, component, count) do
      fresh_analysis_runs_fixture(scope, ["credo"])
      problem_list_fixture(scope, count, %{source: "credo", component_id: component.id})
      go_stale(scope)
    end

    test "reports the findings rather than refusing", %{scope: scope, component: component} do
      found(scope, component, 3)

      assert {false, details} = evaluate_component(scope, component)
      assert details.count == 3
      assert details.reason =~ "3 credo problem(s)"
    end

    test "says they are from the last completed run", %{scope: scope, component: component} do
      found(scope, component, 2)

      assert {false, details} = evaluate_component(scope, component)

      assert details.reason =~ "last completed credo run",
             "a stale list is indistinguishable from a current one unless it says " <>
               "so, and that is what sent an agent back to re-fix four findings " <>
               "it had already corrected"

      assert details.stale == true
    end

    # The asymmetry itself. Same staleness, opposite answers, decided by whether
    # withholding costs a false pass or a stalled requirement.
    test "a stale zero refuses where a stale count does not", %{
      scope: scope,
      component: component
    } do
      fresh_analysis_runs_fixture(scope, ["credo"])
      go_stale(scope)

      assert {false, %{reason: clean_reason}} = evaluate_component(scope, component)
      assert clean_reason =~ "not current"

      problem_list_fixture(scope, 1, %{source: "credo", component_id: component.id})

      assert {false, %{reason: found_reason}} = evaluate_component(scope, component)
      refute found_reason =~ "not current"
      assert found_reason =~ "1 credo problem(s)"
    end
  end
end
