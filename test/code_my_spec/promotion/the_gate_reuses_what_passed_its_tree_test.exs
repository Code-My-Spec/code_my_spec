defmodule CodeMySpec.Promotion.TheGateReusesWhatPassedItsTreeTest do
  @moduledoc """
  Story 1174: the promotion gate reuses every analyzer already passed on the
  tree it would land, and runs only the rest. A fast-forward of a certified
  tree runs nothing; `fresh` runs everything again.

  The gate copy's harness is a process that records the runs dispatched to it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies

  @candidate String.duplicate("2", 40)
  @merge String.duplicate("4", 40)
  @earlier_merge String.duplicate("5", 40)
  @tree String.duplicate("a", 40)
  @merged_tree String.duplicate("c", 40)

  setup do
    scope = full_scope_fixture()

    {:ok, gate} = WorkingCopies.issue(scope, nil, label: "gate", device: device_fixture(scope))
    {:ok, gate} = WorkingCopies.report_root(gate, "/reuse/gate")
    {:ok, team} = WorkingCopies.issue(scope, nil, label: "team", device: device_fixture(scope))

    a_harness(gate.id)

    %{
      gate: %{scope | active_working_copy_id: gate.id},
      team: %{scope | active_working_copy_id: team.id}
    }
  end

  defp a_harness(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "gate-harness", "/reuse/gate")
      send(test, :registered)
      forward(test)
    end)

    assert_receive :registered, 2_000
  end

  defp forward(test) do
    receive do
      {:run_analysis, runs} -> send(test, {:dispatched, runs})
      _other -> :ok
    end

    forward(test)
  end

  defp dispatched_sources do
    receive do
      {:dispatched, runs} -> Enum.map(runs, & &1["source"]) ++ dispatched_sources()
    after
      100 -> []
    end
  end

  test "a fast-forward of a certified tree runs nothing", ctx do
    certified =
      AnalysisFixtures.fresh_analysis_runs_fixture(ctx.team, Run.sources(),
        commit: @candidate,
        tree: @tree
      )

    assert {:ok, certified_by} = Promotion.gate(ctx.gate, @candidate, tree: @tree)
    assert Enum.map(certified_by, & &1.run_id) == Enum.map(certified, & &1.id)
    assert dispatched_sources() == []
  end

  test "a new merge tree runs only the analyzers that have not passed it", ctx do
    # An earlier gate attempt merged the same candidates onto the same main:
    # another merge commit, the same tree.
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.gate, ~w(compiler exunit),
      commit: @earlier_merge,
      tree: @merged_tree
    )

    # The candidate's own certification is of another tree.
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.team, Run.sources(),
      commit: @candidate,
      tree: @tree
    )

    assert {:pending, %{started: started, running: []}} =
             Promotion.gate(ctx.gate, @merge, tree: @merged_tree)

    assert Enum.sort(started) == ~w(credo spex)
    assert Enum.sort(dispatched_sources()) == ~w(credo spex)
  end

  test "a gate copy's leftover problems do not refuse a source it reused", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.team, Run.sources(),
      commit: @candidate,
      tree: @tree
    )

    # From the batch the gate copy ran before this one.
    problem_fixture(ctx.gate, %{source: "exunit", severity: :error, file_path: "test/a_test.exs"})

    assert {:ok, _certified_by} = Promotion.gate(ctx.gate, @candidate, tree: @tree)
  end

  test "fresh runs every analyzer again", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.team, Run.sources(),
      commit: @candidate,
      tree: @tree
    )

    fresh_since = DateTime.add(DateTime.utc_now(), 1, :second)

    assert {:pending, %{started: started}} =
             Promotion.gate(ctx.gate, @candidate, tree: @tree, fresh_since: fresh_since)

    assert Enum.sort(started) == Enum.sort(Run.sources())
  end

  test "no tree from the gate copy reuses nothing", ctx do
    AnalysisFixtures.fresh_analysis_runs_fixture(ctx.team, Run.sources(),
      commit: @candidate,
      tree: @tree
    )

    assert {:pending, %{started: started}} = Promotion.gate(ctx.gate, @candidate, tree: nil)
    assert Enum.sort(started) == Enum.sort(Run.sources())
  end
end
