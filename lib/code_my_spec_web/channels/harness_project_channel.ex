defmodule CodeMySpecWeb.HarnessProjectChannel do
  @moduledoc """
  The **data plane** for one working copy: the channel a light harness holds
  while it serves that checkout.

  Distinct from `HarnessChannel`, which is account-scoped and relays an agent's
  conversation to the operator inbox. This one is scoped to a working copy and
  carries the work — sync results, analysis results, hook decisions.

  ## Two checkouts of one project both serve

  They used to not. Files and problems were keyed by project, so each harness's
  full reconcile deleted the other's rows and the requirement graph described
  neither checkout — which is why joining used to take a project-wide advisory
  lock and refuse the second harness outright.

  Both are keyed on the harness now, so there is nothing left for that lock to
  protect and it is gone: no `project_leases`, no advisory lock, no expiry.
  Two working copies of one project are two harnesses, and both serve.

  What is still refused is a second harness on the *same* working copy. Not for
  the files — two processes reading one disk produce manifests that agree — but
  for the toolchain: `mix test` and `mix spex` share a single `_build`, and two
  at once corrupt it into reporting failures that are not in the code. That is
  a registry entry held for the life of the channel, which is all it needs to
  be.

  ## Why a channel rather than REST

  Liveness. The registry entry, the analysis executor slot and the in-flight
  run ledger all key off "is this harness still here", and REST has no such
  signal — it would need an expiry and a heartbeat, which is a timer
  compensating for a deadline. A socket closing says it exactly.
  """

  use CodeMySpecWeb, :channel

  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.AgentHarness.ConversationRecorder
  alias CodeMySpec.Analysis
  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.ReconcileRegistry
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Harnesses
  alias CodeMySpec.Hooks.AskUserQuestion
  alias CodeMySpec.Hooks.NotificationHook
  alias CodeMySpec.Hooks.PostToolUse
  alias CodeMySpec.Hooks.PreToolUse
  alias CodeMySpec.Hooks.SessionStart
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Hooks.SubagentStart
  alias CodeMySpec.Hooks.SubagentStop
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope

  @impl true
  def join("harness_project:" <> project_id, payload, socket) do
    label = harness_label(payload)

    with :ok <- check_contract(payload, project_id),
         {:ok, scope} <- authorize(socket, project_id),
         {:ok, harness} <- Harnesses.issue(scope, payload["harness_id"], label: label),
         {:ok, harness} <- report_root(harness, payload["root"]),
         # Everything below is per working copy, so the scope carries the
         # harness — and the working copy itself — before any of it runs.
         scope = put_harness_scope(scope, harness),
         :ok <- take_working_copy(harness, payload) do
      # Anything still `:running` belongs to a previous connection. Its queue
      # was on a harness that has gone, so nothing will ever finish it — and an
      # open run makes every later stop report analysis pending, which allows
      # the stop while saying results will apply next time, on a next time that
      # never arrives. This is the one moment it is provably safe to close them.
      Analysis.fail_in_flight(scope, :harness_reconnected, claimed_runs(payload))

      # The id goes back in the join reply whether it was just minted or
      # recognised. A harness that already holds one gets the same value and
      # writes nothing; one joining a checkout for the first time writes it
      # down, so its next restart is the same harness rather than a second.
      # Every read and write this channel makes is about *this* working copy.
      # Carrying the harness on the scope is what makes that true by default,
      # rather than something each call site has to remember — and forgetting it
      # returns another checkout's files with no error to notice.
      {:ok, %{harness_id: harness.id},
       socket
       |> assign(:scope, scope)
       |> assign(:harness, harness)
       # One reconcile in flight, at most one waiting. See `accept_manifest/2`.
       |> assign(:reconciling, nil)
       |> assign(:pending_manifest, nil)}
    else
      # Two harness processes on one working copy. Their manifests agree — they
      # read the same disk — so files and problems are safe either way now that
      # both are keyed on the harness. What is not safe is the toolchain: `mix
      # test` and `mix spex` share one `_build`, and two at once corrupt it into
      # reporting failures that are not in the code.
      #
      # That is the whole of what still needs single ownership, and it is a
      # registry entry rather than a lease: no table, no expiry, no advisory
      # lock, and it goes when the channel does.
      # A refusal that already built its own payload passes through. The clause
      # below calls `to_string/1`, which raises on a map — so a well-formed
      # refusal would arrive at the agent as "join crashed", which is both wrong
      # and the most alarming thing it could say. Caught by the contract test
      # before it ever ran for real.
      {:error, %{} = refusal} ->
        {:error, refusal}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid topic"}}

  # The channel contract this server speaks. Kept in step with
  # `CmsHarness.Project.ChannelClient`'s copy — the two *are* the contract, so
  # they are the two places that have to agree. Bump on a change to the join
  # payload, the `handle_in` set, or the shapes those carry.
  @contract_version 1

  @doc """
  The channel contract version this server speaks.

  Public so a test can compare it against `CmsHarness.Project.ChannelClient`'s
  copy. Hardcoding either number in a test would assert `1 == 1` and keep
  passing after somebody bumped one side and forgot the other — which is
  precisely the skew this whole mechanism exists to catch.
  """
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  # Say "these two disagree about the contract" outright.
  #
  # Skew surfaced as `{:error, %{"reason" => "unmatched topic"}}` on every stop
  # — a message about topics for a problem about versions — and was diagnosable
  # only because the refusal wrapper appends the harness's boot commit and its
  # checkout's current one, leaving the reader to run `git diff --stat <range>
  # -- lib/cms_harness lib/code_my_spec_web/channels` and notice the contract
  # had moved. That worked, and it is too much to ask of a message that fires on
  # every stop (c8a7f11d).
  #
  # It refuses rather than warns because a harness on the wrong contract cannot
  # do its job: every hook it forwards is refused anyway, and the refusal it
  # gets today names the wrong thing. Better to fail at the join, once, with the
  # two numbers in the message.
  defp check_contract(%{"contract_version" => version}, _project_id)
       when version == @contract_version,
       do: :ok

  defp check_contract(%{"contract_version" => version}, project_id) when is_integer(version) do
    Logger.warning(
      "[HarnessProject] refused a harness on contract v#{version} for #{project_id}; " <>
        "this server speaks v#{@contract_version}"
    )

    {:error,
     %{
       reason: "contract_version_mismatch",
       harness_contract: version,
       server_contract: @contract_version,
       detail:
         "This harness speaks channel contract v#{version} and the server speaks " <>
           "v#{@contract_version}. Restart the harness from a checkout level with the " <>
           "server — `just refresh-harness` — rather than looking at the network."
     }}
  end

  # A harness that predates the field. Allowed, because refusing it would make
  # this change require a coordinated rollout, and the same reasoning already
  # governs `active_runs` and `harness_id` in the same payload. It is logged
  # once per join rather than silently accepted: if skew is what is wrong, the
  # absence is itself the clue, and `unmatched topic` will be along shortly.
  defp check_contract(_payload, project_id) do
    Logger.info(
      "[HarnessProject] a harness joined #{project_id} without a contract version; " <>
        "it predates the field. Server speaks v#{@contract_version}."
    )

    :ok
  end

  # Runs the joining harness says it is still executing.
  #
  # Only integers it actually sent. A harness that predates this field sends
  # nothing and everything is swept, which is what happened before — so the
  # rollout order does not matter.
  defp claimed_runs(%{"active_runs" => ids}) when is_list(ids),
    do: Enum.filter(ids, &is_integer/1)

  defp claimed_runs(_payload), do: []

  @doc """
  Hand the harness the small slice of the domain that scanning needs.

  `Files.Scanner` is already the device half of sync: it walks the working
  copy, hashes it, and decides whether each spec is valid, and its own moduledoc
  notes that none of that needs a database and that no file content ever leaves
  it. The one thing it does need is a `ReadModel` — component module names, the
  project's story ids, and whether validation is strict.

  So this is the whole of what a database-less harness requires in order to
  produce a manifest. It is small and it changes slowly, which is why it is
  fetched rather than inferred.
  """
  @impl true
  def handle_in("read_model", _payload, socket) do
    read_model = Files.read_model(socket.assigns.scope)

    {:reply, {:ok, serialize_read_model(read_model)}, socket}
  end

  # Take a harness's whole observation set and reconcile it into File rows.
  #
  # The manifest, not a delta. Sending only what changed would be smaller and
  # would make a deletion indistinguishable from an omission — the server would
  # keep rows for files that had gone, and that surfaces much later as a
  # requirement graph citing a spec nobody can find. The full set is what makes
  # the result verifiable.
  #
  # Costs about 150 bytes a file, so a 4,300-file project is roughly 650 KB.
  # Nothing here carries file content: validation already happened on the
  # harness, and only its verdict travels.
  #
  # An empty manifest is refused rather than obeyed. Reconciling one would
  # delete every file row the project has, and over a wire "the scan found
  # nothing" and "the scan did not run" arrive as the same empty list. A
  # genuinely empty project has no rows to lose, so refusing costs nothing and
  # a harness bug stops being indistinguishable from an empty checkout.
  # A completed model turn from the sprite's proxy. The records live here
  # because this is where the operator reads them — the sprite holds a working
  # copy, the server holds what happened, same split as observations.
  #
  # Never replies. The harness sends this as a cast and the agent's turn was
  # answered long before it arrived; a reply would only be something for nobody
  # to wait on. A failure is logged and dropped, and the operator sees the gap.
  def handle_in("record_turn", payload, socket) do
    scope = socket.assigns.scope

    _ =
      ConversationRecorder.record_turn(
        scope.active_account_id,
        scope.active_project_id,
        session_external_id(scope, payload),
        payload["request"] || %{},
        payload["response"] || %{},
        payload["agent_role"] || "main"
      )

    {:noreply, socket}
  end

  def handle_in("observations", %{"observations" => []}, socket) do
    {:reply, {:error, %{"reason" => "empty_manifest"}}, socket}
  end

  def handle_in("observations", %{"observations" => observations}, socket)
      when is_list(observations) do
    # A manifest is proof of life for a harness whose agent may not be firing
    # hooks — the scanner runs on its own. Join alone was not enough: a stable
    # connection never re-joins, so `last_seen_at` aged past the reclaim window
    # while the harness was demonstrably working.
    Harnesses.mark_alive(socket.assigns.scope.active_harness_id)

    case deserialize_observations(observations) do
      {:ok, entries} ->
        {:reply, {:ok, %{"status" => "accepted", "observations" => length(entries)}},
         accept_manifest(socket, entries)}

      {:error, problems} ->
        # Usually version skew: a harness classifying files into roles this
        # server has never heard of. Writing those as nil would land wrong rows
        # and surface later as a requirement graph nobody can explain, so the
        # manifest is rejected whole and the reasons are named.
        #
        # Still synchronous, deliberately: this is the one answer the harness
        # can act on, and it is cheap to compute.
        Logger.warning("[HarnessProject] rejected manifest: #{inspect(problems)}")

        {:reply, {:error, %{"reason" => "invalid_manifest", "problems" => problems}}, socket}
    end
  end

  # Decide a hook the harness is proxying for Claude Code.
  #
  # The decision is mostly database work — blocking problems, config modes,
  # session and task state — so it lives here, while the analyzers that feed it
  # shell out against a working copy and stay on the harness. This is the same
  # split the local controllers already use; they call the identical `Hooks.*`
  # modules, so the two paths cannot drift in what they decide, only in how they
  # are reached.
  #
  # **Mostly**, not entirely, and the difference is why this runs in a task.
  # Task evaluation reads files — `QaIntegrationPlan` alone reads an index, each
  # spec and each verify script, and `CodeGeneration`, `QaSetup` and `Deploy` do
  # the same. A read goes out as `handle_call({:fs_request, …})` on *this*
  # process, so deciding inline meant the channel calling itself: OTP detects it
  # and exits at once with `{:calling_self, …}`, 3,270 times in one `web.log`.
  #
  # Every one of those was a failed read that the caller could not tell from a
  # missing file — `check_index/1`'s catch-all reports "Integration index not
  # found. Write it and stop again" for a file that is sitting right there. So
  # this was not log noise; it was task evaluation being told the working copy
  # was empty, on the critical path of every agent turn (`f530595e`).
  #
  # Same shape as `analysis_wait` below, and for the same reason: the channel
  # process has to stay free to answer `fs_result`, because it is the only thing
  # that can.
  def handle_in("hook_decision", %{"hook" => hook, "payload" => payload} = msg, socket)
      when is_binary(hook) and is_map(payload) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope
    port = msg["port"]

    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Phoenix.Channel.reply(ref, decision_reply(hook, scope, payload, port))
    end)

    {:noreply, socket}
  end

  # What an analyzer printed on the machine that has the working copy.
  #
  # The split this carries: the harness has the disk and the toolchain, so it
  # runs `mix`; the `Problem` schema and the run ledger are here, so this
  # converts and records. The harness sends diagnostics, never Problems —
  # `Analysis.record_remote_result/2` puts them through the same
  # `Runners.from_raw/2` a local run goes through, which is what stops the two
  # paths disagreeing about what a diagnostic means.
  #
  # The reply is read on the far side. A rejected result is an analyzer that ran
  # and was not recorded, which looks from the outside exactly like one that
  # never ran — the distinction this whole design exists to keep.
  #
  # Deferred, like `hook_decision` and `analysis_run`, and for the reason the
  # `{:calling_self, …}` warning in `Analysis.harness_fs_request/4` already
  # names: "a reconcile running inline in the channel process reached for a
  # file". `Reconciler`'s own moduledoc says it "runs inside the analysis Task —
  # never inside a GenServer callback"; that held for the local queue and was
  # never true of this path, which is the remote half of the same reconcile.
  def handle_in("analysis_result", %{"run_id" => _, "source" => source} = payload, socket) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope

    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Phoenix.Channel.reply(ref, result_reply(scope, source, payload))
    end)

    {:noreply, socket}
  end

  # The agent's own `mix test`, routed through here so it counts.
  #
  # It did not count before. The PreToolUse rewrite requires `scope.cwd`, which a
  # light harness has no business setting — a server with no disk has no working
  # directory, and the modules that read `cwd` would read the wrong tree. So the
  # rewrite silently did not fire, the agent's suite ran unrecorded, and the stop
  # hook then ran the same suite again because as far as this server was
  # concerned nothing had. Observed: 118 seconds of exunit immediately after the
  # agent had finished exactly that run.
  #
  # Deferred reply, not a blocking call. `await_run/4` takes as long as the suite
  # does, and holding the channel for it starves the stop decision behind it —
  # the same defect the manifest reconcile had. `socket_ref/1` is what lets the
  # answer outlive the call that asked for it.
  def handle_in("analysis_run", %{"source" => source} = payload, socket)
      when is_binary(source) do
    args = List.wrap(payload["args"] || [])
    ref = socket_ref(socket)
    scope = socket.assigns.scope

    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Phoenix.Channel.reply(ref, run_for_agent(scope, source, args))
    end)

    {:noreply, socket}
  end

  # Wait until this project's analyzers are idle, then report.
  #
  # Replied out of band like `analysis_run` above, because the wait is minutes:
  # a sweep runs 200-590s. Holding the channel process for that would block
  # every other message the harness sends.
  #
  # This exists as a channel message, and reaches the agent as an HTTP endpoint,
  # because the same wait as an MCP tool could not return — MCP's transport caps
  # a request at 30s, so it answered `-32603 Server unavailable` every time it
  # was needed.
  def handle_in("analysis_wait", _payload, socket) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope

    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      result = CodeMySpec.Analysis.await_all(scope, timeout: :timer.minutes(20))

      Phoenix.Channel.reply(
        ref,
        {:ok, %{"state" => to_string(result), "summary" => wait_summary(scope)}}
      )
    end)

    {:noreply, socket}
  end

  # The harness's answer to a filesystem request. See `handle_call/3` below.
  def handle_in("fs_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(socket.assigns[:pending_fs] || %{}, ref)
    if from, do: GenServer.reply(from, decode_fs_result(msg))
    {:noreply, assign(socket, :pending_fs, pending)}
  end

  # An unknown event is answered, not dropped.
  #
  # This clause used to be `{:noreply, socket}`, and that silence was a real
  # defect: the harness pushed `hook_decision` before this server implemented it,
  # got no reply, and sat out its full timeout on every single hook. Both test
  # suites were green throughout, because the harness tests against a fake that
  # did implement it.
  #
  # A reply saying "I do not know that event" is the difference between a version
  # skew that announces itself and one that reads as latency.
  def handle_in(event, _payload, socket) do
    Logger.warning("[HarnessProject] unknown event #{inspect(event)}")
    {:reply, {:error, %{"reason" => "unknown_event", "event" => event}}, socket}
  end

  # A filesystem operation for the working copy this channel serves.
  #
  # The transport half of `Environments.Harness`: this side only carries the
  # message, the harness applies it with its own `Environments` implementation
  # against the disk that actually holds the checkout. Writes as well as reads —
  # a spec stub has to be written where the working copy is.
  #
  # Replied out of band. The caller's `from` is parked against a ref and
  # answered by `handle_in("fs_result", …)`, so the channel process is not
  # blocked while the far side does disk work.
  @impl true
  def handle_call({:fs_request, op, payload}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "fs_request", %{"ref" => ref, "op" => op, "payload" => payload})

    {:noreply, assign(socket, :pending_fs, Map.put(pending_fs(socket), ref, from))}
  end

  defp pending_fs(socket), do: socket.assigns[:pending_fs] || %{}

  # Always answers, including when the decision raises.
  #
  # Deciding inline, a crash took the channel down and the harness saw the
  # socket close — bad, but loud. From a task it would kill nothing and send
  # nothing, and the harness would sit out its full decision timeout on every
  # turn, which reads as latency rather than as a crash. This is the hot path of
  # every agent turn; silence is the one answer it must never give.
  defp decision_reply(hook, scope, payload, port) do
    case decide_hook(hook, scope, payload, port) do
      {:error, reason} -> {:error, %{"reason" => reason}}
      {200, body} -> {:ok, body}
      {status, body} when is_integer(status) -> {:error, %{"status" => status, "body" => body}}
    end
  rescue
    exception ->
      Logger.error(
        "[HarnessProject] #{hook} decision crashed: #{Exception.message(exception)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:error, %{"reason" => "decision_crashed", "hook" => hook}}
  end

  # Same contract as before, moved off the channel process. The two warnings
  # below are unchanged: "already closed" and "belongs to another checkout" read
  # identically without them, and the second — every join sweeping every other
  # working copy's runs — once hid a total failure for a day behind a message
  # that looked like an ordinary reconnect.
  defp result_reply(scope, source, payload) do
    case Analysis.record_remote_result(scope, payload) do
      {:ok, run} ->
        {:ok, %{"run_id" => run.id, "status" => to_string(run.status)}}

      # Not applied: reconciling it would rewrite this source's Problems off a
      # run nobody is waiting for.
      {:error, :unknown_run} ->
        Logger.warning(
          "[HarnessProject] #{source} result for run #{payload["run_id"]} not recorded: " <>
            Analysis.explain_unknown_run(scope, payload["run_id"])
        )

        {:error, %{"reason" => "unknown_run"}}

      {:error, reason} ->
        Logger.warning("[HarnessProject] #{source} result rejected: #{inspect(reason)}")
        {:error, %{"reason" => inspect(reason)}}
    end
  rescue
    exception ->
      Logger.error(
        "[HarnessProject] #{source} result crashed while recording: " <>
          Exception.message(exception)
      )

      {:error, %{"reason" => "record_crashed", "source" => source}}
  end

  # The harness reports outcomes the way the behaviour states them, so this only
  # has to put the shape back together. An `error` is kept as an atom because
  # callers match on `:enoent` and friends.
  defp decode_fs_result(%{"error" => reason}) when is_binary(reason),
    do: {:error, String.to_atom(reason)}

  defp decode_fs_result(%{"ok" => true, "result" => result}), do: {:ok, result}
  defp decode_fs_result(%{"ok" => true}), do: :ok
  defp decode_fs_result(other), do: {:error, {:unreadable_fs_result, other}}

  defp wait_summary(scope) do
    counts =
      scope
      |> CodeMySpec.Problems.list_project_problems([])
      |> Enum.group_by(& &1.source)
      |> Map.new(fn {source, problems} -> {source, length(problems)} end)

    scope
    |> CodeMySpec.Analysis.status()
    |> Enum.map_join("\n", fn {source, %{state: state}} ->
      "- #{source}: #{state}, #{Map.get(counts, source, 0)} problem(s)"
    end)
  end

  # `Analysis` dispatches a run by sending here, because the executor it looked
  # up in `HarnessRegistry` is this process. It arrives as a plain message
  # rather than a broadcast so that the thing proving the harness is alive and
  # the thing the work is sent to are the same pid.
  #
  # Note this can be sent *by this process to itself*: the stop hook is decided
  # inside `handle_in("hook_decision", …)`, which is what enqueues the runs. The
  # message lands after that call returns, which is the right order — the
  # decision is made from what has already been recorded, never from what is
  # about to run.
  @impl true
  def handle_info({:run_analysis, runs}, socket) do
    push(socket, "run_analysis", %{"runs" => runs})
    {:noreply, socket}
  end

  # The counts the harness used to receive in its reply. Logged here instead,
  # because the reply now leaves before they exist.
  def handle_info({ref, counts}, %{assigns: %{reconciling: %Task{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])

    # Named by working copy. This line carried counts and no identity, so ten
    # reconciles alternating between two checkouts read as one healthy sync
    # repeating — while one of those checkouts was being emptied on every pass.
    Logger.info(
      "[HarnessProject] reconciled #{socket.assigns.harness.root || socket.assigns.harness.id}: " <>
        "#{counts.upserted} upserted, #{counts.removed} removed, " <>
        "#{counts.changed} changed, #{counts.components} components"
    )

    {:noreply, next_manifest(socket)}
  end

  # A reconcile that died takes its manifest with it. The next scan sends the
  # whole set again — which is what makes a manifest safe to lose — so this says
  # so and moves on rather than retrying a snapshot that has since aged.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{reconciling: %Task{ref: ref}}} = socket
      ) do
    Logger.error("[HarnessProject] reconcile failed: #{inspect(reason)}")
    {:noreply, next_manifest(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Reconciling a 2071-row manifest takes long enough that a stop decision
  # queued behind it blows the harness's 10s timeout, and the agent is told
  # "the harness never got to ask" — which reads as a server fault when the
  # server is fine and the decision simply never got a turn.
  #
  # So the channel tracks the work instead of doing it. It cannot merely spawn
  # and forget: `reconcile/2` takes the *whole* observation set and removes rows
  # absent from it, so two running at once would delete each other's files.
  # Ordering has to survive, and today it survives only because this process is
  # busy.
  #
  # One in flight, one pending, newest wins. A superseded manifest describes a
  # tree that no longer exists — the same reasoning that makes a second queued
  # analyzer run pointless.
  #
  # Inline under `analysis_mode: :inline` — the test env. A task started from
  # here runs in a process the SQL sandbox has never heard of, so it would find
  # no connection at all. The *reply* is identical either way, on purpose: the
  # thing worth asserting is what production sends, and only the timing differs.
  # Same trade the analysis executor already makes.
  # The agent reads this as test output, so the tool's own text is the body and
  # everything else is a footer. An error still answers in that shape — the
  # alternative is a curl that prints nothing and exits 0, which reads as a
  # suite that passed.
  defp run_for_agent(scope, source, args) do
    case Analysis.await_run(scope, source, args) do
      {:ok, %{} = run} ->
        {:ok,
         %{
           "run_id" => run.id,
           "status" => to_string(run.status),
           "output" => run.output || "",
           "exit_status" => run.exit_status,
           "stats" => run.stats || %{}
         }}

      {:error, reason} ->
        Logger.warning("[HarnessProject] #{source} run for the agent failed: #{inspect(reason)}")
        {:error, %{"reason" => inspect(reason)}}
    end
  end

  defp accept_manifest(socket, entries) do
    cond do
      Application.get_env(:code_my_spec, :analysis_mode) == :inline ->
        reconcile(socket.assigns.scope, entries)
        socket

      socket.assigns.reconciling == nil ->
        assign(socket, :reconciling, start_reconcile(socket.assigns.scope, entries))

      true ->
        assign(socket, :pending_manifest, entries)
    end
  end

  defp start_reconcile(scope, entries) do
    Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fn ->
      # Marked by the task, not by this function, so the entry lives exactly as
      # long as the work and needs no cleanup — when the task exits, registered
      # or crashed, the marker goes with it.
      ReconcileRegistry.mark(scope.active_harness_id, length(entries))
      reconcile(scope, entries)
    end)
  end

  # Both halves, in one transaction, in the context that owns the database.
  #
  # Reconciling files is only half of a sync. The other half turns those files
  # into components and — the part that matters here — writes `component_id`
  # back onto each File row. Without it every `implementation_file` requirement
  # stays unsatisfied forever: the check is scoped to a component's own files,
  # and a file nothing owns is invisible to it. Drill 11 finished the entire
  # project chain, wrote every module, passed 157 tests, and still showed 15
  # implementation requirements open with all 66 implementation files synced and
  # not one of them linked.
  #
  # The local path has always run both (see `Tools.SyncProject`). This one ran
  # only the first, and could not have run the second until `ComponentSync`
  # stopped needing to read the files itself — the component identity now
  # travels in the File record, which is what makes it possible at all.
  #
  # The transaction lives in `FileSync`, not here: `CodeMySpecWeb` may not
  # reference `CodeMySpec.Repo`, and Boundary is right about that — a channel
  # opening a database transaction is the wrong shape regardless of whether the
  # compiler catches it. See `reconcile_and_project/2` for the timeout and for
  # the harness-read caveat.
  defp reconcile(scope, entries), do: FileSync.reconcile_and_project(scope, entries)

  defp next_manifest(%{assigns: %{pending_manifest: nil}} = socket) do
    assign(socket, :reconciling, nil)
  end

  defp next_manifest(%{assigns: %{pending_manifest: entries}} = socket) do
    socket
    |> assign(:reconciling, start_reconcile(socket.assigns.scope, entries))
    |> assign(:pending_manifest, nil)
  end

  # Everything this harness had running dies with it: the queue was on the other
  # machine. Leaving those rows `:running` would make every later stop for this
  # project report analysis pending — an allow, with a note that results apply
  # next time, forever.
  @impl true
  # Why the channel died, not just that it did.
  #
  # This discarded `reason` until now, and the harness could not supply it
  # either: a channel process that crashes sends `phx_error` with no payload, so
  # the far side logs `closed: {:error, %{}}` and the empty map is all it ever
  # learns. The one process that knows was throwing it away.
  #
  # That cost a day. Seven crashes over one evening were indistinguishable from
  # seven network drops, and the sweep below turned each into a batch of results
  # the server would later refuse as `unknown_run` — which is what was actually
  # investigated, three times, from the wrong end.
  #
  # Deliberately loud. A disconnect here is not routine: it fails every run this
  # working copy has open, while the analyzers themselves are OS processes on
  # the harness that keep running regardless. Their results arrive for runs that
  # are no longer `:running` and are refused. Nothing retries.
  def terminate(reason, socket) do
    case socket.assigns[:scope] do
      %Scope{active_project_id: id} when not is_nil(id) ->
        log_disconnect(reason, socket)
        Analysis.fail_in_flight(socket.assigns.scope, failure_reason(reason))

      _ ->
        :ok
    end

    :ok
  end

  # Say which of the two things happened, because they read identically and
  # only one of them is about the working copy.
  #
  # Phoenix drains its channels on shutdown, so `{:shutdown, :draining}` means
  # the *server* went away — someone restarted :4000 — and every in-flight run
  # for every working copy dies with it, since one harness serves them all.
  # Recording that as `:harness_disconnected` sent agents looking for a harness
  # problem they did not have: a 12-minute spex sweep returning
  # `:not_connected`, a completed sweep whose latch did not flip, three hours
  # read as analyzer-queue starvation. Three separate wrong theories, each
  # ending at "somebody else restarted the server" (406f85db).
  #
  # The timestamp is the part that ends the investigation. An agent that can see
  # its sweep died at the moment of a restart stops looking at its own code.
  defp failure_reason({:shutdown, :draining}) do
    "the shared dev server was restarted at " <>
      DateTime.to_iso8601(DateTime.utc_now()) <>
      " — this run was killed by that restart, not by anything in your working " <>
      "copy or its analyzers"
  end

  defp failure_reason(_reason), do: :harness_disconnected

  # The harness leaving on purpose — a restart, a shutdown. Worth a line,
  # because it still strands whatever was running, but not an alarm.
  defp log_disconnect(reason, socket)
       when reason in [:normal, :shutdown, {:shutdown, :left}, {:shutdown, :closed}] do
    Logger.info("[HarnessProject] channel closed (#{inspect(reason)}) topic=#{socket.topic}")
  end

  defp log_disconnect(reason, socket) do
    Logger.error(
      "[HarnessProject] channel DIED topic=#{socket.topic} reason=#{death_reason(reason)}" <>
        " — every in-flight run for this working copy is about to be failed as" <>
        " :harness_disconnected. The analyzers keep running on the harness and" <>
        " their results will be refused as unknown_run. Fix the crash, not the sweep."
    )
  end

  # The reason, legibly. This is the one line that says why the channel died,
  # and `inspect(reason, limit: 12)` truncated it before it got to the point:
  #
  #     reason={%Protoc
  #
  # A real crash cost an hour behind that. The cause was
  # `{:error, :not_supported_on_harness}` handed to `Enum.filter/2`, and finding
  # it meant grepping the raw logfmt for the sibling `gen_server terminate`
  # report — which is exactly the work this line exists to save.
  #
  # A crash arrives as `{exception, stacktrace}`, so it is formatted as one:
  # the banner names what broke and the first frames name where. Bounded at
  # five frames rather than unbounded, because a channel that dies in a loop
  # would otherwise fill the log with the same trace.
  defp death_reason({exception, stacktrace}) when is_list(stacktrace) do
    Exception.format_banner(:error, exception) <>
      "\n" <> Exception.format_stacktrace(Enum.take(stacktrace, 5))
  rescue
    # Not every two-tuple with a list in it is a crash. Anything this cannot
    # format is still worth printing whole.
    _ -> inspect({exception, stacktrace}, limit: :infinity, printable_limit: 2048)
  end

  defp death_reason(reason), do: inspect(reason, limit: :infinity, printable_limit: 2048)

  # `port` is the harness's own — the analysis curl that `pre-tool-use` rewrites
  # points at `http://localhost:<port>/api/analysis/run`, which only means
  # anything on the machine running the agent. The server cannot know it and
  # must not guess it, so a rewrite without one is refused rather than pointed
  # somewhere plausible.
  defp decide_hook("pre-tool-use", _scope, _payload, nil), do: {:error, "port_required"}

  defp decide_hook("pre-tool-use", scope, payload, port),
    do: {200, PreToolUse.decide(scope, payload, port)}

  defp decide_hook("stop", scope, payload, _port), do: {200, Stop.decide(scope, payload)}

  defp decide_hook("session-start", scope, payload, _port),
    do: SessionStart.handle(scope, payload)

  defp decide_hook("post-tool-use", scope, payload, _port),
    do: PostToolUse.handle(scope, payload)

  defp decide_hook("subagent-start", scope, payload, _port),
    do: SubagentStart.handle(scope, payload)

  defp decide_hook("subagent-stop", scope, payload, _port),
    do: SubagentStop.handle(scope, payload)

  defp decide_hook("notification", scope, payload, _port),
    do: NotificationHook.handle(scope, payload)

  defp decide_hook("ask-user-question", scope, payload, _port),
    do: AskUserQuestion.handle(scope, payload)

  defp decide_hook(hook, _scope, _payload, _port), do: {:error, "unknown_hook: #{hook}"}

  # The whole manifest is validated before any of it is written. A partial
  # apply would leave the project half-described, which is worse than not
  # applying it: the graph would be computed from a mixture of two harnesses'
  # views and match neither.
  defp deserialize_observations(observations) do
    entries = Enum.map(observations, &deserialize_observation/1)

    case Enum.flat_map(entries, &problems/1) |> Enum.uniq() |> Enum.take(20) do
      [] -> {:ok, Enum.map(entries, &Map.delete(&1, :raw_role))}
      problems -> {:error, problems}
    end
  end

  defp problems(%{role: nil, raw_role: raw}), do: ["unknown role: #{inspect(raw)}"]
  defp problems(%{mtime: nil, path: path}), do: ["unparseable mtime on #{path}"]

  # Parseable is not the same as storable, and the gap between them killed the
  # channel rather than answering.
  #
  # `2026-08-12T00:00:00Z` is a perfectly good DateTime and passed every check
  # here, then failed four frames later in `Files.upsert_files/2` against a
  # `:utc_datetime_usec` column — as an ArgumentError from `Ecto.Type.check_usec!`
  # inside the channel process. So the harness saw a dropped connection, not a
  # rejected manifest: it would reconnect, re-send the same manifest, and die
  # again, with nothing on its side naming the cause. A reconnect loop that
  # reads as a network problem.
  #
  # Refused rather than truncated on the way in. A harness sending a timestamp
  # this server cannot store should be told so — silently adjusting it would
  # make `Files.stale_paths/2` compare a value the working copy never reported.
  # Whether a real filesystem reports whole seconds was never established;
  # `File.stat` granularity varies, and a container bind mount is exactly where
  # it would differ.
  defp problems(%{mtime: %DateTime{microsecond: {_value, precision}}, path: path})
       when precision != 6 do
    [
      "mtime on #{path} has #{precision}-digit sub-second precision; " <>
        "microsecond precision (6 digits, e.g. 2026-08-12T00:00:00.000000Z) is required"
    ]
  end

  defp problems(_entry), do: []

  # Keys are mapped one at a time and roles are matched against the schema's
  # own enum. Nothing here calls String.to_atom on wire data — a harness is
  # authenticated, but "authenticated" is not "allowed to mint atoms in this
  # VM until it runs out of them".
  defp deserialize_observation(observation) do
    %{
      path: observation["path"],
      role: role_atom(observation["role"]),
      raw_role: observation["role"],
      mtime: parse_mtime(observation["mtime"]),
      size: observation["size"],
      fingerprint: observation["fingerprint"],
      valid: observation["valid"],
      validation_errors: observation["validation_errors"],
      component_id: observation["component_id"],
      story_id: observation["story_id"]
    }
  end

  defp role_atom(role) when is_binary(role) do
    Enum.find(Ecto.Enum.values(FileRecord, :role), &(to_string(&1) == role))
  end

  defp role_atom(_), do: nil

  # mtime decides which files are stale, so a nil would crash the comparison in
  # `Files.stale_paths/2` rather than merely lose a timestamp. It is validated,
  # not defaulted.
  defp parse_mtime(%DateTime{} = mtime), do: mtime

  defp parse_mtime(mtime) when is_binary(mtime) do
    case DateTime.from_iso8601(mtime) do
      {:ok, parsed, _offset} -> parsed
      {:error, _} -> nil
    end
  end

  defp parse_mtime(_), do: nil

  # Nothing here may be a struct. `story_ids` is a MapSet, which has no JSON
  # representation, and `component_by_id` held whole `%Components.Component{}`
  # rows — which have no `@derive Jason.Encoder`, so the channel serializer
  # raised on the reply and the harness never received a read model at all.
  #
  # Only `module_name` is ever read from a component, by the test-alignment
  # check, so that is all that crosses. Sending the row was both a crash and
  # several kilobytes per component of timestamps and descriptions nobody reads.
  defp serialize_read_model(%Scanner.ReadModel{} = read_model) do
    %{
      "component_by_module" => read_model.component_by_module,
      "component_by_id" => Map.new(read_model.component_by_id, &serialize_component/1),
      "story_ids" => MapSet.to_list(read_model.story_ids),
      "strict" => read_model.strict?
    }
  end

  defp serialize_component({id, component}) do
    {id, %{"module_name" => Map.get(component, :module_name)}}
  end

  # A harness may only hold a project its credential actually reaches.
  #
  # This used to compare the topic against `scope.active_project_id`, which is
  # the user's *UI preference* — whichever project they last clicked in the web
  # app. That made a laptop able to serve exactly one project at a time, which
  # is the opposite of the one-harness-many-projects design, and it broke
  # sprites outright: the deploy-key connect assigns `:deploy_key_project_id`,
  # but resolving through the preference meant a sprite was judged against the
  # *account owner's* last UI click and refused unless it happened to match.
  #
  # A UI preference is not an authorization fact. What is: a deploy key names
  # exactly one project, and a user reaches the projects in accounts they belong
  # to.
  defp authorize(socket, project_id) do
    case socket.assigns[:deploy_key_project_id] do
      nil -> authorize_member(socket.assigns[:scope], project_id)
      key_project_id -> authorize_deploy_key(socket.assigns[:scope], key_project_id, project_id)
    end
  end

  # A deploy key is issued per project and reaches that project only, whatever
  # its account owner happens to have selected in the browser.
  defp authorize_deploy_key(%Scope{} = scope, key_project_id, project_id) do
    if to_string(key_project_id) == project_id do
      pin_to_project(scope, project_id)
    else
      {:error, :unauthorized}
    end
  end

  defp authorize_deploy_key(_scope, _key_project_id, _project_id), do: {:error, :unauthorized}

  defp authorize_member(%Scope{user: %{}} = scope, project_id) do
    pin_to_project(scope, project_id)
  end

  defp authorize_member(_scope, _project_id), do: {:error, :unauthorized}

  # Resolves the project the topic names and rebuilds the scope around it, so
  # everything downstream — files, leases, hook decisions — acts on the project
  # the harness asked for rather than on whatever the session was pointed at.
  defp pin_to_project(%Scope{} = scope, project_id) do
    with %Project{} = project <- Projects.get_project_by_id(project_id),
         true <- Accounts.user_has_account_access?(scope, project.account_id) do
      {:ok,
       %Scope{
         scope
         | active_project: project,
           active_project_id: project.id,
           active_account_id: project.account_id
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # Said by the harness at join, because the server has no way to find it out.
  # A refusal has to name the checkout to go and stop, and the previous version
  # read `socket.assigns[:harness_label]`, which nothing ever assigned — so every
  # refusal said "a harness on an unknown host" while claiming to identify one.
  # The channel test passed only because it injected the assign by hand.
  # The working copy this channel speaks for, as something the server can read
  # and write rather than a fact it merely knows.
  #
  # `scope.environment` was nil on every path that starts here, so anything
  # reaching for a file got `{:error, :no_environment}` — "there is no working
  # copy", which is false. There is one; it is on the other end of this socket.
  # Measured on one reconcile: 25 spec files unreadable, 75 read failures, and
  # `ComponentSync` skipping its cleanup because a sync that cannot read cannot
  # safely prune (684f072e). `a78036b2` built the environment that fixes it and
  # deliberately wired nothing; this is that wiring.
  #
  # Addressed by harness id, not by `root`: the path is a string on the
  # device's filesystem, which the server may not share, and two checkouts of
  # one project are two working copies. `cwd` is carried for the callers that
  # relativize paths against it, never to open anything with.
  #
  # Only the reads that have no manifest answer go over the wire — the scanner
  # parses on the device and ships the verdict, so this is the 25 that fell
  # through, not the 1,519 that did not.
  # Shared with `ProjectScopeOverride`, which set only `active_harness_id` and
  # left MCP tools able to name a working copy they could not read.
  defp put_harness_scope(scope, harness), do: Harnesses.put_scope(scope, harness)

  # One harness serves a working copy at a time — and the refusal says which one.
  #
  # Only a *different* OS process gets here. The same harness coming back takes
  # its own registration, because otherwise it waits behind its own orphaned
  # channel forever — see `Analysis.register_executor/2`.
  #
  # The naming is the point, and it is criterion 744's second half. The refusal
  # used to read `held_by: "another harness on this working copy"`, which is
  # true, useless, and indistinguishable from not knowing: an operator looking at
  # two processes still cannot tell which to stop. The holder's instance and the
  # checkout's root are both things this server has, so it says them.
  defp take_working_copy(harness, payload) do
    case Analysis.register_executor(harness.id, payload["instance"]) do
      :ok ->
        :ok

      {:error, {:already_registered, pid}} ->
        Logger.warning(
          "[HarnessProject] refused a second harness on working copy #{harness.root || harness.id} " <>
            "of project #{harness.project_id} (joining instance #{inspect(payload["instance"])}, " <>
            "held by #{inspect(pid)})"
        )

        {:error, working_copy_in_use(harness, pid)}
    end
  end

  defp working_copy_in_use(harness, pid) do
    holder =
      case Analysis.executor_holder(harness.id) do
        {:ok, _pid, instance} when is_binary(instance) -> instance
        _ -> inspect(pid)
      end

    %{
      reason: "working_copy_in_use",
      harness_id: harness.id,
      root: harness.root,
      held_by: holder,
      detail:
        "The working copy at #{harness.root || harness.id} is already being served by " <>
          "#{holder}. Two harnesses on one checkout share a single `_build`, and two " <>
          "`mix test` runs in it report failures that are not in the code. Stop that " <>
          "process, or serve a different checkout."
    }
  end

  defp harness_label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp harness_label(_payload), do: "a harness that did not say where it is"

  # A join that does not name a root is not an error — a harness built before
  # the field existed does not send one, and its identity is unaffected either
  # way, because the root is recorded about the harness rather than used to
  # find it.
  defp report_root(harness, root) when is_binary(root) and root != "",
    do: Harnesses.report_root(harness, root)

  defp report_root(harness, _), do: {:ok, harness}

  # Linked, deliberately. This process dying is what releases the lock, so the
  # holder must not outlive the channel — and a holder that cannot start must
  # fail the join rather than silently leave the project unguarded.

  # Which conversation a recorded turn belongs to.
  #
  # The harness says so when it can — a sprite sets `x-cms-session-id` and means
  # it. Claude Code sends nothing on `/v1/messages`, because the Anthropic API
  # has no session and nothing sits between the two to add one, so the turn
  # arrives knowing only its working copy. The session running in that copy is
  # the answer, and `session_start` recorded it there.
  #
  # "sprite" stays as the last resort rather than the default it used to be.
  # Reached now only when a harness names no working copy and sends no id, it is
  # a real fallback instead of the label every Claude Code session got.
  defp session_external_id(scope, payload) do
    case payload["session_id"] do
      id when is_binary(id) and id != "" -> id
      _ -> Sessions.external_id_for_harness(scope.active_harness_id) || "sprite"
    end
  end
end
