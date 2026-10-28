defmodule CodeMySpec.PromotionQueueTest do
  @moduledoc """
  The queue end to end on a local checkout: candidates are batched in the gate
  copy, gated once, and a green batch lands on main as its exact commit; a
  conflicting candidate is ejected without blocking the rest; a red candidate
  is ejected with its findings and nothing lands.

  `async: true`: the queue's worker is a process under the application's
  supervisor, so it reads through the shared sandbox.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpecTest.PromotionQueueHelpers
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Promotion.Steps
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
    local_promotion_project(scope)
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

    :ok =
      register_working_copy_execution_context(
        %{scope | active_working_copy_id: main.id},
        ExecutionContext.new(:local, main_root)
      )

    {:ok, gate} =
      WorkingCopies.issue(scope, nil, label: Worker.gate_label(), device: device_fixture(scope))

    {:ok, gate} = WorkingCopies.report_root(gate, gate_root)

    :ok =
      register_working_copy_execution_context(
        %{scope | active_working_copy_id: gate.id},
        ExecutionContext.new(:local, gate_root)
      )

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

      {:cancel_analysis, reason} ->
        send(test, {:cancel_analysis_on, working_copy_id, reason})
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

    :ok =
      register_working_copy_execution_context(
        %{ctx.scope | active_working_copy_id: copy.id},
        ExecutionContext.new(:local, root)
      )

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

  test "a production queue without origin cannot fall back to the desktop", ctx do
    Application.put_env(:code_my_spec, :local_promotion_projects, [])
    a = candidate(ctx, "missing-origin", "main", "a.ex", "a\n")
    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    # The call synchronizes with the worker's initial attempt.
    state = :sys.get_state(GenServer.whereis(Worker.via(ctx.scope.active_project_id)))
    assert state.phase == :idle
    assert Repository.get(entry.id).status == :queued
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) != a.commit
  end

  test "remote publication uses the source gate while the desktop destination is offline", ctx do
    Application.put_env(:code_my_spec, :local_promotion_projects, [])
    remote = CodeMySpec.TempFile.dir("queue-origin")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare", "-q"])
    on_exit(fn -> File.rm_rf(remote) end)
    git!(ctx.main_root, ["remote", "add", "origin", remote])
    git!(ctx.main_root, ["push", "-q", "origin", "main"])
    a = candidate(ctx, "remote-a", "main", "a.ex", "a\n")

    {:ok, _} =
      ctx.gate
      |> Ecto.Changeset.change(label: "promotion-gate:#{a.copy.id}", device_id: a.copy.device_id)
      |> Repo.update()

    clean_runs_at(ctx, a.commit)
    # Destination cannot be consulted; the gate shares only source objects.
    {:ok, _} = WorkingCopies.report_root(ctx.main, "/missing/offline/desktop")
    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    assert {:ok, %{status: :landed}} = settle(entry)
    assert git!(remote, ["rev-parse", "refs/heads/main"]) == a.commit
    assert git!(a.copy.root, ["rev-parse", "HEAD"]) == a.commit
    assert {:ok, gate} = WorkingCopies.fetch(ctx.gate.id)
    assert gate.label == Worker.gate_label(a.copy.device_id)
  end

  test "gate retirement refuses an alias of the source checkout", ctx do
    alias_root = CodeMySpec.TempFile.dir("queue-source-alias")
    File.rm_rf!(alias_root)
    File.ln_s!(ctx.main_root, alias_root)
    on_exit(fn -> File.rm(alias_root) end)

    env = ExecutionContext.new(:local, ctx.main_root)

    assert {:error, %{reason: "refusing to remove the source checkout as a gate"}} =
             Steps.retire_gate_worktree(env, ctx.main_root, alias_root)

    assert File.exists?(Path.join(ctx.main_root, "app.ex"))
  end

  test "a device shares its gate and retires surplus legacy worktrees", ctx do
    Application.put_env(:code_my_spec, :local_promotion_projects, [])
    remote = CodeMySpec.TempFile.dir("queue-origin")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare", "-q"])
    on_exit(fn -> File.rm_rf(remote) end)
    git!(ctx.main_root, ["remote", "add", "origin", remote])
    git!(ctx.main_root, ["push", "-q", "origin", "main"])
    a = candidate(ctx, "remote-share-a", "main", "share_a.ex", "a\n")

    {:ok, _} =
      ctx.gate
      |> Ecto.Changeset.change(
        label: Worker.gate_label(a.copy.device_id),
        device_id: a.copy.device_id
      )
      |> Repo.update()

    obsolete_root = CodeMySpec.TempFile.dir("queue-obsolete-gate")
    File.rm_rf!(obsolete_root)
    git!(a.copy.root, ["worktree", "add", "--detach", obsolete_root, "HEAD"])
    on_exit(fn -> File.rm_rf(obsolete_root) end)

    {:ok, obsolete} =
      WorkingCopies.issue(ctx.scope, nil,
        label: "promotion-gate:#{a.copy.id}",
        device: device_fixture(ctx.scope)
      )

    {:ok, obsolete} =
      obsolete
      |> Ecto.Changeset.change(device_id: a.copy.device_id)
      |> Repo.update()

    {:ok, obsolete} = WorkingCopies.report_root(obsolete, obsolete_root)
    clean_runs_at(ctx, a.commit)
    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    assert {:ok, %{status: :landed}} = settle(entry)
    assert {:error, _} = WorkingCopies.fetch(obsolete.id)
    refute File.exists?(obsolete_root)
    assert {:ok, gate} = WorkingCopies.fetch(ctx.gate.id)
    assert gate.label == Worker.gate_label(a.copy.device_id)

    b = candidate(ctx, "remote-share-b", "remote-share-a", "share_b.ex", "b\n")

    {:ok, b_copy} =
      b.copy
      |> Ecto.Changeset.change(device_id: a.copy.device_id)
      |> Repo.update()

    b = %{b | copy: b_copy}
    clean_runs_at(ctx, b.commit)
    second = queue(ctx, b)
    :ok = PromotionQueue.ensure_worker(%{ctx.scope | active_working_copy_id: b_copy.id})
    assert {:ok, %{status: :landed}} = settle(second)

    assert Enum.count(
             WorkingCopies.list_harnesses(ctx.scope),
             &(&1.label == Worker.gate_label(a.copy.device_id))
           ) == 1
  end

  test "an already published remote head must acquire a certification receipt", ctx do
    Application.put_env(:code_my_spec, :local_promotion_projects, [])
    remote = CodeMySpec.TempFile.dir("queue-origin")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare", "-q"])
    on_exit(fn -> File.rm_rf(remote) end)
    git!(ctx.main_root, ["remote", "add", "origin", remote])
    git!(ctx.main_root, ["push", "-q", "origin", "main"])
    a = candidate(ctx, "remote-a", "main", "a.ex", "a\n")

    {:ok, _} =
      ctx.gate
      |> Ecto.Changeset.change(label: "promotion-gate:#{a.copy.id}", device_id: a.copy.device_id)
      |> Repo.update()

    git!(a.copy.root, ["push", "-q", "origin", "HEAD:main"])
    clean_runs_at(ctx, a.commit)
    # Destination cannot be consulted; the gate shares only source objects.
    {:ok, _} = WorkingCopies.report_root(ctx.main, "/missing/offline/desktop")
    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    assert {:ok, %{status: :landed} = landed} = settle(entry)
    assert is_binary(landed.result["promotion_id"])

    assert git!(remote, [
             "rev-parse",
             "refs/codemyspec/promotions/" <> landed.result["promotion_id"]
           ]) == a.commit

    assert git!(remote, ["rev-parse", "refs/heads/main"]) == a.commit
    assert git!(a.copy.root, ["rev-parse", "HEAD"]) == a.commit
  end

  test "a candidate lands on main as its exact commit", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    clean_runs_at(ctx, a.commit)

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed, result: result}} = settle(entry)
    timing = result["timing"]
    assert timing["gate_copy_id"] == ctx.gate.id
    assert length(timing["run_ids"]) == length(Run.sources())
    assert Enum.all?(timing["run_ids"], &is_integer/1)
    assert is_integer(timing["stages"]["queue-wait"])
    assert is_integer(timing["stages"]["gate-build"])
    assert is_integer(timing["stages"]["asset-build"])
    assert is_integer(timing["stages"]["landing"])
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == a.commit
    assert git!(ctx.main_root, ["describe", "--tags", "--exact-match", "HEAD"]) == "v0.1.1"
  end

  # 2026-10-11: a story candidate refused at landing for QA not at its commit
  # went back to the head of the queue and was refused again every cycle,
  # holding every candidate behind it. Only its team can fix that.
  test "a story candidate whose QA is not at its commit is ejected, and the next lands", ctx do
    story = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope)
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    b = candidate(ctx, "b", "main", "b.ex", "b\n")
    clean_runs_at(ctx, a.commit)
    spex = "test/spex/#{story.number}_feature/criterion_1_spex.exs"

    {_n, _} =
      CodeMySpec.Files.upsert_files(%{ctx.scope | active_working_copy_id: a.copy.id}, [
        %{path: spex, role: :bdd_spec, story_id: story.id, valid: true, mtime: DateTime.utc_now()}
      ])

    {:ok, unreviewed} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: a.copy.id,
        commit: a.commit,
        restart: false,
        subject_type: :story,
        subject_id: Integer.to_string(story.number)
      })

    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(unreviewed)
    assert inspect(result) =~ "needs QA"

    # Re-queued, the refused entry would be older than this one and taken first.
    clean_runs_at(ctx, b.commit)
    behind = queue(ctx, b)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed}} = settle(behind), "the refused story held the queue"
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

  # a0ad4e06: a 2026-10-14 promotion (2664c442b) conflicted with main itself --
  # not with another queued candidate -- and the queue retried "could not
  # build a batch" forever instead of ejecting it. The test above only ever
  # conflicts a candidate against a SIBLING already merged into the batch
  # (`merged` is non-empty, so the `{[], unaccounted}` branch in
  # `build_in_gate_copy/3` is never exercised); this drives the single, lone
  # candidate shape where `merged` stays empty and the `Enum.reject(...,
  # conflicted)` fallback is what has to clear it.
  test "a lone candidate that conflicts with main itself is ejected, not retried forever", ctx do
    a = candidate(ctx, "a", "main", "app.ex", "a's App\n")

    # Someone else's promotion lands on main directly, after `a` branched,
    # touching the same line `a` touches -- so when the queue builds `a`'s
    # batch, it conflicts with main's own HEAD, not with a sibling entry.
    File.write!(Path.join(ctx.main_root, "app.ex"), "someone else's App\n")
    git!(ctx.main_root, ["add", "-A"])
    git!(ctx.main_root, ["commit", "-q", "-m", "landed first"])

    clean_runs_at(ctx, a.commit)
    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry),
           "a lone candidate conflicting with main was retried instead of ejected"

    assert result["reason"] =~ "app.ex"
  end

  # 41644862: 8733d80d8 conflicted with main in a file and in the
  # `.code_my_spec` submodule pointer at once. `git merge --abort` failed
  # under `submodule.recurse`, so the gate kept the half-merge and the next
  # step compiled its conflict markers, reporting "could not reset the
  # gate's test database" instead of naming the conflict.
  test "a candidate conflicting with main in a file and the docs pointer is rejected naming both, and the gate ends clean",
       ctx do
    seed = CodeMySpec.TempFile.dir("conflict-seed")
    origin = CodeMySpec.TempFile.dir("conflict-origin")
    File.mkdir_p!(seed)
    File.mkdir_p!(origin)

    on_exit(fn ->
      File.rm_rf(seed)
      File.rm_rf(origin)
    end)

    git!(origin, ["init", "-q", "--bare", "--initial-branch=main"])
    git!(seed, ["init", "-q", "--initial-branch=main"])
    git!(seed, ["config", "user.email", "q@example.com"])
    git!(seed, ["config", "user.name", "Q"])
    git!(seed, ["commit", "-q", "--allow-empty", "-m", "docs"])
    git!(seed, ["push", "-q", origin, "main"])

    git!(ctx.main_root, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "-q",
      origin,
      ".code_my_spec"
    ])

    git!(ctx.main_root, ["add", ".code_my_spec", ".gitmodules"])
    git!(ctx.main_root, ["commit", "-q", "-m", "add docs"])

    root = CodeMySpec.TempFile.dir("queue-conflict")
    File.rm_rf!(root)
    git!(ctx.main_root, ["worktree", "add", "-q", "-b", "conflict", root, "main"])
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(root, "app.ex"), "candidate's App\n")
    git!(root, ["add", "app.ex"])

    git!(root, [
      "update-index",
      "--cacheinfo",
      "160000,#{String.duplicate("a", 40)},.code_my_spec"
    ])

    git!(root, ["commit", "-q", "-m", "candidate"])
    candidate_commit = git!(root, ["rev-parse", "HEAD"])

    {:ok, copy} =
      WorkingCopies.issue(ctx.scope, nil, label: "conflict", device: device_fixture(ctx.scope))

    {:ok, copy} = WorkingCopies.report_root(copy, root)

    :ok =
      register_working_copy_execution_context(
        %{ctx.scope | active_working_copy_id: copy.id},
        ExecutionContext.new(:local, root)
      )

    # Main diverges on its own, after the candidate branched -- the same
    # file, differently, and the docs pointer, differently -- so the gate's
    # merge conflicts on both at once, the shape 8733d80d8 hit.
    File.write!(Path.join(ctx.main_root, "app.ex"), "main's App\n")
    git!(ctx.main_root, ["add", "app.ex"])

    git!(ctx.main_root, [
      "update-index",
      "--cacheinfo",
      "160000,#{String.duplicate("b", 40)},.code_my_spec"
    ])

    git!(ctx.main_root, ["commit", "-q", "-m", "main diverges"])
    main_commit = git!(ctx.main_root, ["rev-parse", "HEAD"])

    entry = queue(ctx, %{copy: copy, commit: candidate_commit})
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry),
           "a candidate conflicting with main in a file and the docs pointer was not ejected"

    assert result["reason"] =~ "app.ex"
    assert result["reason"] =~ ".code_my_spec"
    assert result["reason"] =~ String.slice(candidate_commit, 0, 12)
    assert result["reason"] =~ String.slice(main_commit, 0, 12)
    assert result["reason"] =~ "Merge the current development branch"

    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == main_commit
    assert git!(ctx.gate_root, ["status", "--porcelain", "--ignore-submodules"]) == ""

    {merge_head, _} =
      System.cmd("git", ["rev-parse", "-q", "--verify", "MERGE_HEAD"],
        cd: ctx.gate_root,
        stderr_to_stdout: true
      )

    assert merge_head == ""
  end

  test "a new queue entry retries an earlier red source and reuses green runs", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    gate = gate_scope(ctx)
    clean_runs_at(ctx, a.commit)
    previous = RunsRepository.latest_completed_run(gate, "credo")
    problem_fixture(gate, %{source: "credo", severity: :warning, file_path: "a.ex"})

    entry = queue(ctx, a)
    a_harness_for(ctx.gate.id, ctx.gate_root)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    gate_id = ctx.gate.id
    assert_receive {:run_analysis_on, ^gate_id, runs}, 5_000
    assert Enum.map(runs, & &1["source"]) == ["credo"]
    assert Repository.get(entry.id).status == :gating
    assert RunsRepository.latest_completed_run(gate, "credo").id == previous.id
  end

  test "a red candidate is ejected with its findings, and nothing lands", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "broken\n")
    entry = queue(ctx, a)
    gate = gate_scope(ctx)
    clean_runs_at(ctx, a.commit)
    problem_fixture(gate, %{source: "compiler", severity: :error, file_path: "a.ex"})
    problem_fixture(gate, %{source: "compiler", severity: :error, file_path: "a.ex", line: 2})

    before = git!(ctx.main_root, ["rev-parse", "HEAD"])
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry)
    assert result["reason"] =~ "a.ex"
    # Every step's timing survives to the ejection, not only the last write.
    timing = result["timing"]
    assert timing["gate_copy_id"] == gate.active_working_copy_id
    assert is_integer(timing["stages"]["queue-wait"])
    assert is_integer(timing["stages"]["gate-build"])
    assert [_ | _] = timing["run_ids"]
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == before
  end

  # Issue 47567b2a: none of compiler, credo, exunit or spex run the
  # project's asset pipeline, so story 1092's own broken `echarts` import
  # failed esbuild from the moment the batch landed, with every analyzer
  # green.
  test "a broken asset build is ejected, and nothing lands", ctx do
    mix_exs = """
    defmodule App.MixProject do
      use Mix.Project

      def project, do: [app: :app, version: "0.1.0"]
    end
    """

    a = candidate(ctx, "a", "main", "mix.exs", mix_exs)
    clean_runs_at(ctx, a.commit)

    entry = queue(ctx, a)
    before = git!(ctx.main_root, ["rev-parse", "HEAD"])
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry)
    assert result["reason"] =~ "assets"
    timing = result["timing"]
    assert is_integer(timing["stages"]["asset-build"])
    refute Map.has_key?(timing["stages"], "landing")
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == before
  end

  # 0dc0f327: promotion formats the candidate and commits the result as its own
  # commit before gating, and what the agent is told names that commit.
  test "a candidate that is not formatted is formatted in its own commit before gating", ctx do
    mix_exs = """
    defmodule App.MixProject do
      use Mix.Project

      def project, do: [app: :app, version: "0.1.0"]
    end
    """

    a = candidate(ctx, "a", "main", "mix.exs", mix_exs)
    {:ok, %{root: root}} = WorkingCopies.fetch(a.copy.id)
    File.write!(Path.join(root, ".formatter.exs"), "[inputs: [\"*.ex\"]]\n")
    File.write!(Path.join(root, "loose.ex"), "defmodule   Loose  do\nend\n")
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "--amend", "--no-edit"])
    a = %{a | commit: git!(root, ["rev-parse", "HEAD"])}

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    # No runs exist at the batch commit, so the gate ejects it; what matters is
    # the commit it was gated at and what the ejection says about it. The gate
    # is asked again without waiting out the recheck interval.
    [{worker, _}] =
      Registry.lookup(CodeMySpec.PromotionQueue.Registry, ctx.scope.active_project_id)

    :sys.get_state(worker)
    send(worker, :gate)

    assert {:ok, %{status: :ejected, result: %{"reason" => reason}}} = settle(entry)
    assert reason =~ "ran mix format before gating"
    assert reason =~ "loose.ex"

    format_commit = git!(ctx.gate_root, ["log", "-1", "--format=%H", "--grep=Promotion format"])
    assert reason =~ format_commit
    assert git!(ctx.gate_root, ["show", "--stat", "--format=", format_commit]) =~ "loose.ex"
    assert git!(ctx.main_root, ["rev-parse", "main"]) != format_commit
  end

  # 2026-10-12: a batch ejected on its first finding left its other analyzers
  # running in the gate copy, and the next batch reset the tree under them.
  test "an ejected batch's runs in the gate copy are stopped", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "broken\n")
    entry = queue(ctx, a)
    gate = gate_scope(ctx)
    clean_runs_at(ctx, a.commit)
    problem_fixture(gate, %{source: "compiler", severity: :error, file_path: "a.ex"})
    a_harness_for(ctx.gate.id, ctx.gate_root)

    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected}} = settle(entry)
    gate_id = ctx.gate.id
    assert_receive {:cancel_analysis_on, ^gate_id, reason}, 5_000
    assert reason =~ "left the gate"
  end

  test "the next batch is not built while a run is still going in the gate copy", ctx do
    gate = gate_scope(ctx)
    a_harness_for(ctx.gate.id, ctx.gate_root)
    gate_id = ctx.gate.id
    _ = Analysis.start_run(gate, "exunit", [])
    assert_receive {:run_analysis_on, ^gate_id, _left_running}, 5_000
    assert Analysis.running_on?(gate)

    b = candidate(ctx, "b", "main", "b.ex", "b\n")
    entry = queue(ctx, b)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert_receive {:cancel_analysis_on, ^gate_id, reason}, 5_000
    assert reason =~ "needed for the next batch"

    [{worker, _}] =
      Registry.lookup(CodeMySpec.PromotionQueue.Registry, ctx.scope.active_project_id)

    :sys.get_state(worker)
    assert Repository.get(entry.id).status == :queued

    {:ok, _closed} = Analysis.fail_in_flight(gate, :cancelled)
    send(worker, :next)
    assert_receive {:run_analysis_on, ^gate_id, _runs}, 15_000
  end

  # 87bc9721, 2026-10-05: the gate refused on exunit while spex was still running
  # at the head, and triage re-read the copy's problems for every source —
  # spex's included, from its run at the commit before. A finding red on main
  # was blamed on the candidate. Problems are kept per copy, not per commit:
  # triage reads the ones the gate judged.
  test "a red batch is triaged on what the gate judged at its head, not older runs", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "broken\n")
    entry = queue(ctx, a)
    own = gate_scope(ctx)

    AnalysisFixtures.fresh_analysis_runs_fixture(own, ~w(compiler exunit spex), commit: a.commit)

    AnalysisFixtures.fresh_analysis_runs_fixture(own, ["credo"],
      commit: String.duplicate("0", 40)
    )

    problem_fixture(own, %{source: "exunit", severity: :error, file_path: "test/a_test.exs"})
    problem_fixture(own, %{source: "credo", severity: :error, file_path: "lib/stale.ex"})

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

    # The gate's checkout is not there yet: the candidate is not taken, and
    # waits queued rather than being ejected for something that is not its.
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    assert {:error, :timeout} = PromotionQueue.await(entry, 500)
    assert Repository.get(entry.id).status == :queued

    gate_checkout(ctx.main_root, ctx.gate_root, :now)
    :ok = PromotionQueue.copy_joined(ctx.scope, ctx.gate)

    assert {:ok, %{status: :landed}} = settle(entry)
  end

  # A disk cleanup removed the gate's folder and left its record: the queue took
  # the record for the gate and refused every batch on its unreadable HEAD.
  test "a gate copy whose checkout is gone is retired and asked for again", ctx do
    test = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:code_my_spec, :promotion_queue, :gate_copy_needed],
      fn _event, _measurements, metadata, _config -> send(test, {:gate_needed, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok = WorkingCopies.observe_paths(ctx.gate.device_id, %{ctx.gate.id => false})
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    queue(ctx, a)

    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert_receive {:gate_needed, %{label: label}}, 5_000
    assert label == Worker.gate_label()
    refute Enum.any?(WorkingCopies.list_harnesses(ctx.scope), &(&1.id == ctx.gate.id))
  end

  # A candidate that stopped short of a verdict used to be requeued, where it
  # headed the queue again and failed the same way every five minutes, holding
  # everything behind it. Once taken, it leaves.
  test "a candidate the gate copy cannot be reset for is ejected, not retried", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    git_dir = git!(ctx.gate_root, ["rev-parse", "--absolute-git-dir"])
    File.write!(Path.join(git_dir, "index.lock"), "")
    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :ejected, result: result}} = settle(entry)
    assert result["reason"] =~ "could not gate it"
    assert result["reason"] =~ "index.lock"
  end

  # Main moved under a green batch — something committed to it another way.
  # It cannot land as certified: it is rebuilt on the new main and gated again
  # at once, not after a retry period, and nothing is ejected.
  # 2026-10-13: a green batch waited up to thirty minutes for any run on any
  # other copy, and with two teams one was nearly always going.
  test "a green batch lands while another copy has a run in flight", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    clean_runs_at(ctx, a.commit)

    main_scope = %{ctx.scope | active_working_copy_id: ctx.main.id}
    _in_flight = AnalysisFixtures.analysis_run_fixture(main_scope, %{source: "compiler"})

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed}} = settle(entry)
  end

  test "a batch main moved under is rebuilt on the new main at once, not ejected", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    gate = gate_scope(ctx)

    # Exunit unanswered, so the batch waits at the gate for it while main moves.
    AnalysisFixtures.fresh_analysis_runs_fixture(gate, ~w(compiler credo spex), commit: a.commit)
    a_harness_for(ctx.gate.id, ctx.gate_root)

    first = queue(ctx, a)
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, Repository.topic(ctx.scope.active_project_id))
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert_receive {:promotion_queue, %{id: id, status: :gating, batch_id: batch}}
                   when id == first.id and is_binary(batch),
                   5_000

    gate_id = ctx.gate.id
    assert_receive {:run_analysis_on, ^gate_id, [%{"source" => "exunit"}]}, 15_000

    File.write!(Path.join(ctx.main_root, "elsewhere.ex"), "elsewhere\n")
    git!(ctx.main_root, ["add", "-A"])
    git!(ctx.main_root, ["commit", "-q", "-m", "committed to main another way"])
    moved = git!(ctx.main_root, ["rev-parse", "HEAD"])

    [exunit] = RunsRepository.running_full_runs(gate, "exunit")
    {:ok, exunit} = RunsRepository.finish_run(exunit, :completed, %{exit_status: 0})

    RunsRepository.record_tree(exunit, %{
      start_commit: a.commit,
      start_tree_dirty: false,
      completed_commit: a.commit
    })

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "analysis:#{ctx.scope.active_project_id}",
      {:analysis,
       %{source: "exunit", status: :completed, run_id: exunit.id, working_copy_id: gate_id}}
    )

    assert_receive {:promotion_queue, %{id: id, status: :gating, batch_id: rebuilt}}
                   when id == first.id and is_binary(rebuilt) and rebuilt != batch,
                   5_000

    assert git!(ctx.gate_root, ["merge-base", "--is-ancestor", moved, "HEAD"]) == ""
    assert git!(ctx.main_root, ["rev-parse", "HEAD"]) == moved

    refute Repository.get(first.id).status in [:ejected, :landed]
  end

  test "a key socket startup failure retries ExUnit without ejecting the candidate", ctx do
    a = candidate(ctx, "socket-retry", "main", "socket_retry.ex", "ok\n")
    gate = gate_scope(ctx)
    AnalysisFixtures.fresh_analysis_runs_fixture(gate, ~w(compiler credo spex), commit: a.commit)
    a_harness_for(ctx.gate.id, ctx.gate_root)

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    gate_id = ctx.gate.id
    assert_receive {:run_analysis_on, ^gate_id, [%{"source" => "exunit"}]}, 15_000
    [first] = RunsRepository.running_full_runs(gate, "exunit")

    reason =
      {:test_suite_did_not_run, :sops_key_socket_address_in_use, 1,
       "CmsHarness.SopsKeySocket listener exited with :eaddrinuse"}

    {:ok, failed} =
      CodeMySpec.Analysis.Reconciler.fail(first, reason, %{
        output: "CmsHarness.SopsKeySocket listener exited with :eaddrinuse",
        exit_status: 1
      })

    assert failed.status == :failed
    assert failed.stats["error"] =~ "sops_key_socket_address_in_use"

    [{worker, _}] =
      Registry.lookup(CodeMySpec.PromotionQueue.Registry, ctx.scope.active_project_id)

    send(worker, :gate)
    assert_receive {:run_analysis_on, ^gate_id, [%{"source" => "exunit"}]}, 15_000
    assert Repository.get(entry.id).status == :gating
  end

  # A run that fails at the batch commit is red like a finding, and not retried:
  # the candidate's own change may be what stops the analyzer running. (The
  # first live batch, 2026-10-05: a gate copy minted without its envs could not
  # boot the test suite. That is the gate copy's to fix, and it ejects too.)
  test "a candidate whose gate run fails is ejected, naming the analyzer", ctx do
    RecordingAgentTransport.listen(ctx)

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

  # 1d65a84e: the landed notice used the same fire-and-forget, wake-gated
  # dispatch as every other agent message -- Wake is asked, and can hold,
  # BEFORE anything is ever recorded (Agents.dispatch_message/4,5,6's own
  # `with {:ok, agent} <- ..., :ok <- wake(...), ... <- record_admission(...)`
  # chain), so an agent unreachable at the instant do_land/1 ran lost the one
  # message its open promote_issue/story_promoted task depended on, with
  # nothing left to retry it.
  #
  # Reproduced deterministically here, not via the original report's
  # two-sender timing race (confirmed real -- 5 of 8 repeated runs against
  # the pre-fix code lost the landed dispatch to a second, independently-timed
  # sender -- but inherently nondeterministic, and not something to leave as
  # a standing flake in a suite every team's promotions run through): an
  # agent genuinely unreachable, not a timing window, at the moment its
  # promotion lands.
  test "a landed promotion reaches its agent even if it was unreachable at that instant", ctx do
    RecordingAgentTransport.listen(ctx)

    a = candidate(ctx, "a", "main", "a.ex", "a\n")

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: a.copy.root,
        working_copy_id: a.copy.id
      })

    # Deliberately no AgentPresence.present(agent) -- unlike an_agent/2's own
    # agents, this one is not reachable right now, the exact condition the
    # old path silently dropped the landed notice on.

    clean_runs_at(ctx, a.commit)

    {:ok, entry} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: a.copy.id,
        commit: a.commit,
        restart: false,
        requested_by_agent_id: agent.id
      })

    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed}} = settle(entry)

    # `settle/1` returns on the entry's own :landed status, broadcast BEFORE
    # `tell_landed/3` runs -- its own admission (a separate DB write) is not
    # guaranteed to have landed yet. Poll rather than assert immediately.
    mailbox_entry = eventually_mailbox_entry(agent.id)

    assert mailbox_entry.state == :queued,
           "the landed notice was not durably queued for an unreachable agent"

    message = Repo.get!(Message, mailbox_entry.message_id)
    assert Message.text(message) =~ "landed on main"

    assert message.delivery == :pending,
           "the landed notice's own record disagrees with having been durably queued"

    # The agent reconnects; its next pump delivers what was waiting for it.
    AgentPresence.present(agent)
    assert {:ok, :started} = Mailbox.pump(ctx.scope, agent.id)

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, told}, 5_000
    assert told =~ "landed on main"
  end

  # 2026-10-15: 71d28513's fix was ejected while its coder was not running, and
  # the fire-and-forget notice was dropped; the coder waited 90 minutes.
  test "an ejected promotion reaches its agent even if it was unreachable at that instant",
       ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: a.copy.root,
        working_copy_id: a.copy.id
      })

    git_dir = git!(ctx.gate_root, ["rev-parse", "--absolute-git-dir"])
    File.write!(Path.join(git_dir, "index.lock"), "")

    {:ok, entry} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: a.copy.id,
        commit: a.commit,
        restart: false,
        requested_by_agent_id: agent.id
      })

    :ok = PromotionQueue.ensure_worker(ctx.scope)
    assert {:ok, %{status: :ejected}} = settle(entry)

    mailbox_entry = eventually_mailbox_entry(agent.id)

    assert mailbox_entry.state == :queued,
           "the ejection notice was not durably queued for an unreachable agent"

    assert Repo.get!(Message, mailbox_entry.message_id) |> Message.text() =~
             "taken out of the queue"
  end

  defp eventually_mailbox_entry(agent_id, attempts \\ 50)

  defp eventually_mailbox_entry(agent_id, 0) do
    Repo.get_by(Mailbox.Entry, agent_id: agent_id) ||
      raise "no mailbox entry ever appeared for agent #{agent_id}"
  end

  defp eventually_mailbox_entry(agent_id, attempts) do
    Repo.get_by(Mailbox.Entry, agent_id: agent_id) || retry_mailbox_entry(agent_id, attempts)
  end

  defp retry_mailbox_entry(agent_id, attempts) do
    Process.sleep(10)
    eventually_mailbox_entry(agent_id, attempts - 1)
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

  # 8951606c/52d2006d, 2026-10-05: a candidate an earlier batch had already
  # carried forward -- an ancestor of main, never its own tip -- was gated as
  # though new and ejected over a failure nothing on it could have produced.
  # `on_main/3`'s ancestry check, not `gating/5`'s equality against main's
  # exact HEAD, is what has to catch this: the candidate's own commit is no
  # longer main's tip by the time it is re-queued.
  test "a candidate main has since moved past still lands as already on main", ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    git!(ctx.main_root, ["merge", "--quiet", "--ff-only", a.commit])

    moved = candidate(ctx, "b", "main", "b.ex", "b\n")
    git!(ctx.main_root, ["merge", "--quiet", "--ff-only", moved.commit])

    entry = queue(ctx, a)
    :ok = PromotionQueue.ensure_worker(ctx.scope)

    assert {:ok, %{status: :landed, result: result}} = settle(entry)
    assert result["already_on_main"] == true
    assert Run |> Repo.all() |> Enum.filter(&(&1.working_copy_id == ctx.gate.id)) == []
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

  test "runtime disk operations use the selected copy registry, not a stale scope environment",
       ctx do
    a = candidate(ctx, "a", "main", "a.ex", "a\n")
    clean_runs_at(ctx, a.commit)

    entry = queue(ctx, a)
    stale_scope = %{ctx.scope | cwd: "/wrong/remote/root"}
    :ok = PromotionQueue.ensure_worker(stale_scope)

    assert {:ok, %{status: :landed}} = settle(entry)
    assert git!(ctx.gate_root, ["rev-parse", "HEAD"]) == a.commit
  end

  # 3c59be47, 2026-10-05: a landing restarts the harness, which orphans the
  # next gate's first runs. Those say nothing about whether the gate copy can
  # run them, and counting them held a batch whose analyzers ran fine.
  test "runs a harness going away orphaned are not failures of the batch", ctx do
    RecordingAgentTransport.listen(ctx)

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
