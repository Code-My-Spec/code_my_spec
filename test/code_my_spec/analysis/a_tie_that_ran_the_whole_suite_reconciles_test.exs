defmodule CodeMySpec.Analysis.ATieThatRanTheWholeSuiteReconcilesTest do
  @moduledoc """
  2026-10-05, batch 313e82812: a targeted exunit run (55132) sat queued on the
  gate copy, and the batch's full run (55135) was tied onto it. The harness
  merges a tie's args, so what executed was the whole suite. But the primary row
  was partial, so its result was output only, and the tied full run was output
  only by design. Nothing reconciled: 17 problems from an older run stood, the
  gate read them, and the batch was ejected on findings its own run did not
  have.

  What a result replaces is decided by what ran (`"args"` on the result), not
  by what the primary row asked for.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Problems.ProblemRepository

  @files ["test/a_test.exs"]

  setup do
    scope = full_scope_fixture()

    problem_fixture(scope, %{source: "exunit", severity: :error, file_path: "test/stale_test.exs"})

    {:ok, primary} =
      RunsRepository.start_run(scope, %{
        source: "exunit",
        kind: :partial,
        args: %{"args" => @files}
      })

    {:ok, tied} = RunsRepository.start_run(scope, %{source: "exunit", kind: :full})
    %{scope: scope, primary: primary, tied: tied}
  end

  defp clean(run_id, executed, tied_to \\ nil) do
    %{
      "run_id" => run_id,
      "source" => "exunit",
      "status" => "ok",
      "args" => executed,
      "tied_to" => tied_to,
      "result" => %{
        "exit_status" => 0,
        "execution_status" => "success",
        "output" => "1 test, 0 failures",
        "stats" => %{"tests" => 1, "failures" => 0},
        "diagnostics" => []
      }
    }
  end

  defp exunit_problems(scope),
    do: ProblemRepository.list_project_problems(scope, sources: ["exunit"])

  test "a partial primary whose tie widened it to the whole suite replaces the problems", ctx do
    Analysis.record_remote_result(ctx.scope, clean(ctx.primary.id, []))
    Analysis.record_remote_result(ctx.scope, clean(ctx.tied.id, [], ctx.primary.id))

    assert exunit_problems(ctx.scope) == [],
           "the whole suite ran clean and the older finding still stands"
  end

  test "a partial primary that ran only its files leaves the problems alone", ctx do
    Analysis.record_remote_result(ctx.scope, clean(ctx.primary.id, @files))

    assert [%{file_path: "test/stale_test.exs"}] = exunit_problems(ctx.scope)
  end
end
