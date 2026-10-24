defmodule CodeMySpec.Promotion.PromotionIsTheAnalysisGateTest do
  @moduledoc """
  28d72f8a, chunks 1 and 2: promote certifies a commit, not a fingerprint.

  In order: the copy contains main, its tree is clean, every analyzer has a
  completed run that started on a clean tree at HEAD and finished there (one is
  started, and the answer is pending, where it has none), and then exactly
  that commit is merged.

  Git is scripted through the in-memory environment's per-env shell; nothing
  shells out. The promoting copy's harness is a process that records the runs
  dispatched to it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Promotion
  alias CodeMySpec.Support.InMemoryExecutionContext
  alias CodeMySpec.WorkingCopies

  @main "/analysis-gate/main"
  @agent "/analysis-gate/agent"
  @main_head "1111111111111111111111111111111111111111"
  @head "2222222222222222222222222222222222222222"
  @elsewhere "3333333333333333333333333333333333333333"

  defp script(git) do
    test = self()

    fn "git", args, opts ->
      cd = Keyword.fetch!(opts, :cd)
      send(test, {:git, cd, args})
      answer(git, cd, args)
    end
  end

  defp answer(%{contains_main: true}, @agent, ["merge-base", "--is-ancestor", @main_head, "HEAD"]),
       do: {"", 0}

  defp answer(%{contains_main: false}, @agent, ["merge-base", "--is-ancestor", @main_head, "HEAD"]),
       do: {"", 1}

  defp answer(git, @agent, ["status" | _]), do: {git.status, 0}
  defp answer(_git, @agent, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"story/x\n", 0}
  # `heads` is the copy's HEAD per read, the last one repeating: a copy that
  # moves between the gate and the merge.
  defp answer(%{heads: heads}, @agent, ["rev-parse", "HEAD"]) do
    head =
      Agent.get_and_update(heads, fn
        [h] -> {h, [h]}
        [h | rest] -> {h, rest}
      end)

    {head <> "\n", 0}
  end

  defp answer(_git, @agent, ["rev-parse", "HEAD"]), do: {@head <> "\n", 0}
  defp answer(_git, @agent, ["ls-files" | _]), do: {"", 0}
  defp answer(_git, @main, ["rev-parse", "HEAD"]), do: {@main_head <> "\n", 0}
  defp answer(_git, @main, ["diff" | _]), do: {"", 0}
  defp answer(_git, @main, ["merge", "--ff-only", @head]), do: {"Already up to date.\n", 0}

  defp answer(_git, @main, ["show", "HEAD:mix.exs"]),
    do: {~s|def project, do: [app: :x, version: "0.3.3"]\n|, 0}

  defp answer(_git, cd, args), do: {"unscripted: git #{Enum.join(args, " ")} in #{cd}", 1}

  # The main copy's app, answering the restart a promotion dispatches.
  defp a_running_app(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "main-harness", @main)
      send(test, :registered)

      receive do
        {:"$gen_call", from, {:restart_app, _request}} ->
          GenServer.reply(from, {:ok, %{status: "serving", url: "http://x", commit: @head}})
      end
    end)

    assert_receive :registered, 2_000
  end

  # The promoting copy's harness: every run dispatched to it is forwarded.
  defp a_harness(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "agent-harness", @agent)
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

  defp a_project(git \\ []) do
    git = Map.merge(%{contains_main: true, status: ""}, Map.new(git))
    scope = full_scope_fixture()

    {:ok, running} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, running} = WorkingCopies.report_root(running, @main)
    a_running_app(running.id)

    {:ok, agent} = WorkingCopies.issue(scope, nil, label: "agent", device: device_fixture(scope))
    {:ok, agent} = WorkingCopies.report_root(agent, @agent)
    a_harness(agent.id)

    {:ok, env} = InMemoryExecutionContext.create(shell: script(git))
    :ok = ExecutionContexts.register({:working_copy, running.id}, env)
    :ok = ExecutionContexts.register({:working_copy, agent.id}, env)
    %{scope: %{scope | active_working_copy_id: agent.id}}
  end

  defp dispatched_sources do
    receive do
      {:dispatched, runs} -> Enum.map(runs, & &1["source"]) ++ dispatched_sources()
    after
      100 -> []
    end
  end

  defp promote(scope), do: Promotion.promote(scope, nil, notify: "agent-7")

  test "a copy behind main is refused before any analysis" do
    %{scope: scope} = a_project(contains_main: false)

    assert {:error, %{reason: reason}} = promote(scope)
    assert reason =~ "behind main"
    assert reason =~ "Merge main in"

    assert dispatched_sources() == [], "a branch that is behind is never analysed"
    assert RunsRepository.running_full_runs(scope, "compiler") == []
    refute_received {:git, @main, ["merge" | _]}
  end

  test "a dirty tree is refused, naming the files" do
    %{scope: scope} = a_project(status: " M lib/war.ex\nM  lib/peace.ex\n")

    assert {:error, %{reason: reason}} = promote(scope)
    assert reason =~ "lib/war.ex"
    assert reason =~ "lib/peace.ex"
    assert dispatched_sources() == []
    refute_received {:git, @main, ["merge" | _]}
  end

  test "no run at HEAD starts the missing ones and answers pending, not refused" do
    %{scope: scope} = a_project()

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler"], commit: @head)
    # Already running at HEAD, so it is not started a second time.
    {:ok, credo} = RunsRepository.start_run(scope, %{source: "credo", kind: :full})
    RunsRepository.record_tree(credo, %{start_commit: @head, start_tree_dirty: false})

    assert {:ok, %{pending: pending} = result} = promote(scope)
    assert pending.commit == @head
    assert Enum.sort(pending.started) == ["exunit", "spex"]
    assert pending.running == ["credo"]

    assert Promotion.outcome_text({:ok, result}) =~ "Analysis running at #{@head}"

    assert Enum.sort(dispatched_sources()) == ["exunit", "spex"]
    assert [%{id: id}] = RunsRepository.running_full_runs(scope, "credo")
    assert id == credo.id

    [started] = RunsRepository.running_full_runs(scope, "exunit")

    assert started.requested_by["agent_id"] == "agent-7",
           "the result reaches the requester through requested_by when it lands"

    refute_received {:git, @main, ["merge" | _]}
  end

  test "a run whose completed_commit is not HEAD does not qualify" do
    %{scope: scope} = a_project()

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["credo", "exunit", "spex"],
      commit: @head
    )

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler"],
      commit: @head,
      completed_commit: @elsewhere
    )

    assert {:ok, %{pending: %{started: ["compiler"]}}} = promote(scope)
    refute_received {:git, @main, ["merge" | _]}
  end

  test "an incremental compiler run does not qualify; the gate starts a forced one" do
    %{scope: scope} = a_project()

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["credo", "exunit", "spex"],
      commit: @head
    )

    # Clean at HEAD, but incremental: it reports only what it recompiled, and a
    # boundary violation another analyzer had compiled went through unseen.
    {:ok, compiler} =
      RunsRepository.start_run(scope, %{source: "compiler", kind: :full, args: %{"args" => []}})

    {:ok, compiler} = RunsRepository.finish_run(compiler, :completed, %{exit_status: 0})
    RunsRepository.record_tree(compiler, %{start_commit: @head, start_tree_dirty: false})

    assert {:ok, %{pending: %{started: ["compiler"]}}} = promote(scope)

    assert [%{args: %{"args" => ["--force"]}}] =
             RunsRepository.running_full_runs(scope, "compiler")

    refute_received {:git, @main, ["merge" | _]}
  end

  test "a run that started on a dirty tree does not qualify" do
    %{scope: scope} = a_project()

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler", "credo", "exunit"],
      commit: @head
    )

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["spex"],
      commit: @head,
      start_tree_dirty: true
    )

    assert {:ok, %{pending: %{started: ["spex"]}}} = promote(scope)
    refute_received {:git, @main, ["merge" | _]}
  end

  test "a fingerprint-fresh run at another commit no longer counts" do
    %{scope: scope} = a_project()

    # Fingerprint-fresh for every source, but run against a different commit.
    AnalysisFixtures.fresh_analysis_runs_fixture(scope)
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler"], commit: @elsewhere)

    assert {:ok, %{pending: %{started: started}}} = promote(scope)
    assert Enum.sort(started) == ["compiler", "credo", "exunit", "spex"]
    refute_received {:git, @main, ["merge" | _]}
  end

  test "clean runs at HEAD promote exactly that commit" do
    %{scope: scope} = a_project()

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler", "credo", "exunit", "spex"],
      commit: @head
    )

    assert {:ok, %{merged: "story/x", swept: swept}} = promote(scope)
    assert Enum.all?(swept, &(&1.commit == @head))
    assert_received {:git, @main, ["merge", "--ff-only", @head]}
    assert dispatched_sources() == []
  end

  test "a copy that moved after it was certified is refused, and nothing merges" do
    heads = start_supervised!({Agent, fn -> [@head, @elsewhere] end})
    %{scope: scope} = a_project(heads: heads)

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler", "credo", "exunit", "spex"],
      commit: @head
    )

    assert {:error, %{reason: reason}} = promote(scope)
    assert reason =~ "moved from #{@head} to #{@elsewhere}"
    refute_received {:git, @main, ["merge" | _]}
  end

  test "red problems at HEAD refuse under the existing rule" do
    %{scope: scope} = a_project()

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler", "credo", "exunit", "spex"],
      commit: @head
    )

    problem_fixture(scope, %{severity: :warning})

    assert {:error, %{reason: reason}} = promote(scope)
    assert reason =~ "1 credo"
    refute_received {:git, @main, ["merge" | _]}
  end

  test "a credo :info at HEAD is advisory and promotes" do
    %{scope: scope} = a_project()

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["compiler", "credo", "exunit", "spex"],
      commit: @head
    )

    problem_fixture(scope, %{severity: :info})

    assert {:ok, %{merged: "story/x"}} = promote(scope)
  end
end
