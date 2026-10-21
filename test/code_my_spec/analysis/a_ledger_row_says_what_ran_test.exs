defmodule CodeMySpec.Analysis.ALedgerRowSaysWhatRanTest do
  @moduledoc """
  cae115ed. A spex run requested for one file ran all 1727 while its ledger row
  said `kind: partial` with the one path: the harness ties a request onto the
  entry already queued for that source and merges their arguments, so what ran
  was the whole suite (or another request's files too), and a row that records
  only the request cannot tell whoever reads it what executed.

  The row keeps what was asked and gains what ran; its kind follows what ran.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository

  @file_a "test/spex/a_spex.exs"
  @file_b "test/spex/b_spex.exs"

  setup do
    scope = full_scope_fixture()

    {:ok, scoped} =
      RunsRepository.start_run(scope, %{
        source: "spex",
        kind: :partial,
        args: %{"args" => [@file_a]}
      })

    %{scope: scope, scoped: scoped}
  end

  defp result(run_id, executed, tied_to \\ nil) do
    %{
      "run_id" => run_id,
      "source" => "spex",
      "status" => "ok",
      "args" => executed,
      "tied_to" => tied_to,
      "result" => %{
        "exit_status" => 0,
        "output" => "ran",
        "diagnostics" => []
      }
    }
  end

  defp row(scope, run), do: RunsRepository.get_run_in_project(scope, run.id)

  test "a scoped request that executed the whole suite is a full run that says what was asked",
       ctx do
    Analysis.record_remote_result(ctx.scope, result(ctx.scoped.id, []))

    finished = row(ctx.scope, ctx.scoped)
    assert finished.kind == :full
    assert finished.args["args"] == [@file_a], "what was asked is kept"
    assert finished.args["executed"] == [], "and what ran is recorded"
  end

  test "a scoped request tied onto another's files records the union that ran", ctx do
    Analysis.record_remote_result(ctx.scope, result(ctx.scoped.id, [@file_a, @file_b]))

    finished = row(ctx.scope, ctx.scoped)
    assert finished.kind == :partial
    assert finished.args["executed"] == [@file_a, @file_b]
  end

  test "a request that ran exactly what it asked is left as it was", ctx do
    Analysis.record_remote_result(ctx.scope, result(ctx.scoped.id, [@file_a]))

    finished = row(ctx.scope, ctx.scoped)
    assert finished.kind == :partial
    refute Map.has_key?(finished.args, "executed")
  end

  test "a tied row is relabelled by what the primary ran, not what the tie asked", ctx do
    {:ok, primary} = RunsRepository.start_run(ctx.scope, %{source: "spex", kind: :full})

    Analysis.record_remote_result(ctx.scope, result(primary.id, []))
    Analysis.record_remote_result(ctx.scope, result(ctx.scoped.id, [], primary.id))

    tied = row(ctx.scope, ctx.scoped)
    assert tied.kind == :full
    assert tied.args["executed"] == []
  end
end
