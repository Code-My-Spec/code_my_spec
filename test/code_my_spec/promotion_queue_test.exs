defmodule CodeMySpec.PromotionQueueTest do
  @moduledoc """
  The queue end to end on a local checkout: candidates are batched in the gate
  copy, gated once, and a green batch lands on main as its exact commit; a
  conflicting candidate is ejected without blocking the rest; a red candidate
  is ejected with its findings and nothing lands.

  `async: false`: the queue's worker is a process under the application's
  supervisor, so it reads through the shared sandbox.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpecTest.PromotionQueueHelpers
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.PromotionQueue.Worker
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  @reloaded {:ok,
             %{
               status: "serving",
               url: "http://127.0.0.1:4000",
               commit: "launch0",
               serving_commit: "reload1",
               action: "reloaded"
             }}

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(out)
  end

  # Main, a detached gate worktree, and one worktree per candidate branch.
  # `@tag gate: :later` records the gate copy but leaves its checkout unmade,
  # as a freshly minted copy is until its harness comes up: building a batch
  # there fails until it does.
  setup ctx do
    scope = full_scope_fixture()
    main_root = CodeMySpec.TempFile.dir("queue-main")
    File.mkdir_p!(main_root)
    git!(main_root, ["init", "-q", "-b", "main"])
    git!(main_root, ["config", "user.email", "q@example.com"])
    git!(main_root, ["config", "user.name", "Q"])
    File.write!(Path.join(main_root, "app.ex"), "defmodule App do\nend\n")
    git!(main_root, ["add", "-A"])
    git!(main_root, ["commit", "-q", "-m", "base"])
    git!(main_root, ["tag", "-a", "v0.1.0", "-m", "v0.1.0"])

    gate_root = CodeMySpec.TempFile.dir("queue-gate")
    File.rm_rf!(gate_root)
    gate_checkout(main_root, gate_root, ctx[:gate])

    {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, main} = WorkingCopies.report_root(main, main_root)

    {:ok, gate} =
      WorkingCopies.issue(scope, nil, label: Worker.gate_label(), device: device_fixture(scope))

    {:ok, gate} = WorkingCopies.report_root(gate, gate_root)

    a_harness_for(main.id, main_root)

    on_exit(fn ->
      stop_worker(scope.active_project_id)
      File.rm_rf(gate_root)
      File.rm_rf(main_root)
    end)

    %{scope: scope, main_root: main_root, main: main, gate: gate, gate_root: gate_root}
  end

  defp gate_checkout(_main_root, _gate_root, :later), do: :ok

  defp gate_checkout(main_root, gate_root, _now),
    do: git!(main_root, ["worktree", "add", "--detach", gate_root, "main"])

  defp a_harness_for(working_copy_id, root) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "test-harness", root)
      HarnessRegistry.register_verb(working_copy_id, "reload_app")
      send(test, :registered)
      answer(test, working_copy_id)
    end)

    assert_receive :registered, 2_000
  end

  # Every call answered as a reload, and every run it is sent told to the test.
  defp answer(test, working_copy_id) do
    receive do
      {:"$gen_call", from, {_verb, _request}} ->
        GenServer.reply(from, @reloaded)

      {:run_analysis, runs} ->
        send(test, {:run_analysis_on, working_copy_id, runs})
    end

    answer(test, working_copy_id)
  end

  # A candidate: a worktree on its own branch, from `from`, with one commit.
  defp candidate(ctx, name, from, file, content) do
    root = CodeMySpec.TempFile.dir("queue-#{name}")
    File.rm_rf!(root)
    git!(ctx.main_root, ["worktree", "add", "-q", "-b", name, root, from])
    File.write!(Path.join(root, file), content)
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", name])
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, copy} =
      WorkingCopies.issue(ctx.scope, nil, label: name, device: device_fixture(ctx.scope))

    {:ok, copy} = WorkingCopies.report_root(copy, root)
    %{copy: copy, commit: git!(root, ["rev-parse", "HEAD"])}
  end

  defp queue(ctx, %{copy: copy, commit: commit}) do
    {:ok, entry} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: copy.id,
        commit: commit,
        restart: false
      })

    entry
  end

  defp gate_scope(ctx), do: %{ctx.scope | active_working_copy_id: ctx.gate.id}

  defp clean_runs_at(ctx, commit),
    do:
      AnalysisFixtures.fresh_analysis_runs_fixture(gate_scope(ctx), Run.sources(), commit: commit)

  test "a candidate lands on main as its exact commit", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    clean_runs_at(ctx, a.commit)

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed}} = settle(entry)
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == a.commit
    assert git!(ctx.main_root, ["describe", "--tags", "--exact-match", "HEAD"]) == "v0.1.1"
  end

  # 2026-10-06: the gate held a candidate's new files untracked, its merge was
  # refused, and the queue rebuilt the same batch for hours.
  test "a candidate whose new file is left untracked in the gate lands", ctx do
    a = candidate(ctx, "a", "main", "new.ex", "a\n")
    File.write!(Path.join(ctx.gate_root, "new.ex"), "left over\n")
    clean_runs_at(ctx, a.commit)

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed}} = settle(entry)
  end

  test "a candidate that conflicts is ejected and the rest land", ctx do
    a = candidate(ctx, "a", "main", "app.ex", "a's App\n")
    b = candidate(ctx, "b", "main", "app.ex", "b's App\n")
    clean_runs_at(ctx, a.commit)

    [entry_a, entry_b] = [queue(ctx, a), queue(ctx, b)]
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry_b)
    assert result["reason"] =~ "app.ex"
    assert {:ok, %{status: :landed}} = settle(entry_a)
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == a.commit
  end

  test "a red candidate is ejected with its findings, and nothing lands", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "broken\n")
    gate = gate_scope(ctx)
    clean_runs_at(ctx, a.commit)
    problem_fixture(gate, %{source: "compiler", severity: :error, file_path: "a.ex"})
    problem_fixture(gate, %{source: "compiler", severity: :error, file_path: "a.ex", line: 2})

    entry = queue(ctx, a)
    before = git!(ctx.main_root, ["rev-parse", "HEAD"])
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry)
    assert result["reason"] =~ "a.ex"
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == before
  end

  # 87bc9721, 2026-10-05: the gate refused on exunit while spex was still running
  # at the head, and triage re-read the copy's problems for every source —
  # spex's included, from its run at the commit before. A finding red on main
  # was blamed on the candidate. Problems are kept per copy, not per commit:
  # triage reads the ones the gate judged.
  test "a red batch is triaged on what the gate judged at its head, not older runs", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "broken\n")
    own = gate_scope(ctx)

    AnalysisFixtures.fresh_analysis_runs_fixture(own, ~w(compiler exunit spex), commit: a.commit)

    AnalysisFixtures.fresh_analysis_runs_fixture(own, ["credo"],
      commit: String.duplicate("0", 40)
    )

    problem_fixture(own, %{source: "exunit", severity: :error, file_path: "test/a_test.exs"})
    problem_fixture(own, %{source: "credo", severity: :error, file_path: "lib/stale.ex"})

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry)
    assert result["reason"] =~ "test/a_test.exs"

    refute result["reason"] =~ "lib/stale.ex",
           "a finding from another commit's run was blamed on this candidate"
  end

  @tag gate: :later
  test "a gate copy coming up wakes the batch waiting for it", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    clean_runs_at(ctx, a.commit)
    entry = queue(ctx, a)

    # The gate's checkout is not there yet: the batch cannot be built, and the
    # worker waits to retry.
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    assert {:error, :timeout} = PromotionQueue.await(entry, 500)

    gate_checkout(ctx.main_root, ctx.gate_root, :now)
    :ok = PromotionQueue.copy_joined(ctx.scope, ctx.gate)

    assert {:ok, %{status: :landed}} = settle(entry)
  end

  # Main moved under a green batch — something committed to it another way.
  # It cannot land as certified: it is rebuilt on the new main and gated again
  # at once, not after a retry period, and nothing is ejected.
  test "a batch main moved under is rebuilt on the new main at once, not ejected", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    clean_runs_at(ctx, a.commit)

    # A run in flight on another copy holds the green batch at its landing.
    main_scope = %{ctx.scope | active_working_copy_id: ctx.main.id}
    in_flight = AnalysisFixtures.analysis_run_fixture(main_scope, %{source: "compiler"})

    first = queue(ctx, a)
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, Repository.topic(ctx.scope.active_project_id))
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert_receive {:promotion_queue, %{id: id, status: :gating, batch_id: batch}}
                   when id == first.id,
                   5_000

    File.write!(Path.join(ctx.main_root, "elsewhere.ex"), "elsewhere\n")
    git!(ctx.main_root, ["add", "-A"])
    git!(ctx.main_root, ["commit", "-q", "-m", "committed to main another way"])
    moved = git!(ctx.main_root, ["rev-parse", "HEAD"])

    {:ok, _} = RunsRepository.finish_run(in_flight, :completed, %{})

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "analysis:#{ctx.scope.active_project_id}",
      {:analysis,
       %{
         source: "compiler",
         status: :completed,
         run_id: in_flight.id,
         working_copy_id: ctx.main.id
       }}
    )

    assert_receive {:promotion_queue, %{id: id, status: :gating, batch_id: rebuilt}}
                   when id == first.id and rebuilt != batch,
                   5_000

    assert git!(ctx.gate_root, ["merge-base", "--is-ancestor", moved, "HEAD"]) == ""
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == moved

    refute Repository.get(first.id).status in [:ejected, :landed]
  end

  # A run that fails at the batch commit is red like a finding, and not retried:
  # the candidate's own change may be what stops the analyzer running. (The
  # first live batch, 2026-10-05: a gate copy minted without its envs could not
  # boot the test suite. That is the gate copy's to fix, and it ejects too.)
  test "a candidate whose gate run fails is ejected, naming the analyzer", ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    agent = an_agent(ctx, a.copy)

    {:ok, entry} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: a.copy.id,
        commit: a.commit,
        restart: false,
        requested_by_agent_id: agent.id
      })

    :ok = PromotionQueue.ensure_worker(ctx.scope)

    # Its recheck, without waiting out the interval. (Runs fail synchronously
    # here, inside the gate that started them; over a harness each failure
    # re-gates.)
    [{worker, _}] =
      Registry.lookup(CodeMySpec.PromotionQueue.Registry, ctx.scope.active_project_id)

    :sys.get_state(worker)
    send(worker, :gate)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry)
    assert result["reason"] =~ "could not run at the batch commit"

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, told}, 10_000
    assert told =~ "was taken out of the queue"
  end

  defp an_agent(ctx, copy) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: copy.root,
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    agent
  end

  # A candidate main already contains has nothing to gate or land: it lands as
  # it is, at once, and no analyzer runs against main on its behalf — main's
  # own flake once ejected a candidate whose work had already landed
  # (2026-10-05).
  test "a candidate already on main lands as it is, without a gate", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    git!(ctx.main_root, ["merge", "--quiet", "--ff-only", a.commit])

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed, result: result}} = settle(entry)
    assert result["already_on_main"] == true
    assert Run |> Repo.all() |> Enum.filter(&(&1.working_copy_id == ctx.gate.id)) == []
  end

  # 966ee65a, 2026-10-05: an entry already on main, queued again, rode a batch
  # with another candidate as a no-op merge — gated, and exposed to that
  # candidate's findings. It lands the moment it is picked instead.
  test "a candidate already on main lands at once, not in a batch with others", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    git!(ctx.main_root, ["merge", "--quiet", "--ff-only", a.commit])
    b = candidate(ctx, "b", "main", "b.ex", "b\n")

    [on_main, _other] = [queue(ctx, a), queue(ctx, b)]
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed, result: result}} = settle(on_main)
    assert result["already_on_main"] == true, "it rode a batch: #{inspect(result)}"
  end

  # A lone candidate's own copy is reused only for a certification it already
  # holds; anything still to run goes to the gate copy, out of reach of whoever
  # keeps editing the requester's copy.
  test "a lone candidate certified on its own copy is gated there, and nothing runs", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    own = %{ctx.scope | active_working_copy_id: a.copy.id}
    AnalysisFixtures.fresh_analysis_runs_fixture(own, Run.sources(), commit: a.commit)

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed}} = settle(entry)
    assert Run |> Repo.all() |> Enum.filter(&(&1.working_copy_id == ctx.gate.id)) == []
  end

  test "a lone candidate its own copy has not certified is gated in the gate copy", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    clean_runs_at(ctx, a.commit)

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed}} = settle(entry)
    assert git!(ctx.gate_root, ["rev-parse", "HEAD"]) == a.commit

    assert Run |> Repo.all() |> Enum.filter(&(&1.working_copy_id == a.copy.id)) == [],
           "a run was started in the requester's own copy"
  end

  # 3c59be47, 2026-10-05: a landing restarts the harness, which orphans the
  # next gate's first runs. Those say nothing about whether the gate copy can
  # run them, and counting them held a batch whose analyzers ran fine.
  test "runs a harness going away orphaned are not failures of the batch", ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    agent = an_agent(ctx, a.copy)
    gate = gate_scope(ctx)
    AnalysisFixtures.fresh_analysis_runs_fixture(gate, ~w(compiler credo spex), commit: a.commit)
    a_harness_for(ctx.gate.id, ctx.gate_root)

    {:ok, _entry} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: a.copy.id,
        commit: a.commit,
        restart: false,
        requested_by_agent_id: agent.id
      })

    :ok = PromotionQueue.ensure_worker(ctx.scope)

    [{worker, _}] =
      Registry.lookup(CodeMySpec.PromotionQueue.Registry, ctx.scope.active_project_id)

    gate_id = ctx.gate.id

    # Twice the gate copy's harness goes away mid-run, and twice the run is
    # started again on the recheck.
    for _restart <- 1..2 do
      assert_receive {:run_analysis_on, ^gate_id, [%{"source" => "exunit"}]}, 15_000
      {:ok, 1} = Analysis.fail_in_flight(gate, :harness_disconnected)
      send(worker, :gate)
    end

    assert_receive {:run_analysis_on, ^gate_id, [%{"source" => "exunit"}]}, 15_000
    :sys.get_state(worker)

    agent_id = agent.id

    refute_received {:agent_dispatch, ^agent_id, _ref, _told},
                    "the batch was failed over runs its harness going away orphaned"
  end

  # 2026-10-05, 08:41: the gate copy's harness restarted while its batch was
  # gating, and what it had been asked to run went with the connection. Its
  # rejoin asks the gate again, now, rather than at the next recheck.
  test "a batch gating asks the gate again when the gate copy rejoins", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    gate = gate_scope(ctx)
    AnalysisFixtures.fresh_analysis_runs_fixture(gate, ~w(compiler credo spex), commit: a.commit)
    a_harness_for(ctx.gate.id, ctx.gate_root)

    queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    gate_id = ctx.gate.id
    assert_receive {:run_analysis_on, ^gate_id, [%{"source" => "exunit"}]}, 15_000
    {:ok, 1} = Analysis.fail_in_flight(gate, :harness_disconnected)

    :ok = PromotionQueue.copy_joined(ctx.scope, ctx.gate)

    assert_receive {:run_analysis_on, ^gate_id, [%{"source" => "exunit"}]},
                   5_000,
                   "the rejoin did not ask again; the batch waits out the recheck"
  end
end
