defmodule CmsHarness.Project.AnalysisServer do
  @moduledoc """
  One project's analyzer queue: runs the tools the server asked for, one at a
  time, and pushes each result back as it lands.

  **Serialized, not parallel.** `mix test` and `mix spex` share `_build/test`,
  and two mix runs at once can corrupt the build into reporting failures that
  are not in the code. The server's `Analysis.ProjectServer` serializes for
  the same reason.

  **Every request is answered, with a real result.** A run the server started
  is a `:running` row in its ledger; one nobody finishes makes the stop hook
  report analysis pending forever. So a crash, a timeout, a cancel and a tool
  that will not start all push a result saying so, and a duplicate request for
  a source already queued ties onto that entry and receives its real result.

  Runs execute in a task under the project's `Task.Supervisor`, so a wedged
  `mix` cannot take the queue with it when it is killed.
  """

  use GenServer

  require Logger

  alias CmsHarness.Agents.Engine.Execution
  alias CmsHarness.Analysis
  alias CmsHarness.AnalysisSlots
  alias CmsHarness.Channel
  alias CmsHarness.DiskCapacity
  alias CmsHarness.Sync
  alias CodeMySpec.DurableRun
  alias CodeMySpec.ExecutionContexts.ExecutionContext

  # A ceiling, not an expectation: it bounds the run that will never finish,
  # which would otherwise hold every later analyzer behind it.
  @default_timeout :timer.minutes(30)

  # Cleanup retains the process groups established by OTP at spawn.
  # Reserve five seconds inside this initial deadline for overdue recovery.
  # Failed confirmation retains the queue and slot barriers while cleanup retries.
  @cleanup_confirm_deadline :timer.seconds(20)

  # 55379e16 follow-up, per main's direction: `Analysis.tree_state/1` (two
  # git calls -- `rev-parse HEAD`, `status --porcelain`) runs once before
  # the analyzer and once after. The kill timer now arms only once the
  # pre-run call returns (see `:analysis_started`), so a slow git call can
  # no longer eat into the analyzer's own `harness_analysis_timeout` budget
  # -- but an unbounded git call could still hang a run indefinitely on its
  # own, defeating the point of a kill timer entirely. Bounded separately
  # so a failure here is reported as what it is, not misread as the
  # analyzer itself having timed out.
  @git_snapshot_timeout :timer.seconds(10)

  # --- Client ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    GenServer.start_link(__MODULE__, project, name: via(project.root))
  end

  # Keyed on the working copy, not the project: two checkouts of one project
  # resolve the same id.
  def via(root), do: {:via, Registry, {CmsHarness.Registry, {:analysis, root}}}

  @doc """
  Queue the runs the server asked for.

  Each entry is `%{"run_id" => id, "source" => source, "args" => args}`. Returns
  `:ok` whether or not the project is being served — a push for a project this
  harness does not hold is the server's business to notice, not something to
  crash a channel over.
  """
  @spec enqueue(String.t(), [map()]) :: :ok
  def enqueue(root, runs) when is_list(runs) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:enqueue, runs})

      [] ->
        Logger.error(
          "[CmsHarness] the server asked project #{root} to run " <>
            "#{length(runs)} analyzer(s), but this harness has no analysis queue for it. " <>
            "Those runs will sit unfinished on the server."
        )

        :ok
    end
  end

  @doc """
  Stop everything this project's queue holds: the run under way is killed, and
  it and every run queued behind it are answered as superseded, with `reason`.

  The promotion gate asks for this when a batch leaves its copy, so the next
  batch does not rebuild the tree under runs still holding machine-wide slots.
  Returns how many entries were held.
  """
  @spec cancel(String.t(), String.t()) :: non_neg_integer()
  def cancel(root, reason) when is_binary(reason) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, {:cancel, reason}, 5_000)
      [] -> 0
    end
  end

  @doc """
  Cancel one run, executing or queued, answered as `cancelled` (story 1142).
  Its task is killed, and the run, which watches it, halts.
  """
  @spec cancel_run(String.t(), integer()) :: :ok | :not_found
  def cancel_run(root, run_id) when is_integer(run_id) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, {:cancel_run, run_id}, 5_000)
      [] -> :not_found
    end
  end

  @doc """
  Test seam: block until the queue is empty. Not used in production — the
  server learns a run finished by being told, not by anyone waiting.
  """
  @spec idle?(String.t()) :: boolean()
  def idle?(root) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, :idle?, 5_000)
      [] -> true
    end
  end

  @doc """
  Run ids this harness is still working on — the one executing plus everything
  queued behind it.

  Declared to the server on join, so its reconnect sweep does not close runs
  that survived a dropped socket and will still report.

  Empty list when there is no server for this root ("declaring nothing").
  """
  @spec in_flight(String.t()) :: [integer()]
  def in_flight(root) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, :in_flight, 5_000)
      [] -> []
    end
  end

  @doc """
  A snapshot of what this project's queue actually believes right now: the
  one entry executing (or waiting for a machine-wide slot) and everything
  tied to it, plus every other source still queued behind it.

  For the dev dashboard. The server's `analysis_runs` ledger shows each tied
  run as its own `:running` row; only this queue knows they are one execution.

  `nil` when there is no queue for this root.
  """
  @spec status(String.t()) :: %{running: map() | nil, queued: [map()]} | nil
  def status(root) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, :status, 5_000)
      [] -> nil
    end
  end

  def acknowledge(root, run_id) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:acknowledge, run_id})
      [] -> :ok
    end
  end

  # --- Server ---

  @impl true
  def init(project) do
    Process.set_label({__MODULE__, project.root})
    recovering = DurableRun.for_root(project.root) |> Map.new(&{&1["run_id"], &1})
    if map_size(recovering) > 0, do: Process.send_after(self(), :poll_recovery, 100)

    {:ok,
     %{
       project: project,
       running: nil,
       queue: [],
       timer: nil,
       pending_cleanups: [],
       recovering: recovering
     }}
  end

  @impl true
  def handle_cast({:acknowledge, run_id}, state) do
    owner =
      Enum.find(state.recovering, fn {_id, manifest} ->
        run_id in [manifest["run_id"] | manifest["tied_run_ids"] || []]
      end)

    state =
      case owner do
        {id, manifest} ->
          case DurableRun.acknowledge(manifest, run_id) do
            :complete -> %{state | recovering: Map.delete(state.recovering, id)}
            {:pending, updated} -> %{state | recovering: Map.put(state.recovering, id, updated)}
          end

        nil ->
          state
      end

    {:noreply, maybe_start_next(state)}
  end

  def handle_cast({:enqueue, runs}, state) do
    Logger.info(
      "[CmsHarness] enqueue for #{state.project.root}: " <>
        "#{inspect(Enum.map(runs, &Map.get(&1, "run_id")))}"
    )

    state =
      runs
      |> Enum.reduce(state, &accept/2)
      |> settle()
      |> maybe_start_next()

    {:noreply, state}
  end

  @impl true
  def handle_call(:idle?, _from, state) do
    {:reply,
     is_nil(state.running) and state.queue == [] and state.pending_cleanups == [] and
       map_size(state.recovering) == 0, state}
  end

  # Queued and tied runs count as in flight. Their rows are already `:running`
  # on the server, so a sweep would close them just the same, and this server
  # will answer them.
  def handle_call(:in_flight, _from, state) do
    {:reply, Enum.uniq(held_run_ids(state) ++ recovered_run_ids(state)), state}
  end

  def handle_call({:cancel, reason}, _from, state) do
    held = Enum.reject([state.running | state.queue], &is_nil/1)

    recovered =
      Enum.reject(Map.get(state, :recovering, %{}), fn {id, _manifest} ->
        state.running && state.running.run_id == id
      end)

    if running = state.running do
      cancel_durable_run(running.run_id)
      Task.Supervisor.terminate_child(Sync.task_supervisor(state.project.root), running.task.pid)
      Process.demonitor(running.task.ref, [:flush])

      if capture = Map.get(running, :output_capture) do
        StringIO.close(capture)
      end
    end

    for entry <- held, run_id <- [entry.run_id | Map.get(entry, :tied_run_ids, [])] do
      Channel.deliver_analysis_result(state.project.root, %{
        "run_id" => run_id,
        "source" => entry.source,
        "status" => "superseded",
        "error" => reason
      })
    end

    for {owner_id, manifest} <- recovered do
      cancel_durable_run(owner_id)

      for id <- [owner_id | manifest["tied_run_ids"] || []] do
        Channel.deliver_analysis_result(state.project.root, %{
          "run_id" => id,
          "source" => manifest["source"],
          "status" => "superseded",
          "error" => reason
        })
      end
    end

    count = length(held) + length(recovered)

    if count > 0 do
      Logger.info(
        "[CmsHarness] cancelled #{count} analyzer run(s) for #{state.project.root}: #{reason}"
      )
    end

    {:reply, count, state |> Map.put(:queue, []) |> Map.put(:recovering, %{}) |> clear_running()}
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    queued = Enum.find(state.queue, &(run_id in answers_for(&1)))

    recovered =
      Enum.find(Map.get(state, :recovering, %{}), fn {_id, manifest} ->
        run_id in [manifest["run_id"] | manifest["tied_run_ids"] || []]
      end)

    cond do
      state.running && run_id in answers_for(state.running) ->
        running = state.running
        cancel_durable_run(running.run_id)

        Task.Supervisor.terminate_child(
          Sync.task_supervisor(state.project.root),
          running.task.pid
        )

        Process.demonitor(running.task.ref, [:flush])

        if capture = Map.get(running, :output_capture) do
          StringIO.close(capture)
        end

        answer_cancelled(state.project.root, running)

        {:reply, :ok,
         state
         |> Map.update(:recovering, %{}, &Map.delete(&1, running.run_id))
         |> clear_running()
         |> maybe_start_next()}

      queued ->
        answer_cancelled(state.project.root, queued)
        {:reply, :ok, %{state | queue: List.delete(state.queue, queued)}}

      recovered ->
        {owner_id, manifest} = recovered
        cancel_durable_run(owner_id)

        for id <- [owner_id | manifest["tied_run_ids"] || []] do
          Channel.deliver_analysis_result(state.project.root, %{
            "run_id" => id,
            "source" => manifest["source"],
            "status" => "cancelled"
          })
        end

        {:reply, :ok,
         state |> Map.update!(:recovering, &Map.delete(&1, owner_id)) |> maybe_start_next()}

      true ->
        {:reply, :not_found, state}
    end
  end

  def handle_call(:status, _from, %{running: %{started: false} = waiting} = state) do
    {:reply, %{running: nil, queued: Enum.map([waiting | state.queue], &entry_summary/1)}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{running: entry_summary(state.running), queued: Enum.map(state.queue, &entry_summary/1)},
     state}
  end

  defp cancel_durable_run(run_id) do
    case DurableRun.read_manifest(run_id) do
      {:ok, manifest} ->
        DurableRun.cancel(manifest)
        DurableRun.cleanup(run_id)

      _ ->
        :ok
    end
  end

  @impl true
  def handle_info(
        {ref, {:ran, result, completed}},
        %{running: %{task: %Task{ref: ref}} = running} = state
      ) do
    Process.demonitor(ref, [:flush])
    deliver(state, running, result, completed)
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  # The commit the analyzer is actually starting on, for the server to
  # record against this run and every run tied to it. Guarded on `run_id`
  # like `:slot_acquired`, so a start from a run already moved past is not
  # reported.
  #
  # 55379e16 follow-up, per main's direction: this is also where the kill
  # timer now arms, not `:slot_acquired`. `Analysis.tree_state/1` (two git
  # calls, run before this message is sent -- see `run_with_slot/3`) sat
  # between the old arming point and the analyzer actually running; under
  # load those two git calls could by themselves eat most or all of a short
  # `harness_analysis_timeout`, so a kill fired before the analyzer had a
  # real chance to start. Arming here means the analyzer always gets its
  # full window, counted from when it actually begins.
  def handle_info(
        {:analysis_started, run_id, tree},
        %{running: %{run_id: run_id, source: source} = running} = state
      ) do
    for id <- [run_id | Map.get(running, :tied_run_ids, [])] do
      Channel.deliver_analysis_started(state.project.root, %{
        "run_id" => id,
        "source" => source,
        "start_commit" => tree.commit,
        "start_tree_dirty" => tree.dirty,
        "start_tree" => Map.get(tree, :tree)
      })
    end

    timer = Process.send_after(self(), {:timeout, run_id}, timeout())
    {:noreply, %{state | timer: timer, running: Map.put(running, :started, true)}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: %{task: %Task{ref: ref}} = running} = state
      ) do
    # The task died without returning. Answered rather than dropped.
    deliver(state, running, {:error, "analyzer task died: #{inspect(reason)}"})
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  def handle_info({:timeout, run_id}, %{running: %{run_id: run_id} = running} = state) do
    Logger.error(
      "[CmsHarness] #{running.source} for #{state.project.root} exceeded #{timeout()}ms — killing it"
    )

    # Capture group ownership before terminating BEAM owners. Reparented OS
    # descendants remain addressable through the retained group identities.
    # Queue advancement and slot release wait for termination confirmation.
    Process.demonitor(running.task.ref, [:flush])
    task_pid = running.task.pid
    cleanup_deadline = System.monotonic_time(:millisecond) + @cleanup_confirm_deadline
    ownership = Execution.capture(task_pid)

    cleanup =
      Task.Supervisor.async_nolink(Sync.task_supervisor(state.project.root), fn ->
        Execution.stop_owned(ownership)
      end)

    # Reserve the final five seconds of the existing outer deadline for
    # recovery if the first cleanup worker fails to report.
    overdue_timer =
      Process.send_after(
        self(),
        {:cleanup_overdue, run_id, task_pid},
        @cleanup_confirm_deadline - 5_000
      )

    pending =
      Map.merge(running, %{
        cleanup: cleanup,
        cleanup_timer: overdue_timer,
        cleanup_ownership: ownership,
        cleanup_deadline: cleanup_deadline
      })

    Logger.info(
      "[CmsHarness] #{running.source} run #{run_id} for #{state.project.root} handed off to " <>
        "cleanup; the queue and machine-wide slot remain held until confirmation"
    )

    state = %{state | pending_cleanups: [pending | state.pending_cleanups], timer: nil}
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  # The confirmed-dead report from the cleanup task above, found in
  # `pending_cleanups` rather than `running`. Pending cleanup blocks the queue
  # until this report confirms that the owned process groups are gone.
  def handle_info({ref, cleanup_result}, state) when is_reference(ref) do
    case pop_pending_cleanup(state, &(&1.cleanup.ref == ref)) do
      {:ok, pending, state} ->
        Process.demonitor(ref, [:flush])
        cancel_cleanup_deadline(pending)

        finish_cleanup(
          state,
          pending,
          cleanup_result,
          "analyzer timed out after #{timeout()}ms. #{cleanup_status(cleanup_result)}"
        )

      :error ->
        {:noreply, state}
    end
  end

  # The cleanup task itself crashed rather than returning -- still answered,
  # the same as the analyzer task's own unexpected death above, rather than
  # leaving this run stuck on a message that will never arrive. Found in
  # `pending_cleanups`, same as its normal completion above.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_pending_cleanup(state, &(&1.cleanup.ref == ref)) do
      {:ok, pending, state} ->
        cancel_cleanup_deadline(pending)

        cleanup_result =
          Execution.stop_owned(
            pending.cleanup_ownership,
            min(pending.cleanup_deadline, System.monotonic_time(:millisecond) + 5_000)
          )

        finish_cleanup(
          state,
          pending,
          cleanup_result,
          "analyzer timeout cleanup crashed: #{inspect(reason)}. " <>
            cleanup_status(cleanup_result)
        )

      :error ->
        {:noreply, state}
    end
  end

  # Recover using retained groups if the first worker has not reported.
  # Each recovery attempt has a bounded deadline; failure retains the barrier.
  def handle_info({:cleanup_overdue, run_id, _task_pid}, state) do
    case pop_pending_cleanup(state, &(&1.run_id == run_id)) do
      {:ok, pending, state} ->
        Logger.error(
          "[CmsHarness] #{pending.source} for #{state.project.root} timeout cleanup did not " <>
            "report before the recovery window -- retrying owned-group cleanup " <>
            "while retaining the queue and machine-wide slot barriers"
        )

        if cleanup = pending[:cleanup] do
          Task.Supervisor.terminate_child(Sync.task_supervisor(state.project.root), cleanup.pid)
          Process.demonitor(cleanup.ref, [:flush])
        end

        ownership = pending.cleanup_ownership
        cleanup_result = Execution.stop_owned(ownership, pending.cleanup_deadline)

        finish_cleanup(
          state,
          pending,
          cleanup_result,
          "analyzer timed out after #{timeout()}ms. Cleanup worker overdue; " <>
            "attempted owned-group recovery under the cleanup deadline. " <>
            cleanup_status(cleanup_result)
        )

      :error ->
        {:noreply, state}
    end
  end

  # Logs how a long wait for a machine-wide slot ended; short waits are not
  # worth a line. Guarded on `run_id` so a message from a run already moved
  # past does not log against the wrong entry. The kill timer no longer arms
  # here -- see `:analysis_started` below.
  def handle_info(
        {:slot_acquired, run_id, waited_ms},
        %{running: %{run_id: run_id, source: source}} = state
      ) do
    if waited_ms > 500 do
      Logger.info(
        "[CmsHarness] #{source} run #{run_id} for #{state.project.root} got a machine-wide " <>
          "slot after waiting #{waited_ms}ms"
      )
    end

    {:noreply, state}
  end

  def handle_info({:slot_acquired, _run_id, _waited_ms}, state), do: {:noreply, state}

  def handle_info({:track_durable, id}, state) do
    case DurableRun.read_manifest(id) do
      {:ok, manifest} ->
        if map_size(state.recovering) == 0, do: Process.send_after(self(), :poll_recovery, 250)
        {:noreply, %{state | recovering: Map.put(state.recovering, id, manifest)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:track_completed, manifest}, state) do
    if map_size(state.recovering) == 0, do: Process.send_after(self(), :poll_recovery, 250)

    {:noreply,
     %{
       state
       | recovering:
           Map.put(state.recovering, manifest["run_id"], Map.put(manifest, "sent", true))
     }}
  end

  def handle_info(:poll_recovery, state) do
    recovering =
      Map.new(state.recovering, fn {id, manifest} ->
        current =
          if manifest["status"] == "completed" do
            manifest
          else
            case DurableRun.read_manifest(id) do
              {:ok, latest} -> latest
              _ -> manifest
            end
          end

        manifest =
          if state.running && state.running.run_id == id do
            poll_live_run(state.project.root, current)
          else
            poll_recovered_run(state.project.root, current)
          end

        {id, manifest}
      end)

    if map_size(recovering) > 0, do: Process.send_after(self(), :poll_recovery, 250)
    {:noreply, maybe_start_next(%{state | recovering: recovering})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll_recovered_run(root, %{"status" => "completed"} = manifest) do
    unless manifest["sent"] do
      Enum.each(
        DurableRun.unacknowledged_payloads(manifest),
        &Channel.deliver_analysis_result(root, &1)
      )
    end

    Map.put(manifest, "sent", true)
  end

  defp poll_recovered_run(root, %{"status" => "starting"} = manifest) do
    if DurableRun.startup_stale?(manifest) do
      poll_recovered_run(root, Map.put(manifest, "status", "exited"))
    else
      manifest
    end
  end

  defp poll_recovered_run(root, manifest) do
    manifest = poll_live_run(root, manifest)

    if DurableRun.alive?(manifest) do
      manifest
    else
      result =
        case DurableRun.completed_result(manifest) do
          {:ok, raw} -> {:ok, raw}
          {:error, reason} -> {:error, "analyzer process ended during harness restart: #{reason}"}
        end

      payloads = recovered_payloads(manifest, result)
      manifest = DurableRun.complete(manifest, payloads)
      Enum.each(payloads, &Channel.deliver_analysis_result(root, &1))
      manifest
    end
  end

  defp poll_live_run(root, manifest) do
    {events, offsets} = DurableRun.stream_events(manifest)

    for event <- events, live = DurableRun.live_event(event), live != nil do
      Channel.deliver_analysis_event(root, %{"run_id" => manifest["run_id"], "event" => live})
    end

    DurableRun.advance(manifest, offsets)
  end

  defp recovered_payloads(manifest, result) do
    owner = manifest["run_id"]
    ids = [owner | manifest["tied_run_ids"] || []]
    base = %{"args" => manifest["args"], "completed_commit" => manifest["start_commit"]}

    Enum.map(ids, fn id ->
      common = Map.merge(base, %{"run_id" => id, "source" => manifest["source"]})

      case result do
        {:ok, raw} ->
          Map.merge(common, %{
            "status" => "ok",
            "result" => raw,
            "analyzer_staleness" => CodeMySpec.BootVersion.analyzer_staleness(),
            "tied_to" => if(id == owner, do: nil, else: owner)
          })

        {:error, reason} ->
          Map.merge(common, %{"status" => "error", "error" => reason})
      end
    end)
  end

  # --- Internals ---

  # Strips the live `Task`. Carries the `tied_run_ids` themselves so a
  # dashboard can correlate them with the server's `analysis_runs` rows.
  defp entry_summary(nil), do: nil

  defp entry_summary(entry) do
    %{
      source: entry.source,
      run_id: entry.run_id,
      args: Map.get(entry, :args, []),
      tied_run_ids: Map.get(entry, :tied_run_ids, [])
    }
  end

  # Queue rules:
  # - a run id already held is ignored (the server re-sends runs it has joined);
  # - a source already *queued* ties onto that entry: one execution answers
  #   every tied run id with the same real result;
  # - otherwise a new entry, including for a source that is only *running*,
  #   since that run may be answering input now stale.
  # See knowledge/harness/channel, "Analysis queue".
  defp accept(request, state) do
    case parse(request) do
      {:ok, run_id, source, args} ->
        cond do
          # The server re-sends a run it has joined; a second entry would push
          # its result twice.
          holds_run?(state, run_id) ->
            state

          queued_entry_for(state, source) ->
            tie_to_queued(state, source, run_id, args)

          true ->
            entry = %{
              run_id: run_id,
              tied_run_ids: [],
              source: source,
              args: args,
              settled: false,
              priority: priority(request)
            }

            %{state | queue: insert_by_cost(state.queue, entry)}
        end

      {:error, request} ->
        Logger.error("[CmsHarness] unreadable run_analysis entry: #{inspect(request)}")
        state
    end
  end

  # One queued entry per source: at most current run + next run. The next
  # run's args grow to the union of everyone tied to it, so no tied request's
  # files go unanalyzed.
  defp tie_to_queued(state, source, run_id, args) do
    Logger.info(
      "[CmsHarness] #{source} is already queued for #{state.project.root} — " <>
        "run #{run_id} is tied to it and will get its result"
    )

    queue =
      Enum.map(state.queue, fn
        %{source: ^source} = entry ->
          %{
            entry
            | tied_run_ids: [run_id | entry.tied_run_ids],
              args: merge_args(entry.args, args)
          }

        entry ->
          entry
      end)

    %{state | queue: queue}
  end

  # Empty args mean "the whole suite", a superset of any file list, so it wins
  # the merge. Two non-empty lists merge to their union.
  defp merge_args([], _other), do: []
  defp merge_args(_args, []), do: []
  defp merge_args(args, other), do: Enum.uniq(args ++ other)

  defp parse(%{"run_id" => run_id, "source" => source} = request)
       when is_integer(run_id) and is_binary(source) do
    {:ok, run_id, source, List.wrap(Map.get(request, "args", []))}
  end

  defp parse(request), do: {:error, request}

  # The server marks a promotion gate's runs; a server that predates the field
  # sends none, and the run waits like any other.
  defp priority(%{"priority" => "gate"}), do: :gate
  defp priority(_request), do: :normal

  # Only the queue, deliberately not `state.running`: a duplicate of a running
  # source becomes a new entry that later duplicates tie onto.
  defp queued_entry_for(state, source), do: Enum.find(state.queue, &(&1.source == source))

  defp holds_run?(state, run_id),
    do: run_id in held_run_ids(state) or run_id in recovered_run_ids(state)

  defp recovered_run_ids(state) do
    Enum.flat_map(Map.get(state, :recovering, %{}), fn {_id, manifest} ->
      [manifest["run_id"] | manifest["tied_run_ids"] || []]
    end)
  end

  # Every run id this queue will answer: each entry's own and everything tied
  # to it, including a timed-out run still in pending_cleanups -- its result
  # has not been delivered yet either.
  defp held_run_ids(state) do
    [state.running | state.queue ++ state.pending_cleanups]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&[&1.run_id | Map.get(&1, :tied_run_ids, [])])
  end

  # Cheapest first, so the fast analyzers an agent can act on are not stuck
  # behind spex. Ordering rather than a second slot: two concurrent `mix`
  # runs contend for `_build`.
  # See knowledge/harness/channel, "Analysis queue".
  @cost %{"compiler" => 0, "credo" => 1, "exunit" => 2, "spex" => 3}

  @doc """
  Public only so the ordering can be tested without standing up a server.
  """
  def insert_by_cost(queue, entry) do
    # Cheapest first *among what arrived together*, never ahead of something
    # already waiting; otherwise a stream of cheap requests starves spex.
    # `waiting` is every entry that has survived a batch (`settled`); absent
    # reads as unsettled, so hand-built entries in tests sort by cost.
    {waiting, arriving} = Enum.split_while(queue, &Map.get(&1, :settled, false))

    sorted =
      (arriving ++ [entry])
      |> Enum.sort_by(&Map.get(@cost, &1.source, 9))

    waiting ++ sorted
  end

  # Everything currently queued has now waited through an arrival, so the next
  # one sorts behind it rather than in front. Called when a batch is done.
  defp settle(%{queue: queue} = state),
    do: %{state | queue: Enum.map(queue, &Map.put(&1, :settled, true))}

  # No timer armed here: `:slot_acquired` arms it once the run has a slot.
  defp maybe_start_next(%{pending_cleanups: [_ | _]} = state), do: state

  defp maybe_start_next(%{running: nil, queue: [entry | rest]} = state) do
    if Enum.any?(Map.get(state, :recovering, %{}), fn {_id, manifest} ->
         manifest["status"] != "completed"
       end) do
      state
    else
      case DiskCapacity.check([state.project.root, System.tmp_dir!()]) do
        :ok ->
          start_next(state, entry, rest)

        {:error, reason} ->
          for run_id <- answers_for(entry) do
            Channel.deliver_analysis_result(state.project.root, %{
              "run_id" => run_id,
              "source" => entry.source,
              "status" => "refused",
              "error" => reason
            })
          end

          maybe_start_next(%{state | queue: rest})
      end
    end
  end

  defp maybe_start_next(state), do: state

  defp start_next(state, entry, rest) do
    project = state.project
    parent = self()
    {:ok, capture} = StringIO.open("")
    entry = Map.put(entry, :output_capture, capture)

    Logger.info("[CmsHarness] #{entry.source} run #{entry.run_id} starting for #{project.root}")

    task =
      Task.Supervisor.async_nolink(Sync.task_supervisor(project.root), fn ->
        run_with_slot(project, entry, parent)
      end)

    %{state | running: Map.merge(entry, %{task: task, started: false}), queue: rest, timer: nil}
  end

  # Bounds `Analysis.tree_state/1`'s two git calls to @git_snapshot_timeout,
  # independent of the analyzer's own timer -- a hung git call must not be
  # able to hold a slot indefinitely just because it runs before the part
  # the kill timer watches.
  defp bounded_tree_state(env), do: snapshot_tree_state(env, fn -> Analysis.tree_state(env) end)

  @doc false
  def snapshot_tree_state(env, snapshot) when is_function(snapshot, 0) do
    # Git can fail to spawn on the host. A linked snapshot task would kill the
    # analyzer owner before it could report that the suite never ran.
    task = Task.Supervisor.async_nolink(Sync.task_supervisor(env.cwd), snapshot)

    case Task.yield(task, @git_snapshot_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, tree} -> {:ok, tree}
      nil -> {:error, "exceeded #{@git_snapshot_timeout}ms"}
      {:exit, reason} -> {:error, "crashed: #{inspect(reason)}"}
    end
  end

  # Inside the task, so the slot is held by the process doing the work and is
  # released when it exits. Timeout cleanup retains the suspended owner until
  # all owned OS process groups have been confirmed dead.
  # `AnalysisSlots.acquire/1` waits in line for a slot, however long that takes.
  defp run_with_slot(project, entry, parent) do
    requested_at = System.monotonic_time(:millisecond)

    lane = AnalysisSlots.lane(entry.source, entry.args)

    case AnalysisSlots.acquire(lane, Map.get(entry, :priority, :normal)) do
      :ok ->
        waited_ms = System.monotonic_time(:millisecond) - requested_at
        send(parent, {:slot_acquired, entry.run_id, waited_ms})

        # The checkout's git state either side of the run, so the server can
        # record which commit the answer is for. Bounded (@git_snapshot_timeout):
        # the pre-run call must return before the analyzer is given its own
        # timer and run at all -- a run that cannot even be attributed to a
        # commit should fail as that, not silently borrow from the
        # analyzer's own budget.
        env = ExecutionContext.new(:local, project.root)

        case bounded_tree_state(env) do
          {:ok, start_tree} ->
            send(parent, {:analysis_started, entry.run_id, start_tree})

            # The current formatter does not emit a recoverable event stream.
            # Keep the existing live reporting and process cleanup until the
            # stream is explicitly enabled for this harness.
            durable? =
              entry.source in ["exunit", "spex"] and
                System.get_env("CMS_RUN_EVENT_STREAM") not in [nil, ""]

            if durable? do
              DurableRun.begin_run(
                entry.run_id,
                project.root,
                entry.source,
                entry.args,
                start_tree.commit,
                entry.tied_run_ids
              )

              send(parent, {:track_durable, entry.run_id})
            end

            result =
              Analysis.run(project, entry.source, entry.args, entry.run_id,
                output_capture: Map.get(entry, :output_capture),
                durable_run: if(durable?, do: entry.run_id)
              )

            completed_tree =
              case bounded_tree_state(env) do
                {:ok, tree} -> tree
                {:error, _reason} -> nil
              end

            {:ran, result, completed_tree}

          {:error, reason} ->
            {:ran,
             {:error,
              "git snapshot before the analyzer ran: #{reason}. No analysis was run; start a fresh #{entry.source} run once git can spawn"},
             nil}
        end
    end
  end

  defp answers_for(entry), do: [entry.run_id | Map.get(entry, :tied_run_ids, [])]

  defp answer_cancelled(root, entry) do
    for run_id <- answers_for(entry) do
      Channel.deliver_analysis_result(root, %{
        "run_id" => run_id,
        "source" => entry.source,
        "status" => "cancelled"
      })
    end

    Logger.info("[CmsHarness] #{entry.source} run #{entry.run_id} cancelled for #{root}")
  end

  defp clear_running(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | running: nil, timer: nil}
  end

  # Finds and removes the one entry matching `pred` from `pending_cleanups`,
  # returning the updated state alongside it so a caller can both deliver
  # its result and drop it from the list in one pass.
  defp pop_pending_cleanup(state, pred) do
    case Enum.find(state.pending_cleanups, pred) do
      nil ->
        :error

      found ->
        {:ok, found, %{state | pending_cleanups: List.delete(state.pending_cleanups, found)}}
    end
  end

  defp cancel_cleanup_deadline(%{cleanup_timer: timer}) when is_reference(timer),
    do: Process.cancel_timer(timer)

  defp cancel_cleanup_deadline(_running), do: :ok

  defp finish_cleanup(state, pending, result, message) do
    unless Map.get(pending, :result_delivered, false) do
      deliver(state, pending, {:error, message})
    end

    case result do
      :ok ->
        {:noreply, maybe_start_next(state)}

      {:error, _reason} ->
        # Keep both the queue barrier and suspended slot owner while retrying.
        # The timeout result and captured output are delivered exactly once.
        timer = Process.send_after(self(), {:cleanup_overdue, pending.run_id, nil}, 1_000)

        retained =
          Map.merge(pending, %{
            result_delivered: true,
            output_capture: nil,
            cleanup_timer: timer,
            cleanup_deadline: System.monotonic_time(:millisecond) + 6_000
          })

        {:noreply, %{state | pending_cleanups: [retained | state.pending_cleanups]}}
    end
  end

  defp cleanup_status(:ok), do: "Subprocess termination confirmed."

  defp cleanup_status({:error, reason}),
    do: "Subprocess termination unconfirmed: #{inspect(reason)}."

  # Every tied run_id gets the same real result as the primary. `tied_to` is
  # `nil` for the primary and the primary's run_id for tied ones: only the
  # owner's message reconciles Problems, so one execution is reconciled once.
  #
  # `completed` is the checkout's git state when the analyzer finished; nil
  # when it never returned. `"args"` is what actually ran (a tie merges args),
  # and the server decides what the result replaces from it.
  defp deliver(state, running, result, completed \\ nil) do
    output =
      case Map.get(running, :output_capture) do
        nil ->
          nil

        capture ->
          {:ok, {_, bytes}} = StringIO.close(capture)
          Analysis.cap(bytes)
      end

    tree = completed |> completed_tree() |> Map.put("args", Map.get(running, :args))
    tree = if match?({:error, _}, result), do: Map.put(tree, "output", output), else: tree

    case DurableRun.read_manifest(running.run_id) do
      {:ok, manifest} ->
        result =
          case result do
            {:ok, _} -> result
            {:error, _} -> result
            other -> {:error, "unreadable analyzer result: #{inspect(other)}"}
          end

        payloads =
          manifest
          |> recovered_payloads(result)
          |> Enum.map(&Map.merge(&1, tree))

        manifest = DurableRun.complete(manifest, payloads)
        send(self(), {:track_completed, manifest})
        Enum.each(payloads, &Channel.deliver_analysis_result(state.project.root, &1))

      _ ->
        push_result(state.project.root, running.run_id, running.source, result, nil, tree)

        for run_id <- Map.get(running, :tied_run_ids, []) do
          push_result(state.project.root, run_id, running.source, result, running.run_id, tree)
        end
    end
  end

  defp completed_tree(%{commit: commit}) when is_binary(commit),
    do: %{"completed_commit" => commit}

  defp completed_tree(_completed), do: %{}

  # Carries `analyzer_staleness`: a harness runs the analyzer it booted with,
  # and a stale analyzer's findings otherwise look like ordinary stale
  # findings. Sent rather than logged, because the agent reads the result, not
  # the harness log.
  defp push_result(root, run_id, source, {:ok, result}, tied_to, tree) do
    Channel.deliver_analysis_result(
      root,
      Map.merge(tree, %{
        "run_id" => run_id,
        "source" => source,
        "status" => "ok",
        "result" => result,
        "analyzer_staleness" => CodeMySpec.BootVersion.analyzer_staleness(),
        "tied_to" => tied_to
      })
    )
  end

  # A failure never reconciles Problems, so `tied_to` is irrelevant; every tied
  # run_id still needs its own row closed.
  defp push_result(root, run_id, source, {:error, reason}, _tied_to, tree) do
    Logger.error("[CmsHarness] #{source} run #{run_id} did not produce a result: #{reason}")

    Channel.deliver_analysis_result(
      root,
      Map.merge(tree, %{
        "run_id" => run_id,
        "source" => source,
        "status" => "error",
        "error" => to_string(reason)
      })
    )
  end

  defp push_result(root, run_id, source, other, tied_to, tree) do
    push_result(
      root,
      run_id,
      source,
      {:error, "unreadable analyzer result: #{inspect(other)}"},
      tied_to,
      tree
    )
  end

  defp timeout,
    do: Application.get_env(:code_my_spec, :harness_analysis_timeout, @default_timeout)
end
