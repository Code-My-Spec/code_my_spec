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
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.PromotionQueue.Worker
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
      answer()
    end)

    assert_receive :registered, 2_000
  end

  defp answer do
    receive do
      {:"$gen_call", from, {_verb, _request}} ->
        GenServer.reply(from, @reloaded)
        answer()
    end
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

  test "a batch lands on main as its exact commit, every candidate in it landed", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    b = candidate(ctx, "b", "a", "b.ex", "b\n")
    clean_runs_at(ctx, b.commit)

    entries = [queue(ctx, a), queue(ctx, b)]
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    for entry <- entries do
      assert {:ok, %{status: :landed}} = settle(entry)
    end

    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == b.commit
    assert git!(ctx.main_root, ["describe", "--tags", "--exact-match", "HEAD"]) == "v0.1.1"
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
    # A lone candidate level with main is gated on its own copy.
    a = candidate(ctx, "a", "main", "a.ex", "broken\n")
    own = %{ctx.scope | active_working_copy_id: a.copy.id}
    AnalysisFixtures.fresh_analysis_runs_fixture(own, Run.sources(), commit: a.commit)
    problem_fixture(own, %{source: "compiler", severity: :error, file_path: "a.ex"})
    problem_fixture(own, %{source: "compiler", severity: :error, file_path: "a.ex", line: 2})

    entry = queue(ctx, a)
    before = git!(ctx.main_root, ["rev-parse", "HEAD"])
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry)
    assert result["reason"] =~ "a.ex"
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == before
  end

  @tag gate: :later
  test "a gate copy coming up wakes the batch waiting for it", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    b = candidate(ctx, "b", "a", "b.ex", "b\n")
    clean_runs_at(ctx, b.commit)
    entries = [queue(ctx, a), queue(ctx, b)]

    # The gate's checkout is not there yet: the batch cannot be built, and the
    # worker waits to retry.
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    assert {:error, :timeout} = PromotionQueue.await(hd(entries), 500)

    gate_checkout(ctx.main_root, ctx.gate_root, :now)
    :ok = PromotionQueue.copy_joined(ctx.scope, ctx.gate)

    for entry <- entries do
      assert {:ok, %{status: :landed}} = settle(entry)
    end
  end

  # Main moved under a green batch — something committed to it another way.
  # It cannot land as certified: it is rebuilt on the new main and gated again
  # at once, not after a retry period, and nothing is ejected.
  test "a batch main moved under is rebuilt on the new main at once, not ejected", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    b = candidate(ctx, "b", "a", "b.ex", "b\n")
    clean_runs_at(ctx, b.commit)

    # A run in flight on another copy holds the green batch at its landing.
    main_scope = %{ctx.scope | active_working_copy_id: ctx.main.id}
    in_flight = AnalysisFixtures.analysis_run_fixture(main_scope, %{source: "compiler"})

    [first | _] = entries = [queue(ctx, a), queue(ctx, b)]
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

    for entry <- entries,
        do: refute(Repository.get(entry.id).status in [:ejected, :landed])
  end

  # An analyzer that cannot run on the gate copy fails rather than answering;
  # the gate would start it again every recheck, forever. Started a third time
  # at the same commit, the batch is held and its requester told — nothing
  # ejected, nothing landed. (The first live batch, 2026-10-05: a gate copy
  # minted without its envs could not boot the test suite.)
  test "a batch whose gate cannot run an analyzer is held, not looped", ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    b = candidate(ctx, "b", "a", "b.ex", "b\n")
    agent = an_agent(ctx, b.copy)

    {:ok, _} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: a.copy.id,
        commit: a.commit,
        restart: false
      })

    {:ok, entry} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: b.copy.id,
        commit: b.commit,
        restart: false,
        requested_by_agent_id: agent.id
      })

    :ok = PromotionQueue.ensure_worker(ctx.scope)
    agent_id = agent.id

    # Its rechecks, without waiting out the interval: each one finds the runs
    # failed and starts them again, until the third start holds the batch.
    [{worker, _}] =
      Registry.lookup(CodeMySpec.PromotionQueue.Registry, ctx.scope.active_project_id)

    :sys.get_state(worker)
    send(worker, :gate)
    :sys.get_state(worker)
    refute_received {:agent_dispatch, ^agent_id, _, _}
    send(worker, :gate)

    assert_receive {:agent_dispatch, ^agent_id, _ref, told}, 10_000
    assert told =~ "the gate copy cannot run"
    assert told =~ "nothing was taken out"
    assert %{status: :gating} = Repository.get(entry.id)
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
end
