defmodule CodeMySpec.PromotionQueue.APromoteIsCertifiedOnItsTreeTest do
  @moduledoc """
  Story 1174: a change is certified by passes of every analyzer on the exact
  tree it contains, whichever copy or commit produced them, and a refusal names
  exactly the analyzers that have not passed it.

  Git is scripted through the in-memory environment; nothing shells out.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecTest.PromotionQueueHelpers

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.Support.InMemoryExecutionContext
  alias CodeMySpec.WorkingCopies

  @root "/tree-certified/copy"
  @head String.duplicate("2", 40)
  @elsewhere String.duplicate("3", 40)
  @tree String.duplicate("a", 40)
  @other_tree String.duplicate("b", 40)

  setup do
    scope = full_scope_fixture()

    {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, _main} = WorkingCopies.report_root(main, "/tree-certified/main")

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "team", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, @root)
    {:ok, other} = WorkingCopies.issue(scope, nil, label: "other", device: device_fixture(scope))

    {:ok, env} = InMemoryExecutionContext.create(shell: &git/3)
    :ok = ExecutionContexts.register({:working_copy, copy.id}, env)

    on_exit(fn -> stop_worker(scope.active_project_id) end)

    %{
      scope: %{scope | active_working_copy_id: copy.id},
      elsewhere: %{scope | active_working_copy_id: other.id}
    }
  end

  defp git("git", ["status" | _], _opts), do: {"", 0}
  defp git("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts), do: {"team\n", 0}
  defp git("git", ["rev-parse", "HEAD", "HEAD^{tree}"], _opts), do: {"#{@head}\n#{@tree}\n", 0}
  defp git("git", ["ls-files" | _], _opts), do: {"", 0}
  defp git("git", args, _opts), do: {"unscripted: git #{Enum.join(args, " ")}", 1}

  defp queued(scope), do: Repository.queued(scope.active_project_id, 10)

  test "passes recorded on another copy at another commit certify the same tree", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.elsewhere, Run.sources(),
      commit: @elsewhere,
      tree: @tree
    )

    assert {:ok, %{queued: entry}} = PromotionQueue.promote(ctx.scope, nil)
    assert entry.commit == @head
  end

  test "passes on a different tree certify nothing", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.elsewhere, Run.sources(),
      commit: @elsewhere,
      tree: @other_tree
    )

    assert {:error, %{reason: reason, uncertified: missing}} =
             PromotionQueue.promote(ctx.scope, nil)

    assert missing == ~w(compiler credo exunit spex)
    assert reason =~ "is not certified"
    assert queued(ctx.scope) == []
  end

  test "the refusal names exactly the analyzer that has not passed the tree", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.elsewhere, ~w(compiler credo spex),
      commit: @elsewhere,
      tree: @tree
    )

    assert {:error, %{reason: reason, uncertified: ["exunit"]}} =
             PromotionQueue.promote(ctx.scope, nil)

    assert reason =~ "is not certified: exunit has not passed its tree"
    assert queued(ctx.scope) == []
  end

  test "a dirty or red run elsewhere does not certify", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.elsewhere, ~w(compiler credo),
      commit: @elsewhere,
      tree: @tree
    )

    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.elsewhere, ["spex"],
      commit: @elsewhere,
      tree: @tree,
      start_tree_dirty: true
    )

    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.elsewhere, ["exunit"],
      commit: @elsewhere,
      tree: @tree,
      problems: [
        %{severity: :error, source: "exunit", file_path: "test/a_test.exs", message: "failed"}
      ]
    )

    assert {:error, %{uncertified: ["exunit", "spex"]}} = PromotionQueue.promote(ctx.scope, nil)
  end

  test "runs recorded with no tree still certify at the copy's HEAD", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.scope, Run.sources(), commit: @head)

    assert {:ok, %{queued: _entry}} = PromotionQueue.promote(ctx.scope, nil)
  end
end
