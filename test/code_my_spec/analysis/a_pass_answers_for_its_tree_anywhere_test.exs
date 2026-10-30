defmodule CodeMySpec.Analysis.APassAnswersForItsTreeAnywhereTest do
  @moduledoc """
  Story 1174: an analyzer that passed a tree is not run on it again, whichever
  copy or commit produced the pass. Only clean, full, finished passes count.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.{History, RunsRepository}
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.WorkingCopies

  @commit String.duplicate("1", 40)
  @other_commit String.duplicate("2", 40)
  @tree String.duplicate("a", 40)
  @other_tree String.duplicate("b", 40)

  setup do
    scope = full_scope_fixture()
    {:ok, other} = WorkingCopies.issue(scope, nil, label: "other", device: device_fixture(scope))
    %{scope: scope, elsewhere: %{scope | active_working_copy_id: other.id}}
  end

  defp passed(ctx, source \\ "exunit", opts \\ []) do
    [run] =
      AnalysisFixtures.fresh_analysis_runs_fixture(
        ctx.elsewhere,
        [source],
        Keyword.merge([commit: @other_commit, tree: @tree], opts)
      )

    run
  end

  test "a pass on another copy at another commit answers for the same tree", ctx do
    run = passed(ctx)

    assert %{id: id} = Analysis.passed_on_tree(ctx.scope, @tree, "exunit")
    assert id == run.id
    assert Analysis.passed_on_tree(ctx.scope, @other_tree, "exunit") == nil
    assert Analysis.passed_on_tree(ctx.scope, @tree, "credo") == nil
  end

  test "a copy that reports no tree reuses nothing", ctx do
    passed(ctx)
    assert Analysis.passed_on_tree(ctx.scope, nil, "exunit") == nil
  end

  test "a run started on a dirty tree records no tree", ctx do
    run = passed(ctx, "exunit", start_tree_dirty: true)

    assert run.start_tree == nil
    assert Analysis.passed_on_tree(ctx.scope, @tree, "exunit") == nil
  end

  test "a run whose tree moved before it finished does not count", ctx do
    passed(ctx, "exunit", completed_commit: @commit)
    assert Analysis.passed_on_tree(ctx.scope, @tree, "exunit") == nil
  end

  test "a partial run does not count", ctx do
    {:ok, run} =
      RunsRepository.start_run(ctx.elsewhere, %{
        source: "exunit",
        kind: :partial,
        args: %{"args" => ["test/a_test.exs"]}
      })

    {:ok, run} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
    clean(run) |> History.record!([], [])

    assert Analysis.passed_on_tree(ctx.scope, @tree, "exunit") == nil
  end

  test "failed and abandoned runs never count", ctx do
    {:ok, failed} = RunsRepository.start_run(ctx.elsewhere, %{source: "exunit", kind: :full})
    failed = clean(failed)
    {:ok, failed} = RunsRepository.finish_run(failed, :failed, %{exit_status: 1})
    History.record!(failed, [], [])

    {:ok, abandoned} = RunsRepository.start_run(ctx.elsewhere, %{source: "credo", kind: :full})
    {:ok, _} = abandoned |> clean() |> RunsRepository.abandon_run("harness gone")

    assert Analysis.passed_on_tree(ctx.scope, @tree, "exunit") == nil
    assert Analysis.passed_on_tree(ctx.scope, @tree, "credo") == nil
  end

  test "a run with a blocking finding is not a pass; an advisory one is", ctx do
    passed(ctx, "exunit",
      problems: [
        %{severity: :error, source: "exunit", file_path: "test/a_test.exs", message: "failed"}
      ]
    )

    credo =
      passed(ctx, "credo",
        problems: [%{severity: :info, source: "credo", file_path: "lib/a.ex", message: "nit"}]
      )

    assert Analysis.passed_on_tree(ctx.scope, @tree, "exunit") == nil
    assert %{id: id} = Analysis.passed_on_tree(ctx.scope, @tree, "credo")
    assert id == credo.id
  end

  test "a red run does not hide an earlier pass of the same tree", ctx do
    pass = passed(ctx)

    passed(ctx, "exunit",
      problems: [
        %{severity: :error, source: "exunit", file_path: "test/a_test.exs", message: "flaky"}
      ]
    )

    assert %{id: id} = Analysis.passed_on_tree(ctx.scope, @tree, "exunit")
    assert id == pass.id
  end

  test "an incremental compiler run does not count", ctx do
    {:ok, run} =
      RunsRepository.start_run(ctx.elsewhere, %{
        source: "compiler",
        kind: :full,
        args: %{"args" => []}
      })

    {:ok, run} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
    run |> clean() |> History.record!([], [])

    assert Analysis.passed_on_tree(ctx.scope, @tree, "compiler") == nil
  end

  defp clean(run) do
    RunsRepository.record_tree(run, %{
      start_commit: @other_commit,
      start_tree_dirty: false,
      start_tree: @tree,
      completed_commit: @other_commit
    })
  end
end
