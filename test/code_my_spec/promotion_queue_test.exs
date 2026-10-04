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

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.PromotionQueue.Worker
  alias CodeMySpec.WorkingCopies

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
  setup do
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
    git!(main_root, ["worktree", "add", "--detach", gate_root, "main"])

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

    %{scope: scope, main_root: main_root, main: main, gate: gate}
  end

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
end
