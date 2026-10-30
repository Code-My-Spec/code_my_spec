defmodule CodeMySpec.Agents.Tools.StartAnalysisOnAPassedTreeTest do
  @moduledoc """
  Story 1174: a full run of a source that already passed the copy's clean tree,
  on any copy or commit, answers at once and queues nothing, unless asked for
  fresh. Scoped runs are unaffected.

  Git is scripted through the in-memory environment; nothing shells out.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Support.InMemoryExecutionContext
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies

  @head String.duplicate("2", 40)
  @elsewhere String.duplicate("3", 40)
  @tree String.duplicate("a", 40)

  setup do
    scope = full_scope_fixture()

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "team", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/passed-tree/team")
    {:ok, other} = WorkingCopies.issue(scope, nil, label: "other", device: device_fixture(scope))

    {:ok, env} = InMemoryExecutionContext.create(shell: &git/3)
    :ok = ExecutionContexts.register({:working_copy, copy.id}, env)
    :ok = HarnessRegistry.register_executor(copy.id)

    AnalysisFixtures.fresh_analysis_runs_fixture(
      %{scope | active_working_copy_id: other.id},
      ["exunit"],
      commit: @elsewhere,
      tree: @tree
    )

    %{scope: %{scope | active_working_copy_id: copy.id}}
  end

  defp git("git", ["status" | _], _opts), do: {"", 0}
  defp git("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts), do: {"team\n", 0}
  defp git("git", ["rev-parse", "HEAD", "HEAD^{tree}"], _opts), do: {"#{@head}\n#{@tree}\n", 0}
  defp git("git", ["ls-files" | _], _opts), do: {"", 0}
  defp git("git", args, _opts), do: {"unscripted: git #{Enum.join(args, " ")}", 1}

  defp start(scope, params), do: ToolLibrary.run("start_analysis", params, %{scope: scope})

  defp text({:ok, text}) when is_binary(text), do: text

  test "a source that passed the tree answers without queueing", %{scope: scope} do
    response = start(scope, %{source: "exunit"})

    assert text(response) =~ "exunit already passed this tree in run"
    refute_receive {:run_analysis, _}, 100
    assert RunsRepository.running_full_runs(scope, "exunit") == []
  end

  test "fresh queues a full run anyway", %{scope: scope} do
    start(scope, %{source: "exunit", fresh: true})

    assert_receive {:run_analysis, [%{"source" => "exunit", "args" => []}]}
  end

  test "a source that has not passed the tree is queued", %{scope: scope} do
    start(scope, %{source: "credo"})

    assert_receive {:run_analysis, [%{"source" => "credo"}]}
  end

  test "a scoped run is queued whatever passed", %{scope: scope} do
    start(scope, %{source: "exunit", paths: ["test/a_test.exs"]})

    assert_receive {:run_analysis, [%{"source" => "exunit", "args" => ["test/a_test.exs"]}]}
  end
end
