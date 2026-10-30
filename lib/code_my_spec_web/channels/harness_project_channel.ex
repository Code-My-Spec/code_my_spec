defmodule CodeMySpecWeb.HarnessProjectChannel do
  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @moduledoc """
  The **data plane** for one working copy: the channel a light harness holds
  while it serves that checkout.

  Distinct from `HarnessChannel`, which is account-scoped and relays an agent's
  conversation to the operator inbox. This one is scoped to a working copy and
  carries the work — sync results, analysis results, hook decisions.

  ## Two checkouts of one project both serve

  Files and problems are keyed on the working copy, so two checkouts of one
  project are two harnesses and both serve. What is refused is a second
  harness on the *same* working copy: `mix test` and `mix spex` share one
  `_build`, and two at once corrupt it. That is a registry entry held for the
  life of the channel; there is no lease table or advisory lock.

  ## Why a channel rather than REST

  Liveness. The registry entry, the analysis executor slot and the in-flight
  run ledger all key off "is this harness still here", which a closing socket
  says exactly and REST could only approximate with a heartbeat and expiry.

  See knowledge/harness/channel.
  """

  use CodeMySpecWeb, :channel

  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.AgentHarness.ConversationRecorder
  alias CodeMySpec.AgentPerformance.TokenUsage
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.LaunchRequest
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.AgentTasks.SkillRouter
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.FleetHolds
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Drafts
  alias CodeMySpec.Devices
  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.ReconcileRegistry
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Hooks.NotificationHook
  alias CodeMySpec.Hooks.PostToolUse
  alias CodeMySpec.Hooks.PreToolUse
  alias CodeMySpec.Hooks.SessionStart
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.McpServers.Promotion.Responses, as: PromotionResponses
  alias CodeMySpec.McpServers.ToolRegistry
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.Requirements.CopyOverlay
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.AppInstances
  alias CodeMySpec.Workspaces.PreviewTunnel

  @impl true
  def join("harness_project:" <> project_id, payload, socket) do
    label = harness_label(payload)

    with :ok <- check_contract(payload, project_id),
         {:ok, scope} <- authorize(socket, project_id),
         device = resolve_device(scope, payload),
         {:ok, harness} <-
           WorkingCopies.issue(
             scope,
             payload["working_copy_id"] || payload["harness_id"],
             # Device and root let a rejoining checkout that presents no id be
             # recognised rather than minted again.
             label: label,
             device: device,
             root: payload["root"]
           ),
         {:ok, harness} <- report_root(scope, harness, payload["root"]),
         {:ok, harness} <- report_preview_url(harness, payload["preview_url"]),
         :ok <- Devices.box_joined(socket.assigns[:device_id]),
         {:ok, harness} <- WorkingCopies.attach_device(harness, device),
         :ok <-
           record_machine_tools(harness, payload["machine_tools"], payload["machine_tool_docs"]),
         :ok <- record_browser_status(harness, payload["browser_status"]),
         # What this harness says its app is running. A reply or push lost to
         # a restart or reconnect leaves a stale commit, which promotion keys
         # on; the join is where the two converge.
         :ok <- ensure_default_instance(scope, harness),
         :ok <- report_app_state(scope, harness, payload["app"]),
         :ok <- report_app_instances(scope, harness, payload["app_instances"]),
         # Everything below is per working copy, so the scope carries the
         # harness — and the working copy itself — before any of it runs.
         scope = put_harness_scope(scope, harness),
         :ok <- take_working_copy(harness, payload) do
      # Anything still `:running` and not claimed by the joining harness belongs
      # to a previous connection that will never finish it; an open run makes
      # every later stop report analysis pending.
      Analysis.fail_in_flight(scope, :harness_reconnected, claimed_runs(payload))
      Analysis.reconcile_rejoined(scope, claimed_runs(payload))

      # Then settle what the departure killed: reopen what this harness still
      # holds, run the requested rest again. Registered above, so a re-dispatch
      # lands in this channel's mailbox and is pushed once the join returns.
      Analysis.resume_orphaned(scope, claimed_runs(payload))
      PromotionQueue.copy_joined(scope, harness)
      CodeMySpec.Promotion.DeviceSync.copy_joined(scope, harness)

      # The id goes back whether minted or recognised; a first join writes it
      # down so its next restart is the same harness.
      {:ok,
       %{
         working_copy_id: harness.id,
         harness_id: harness.id,
         device_id: device && device.id,
         sops_age_keys: local_age_keys(scope),
         # `harness` is fresh here, so `main` can be read straight off it;
         # `put_tunnel/2` must re-fetch.
         tunnel: tunnel_for(harness)
       },
       socket
       |> assign(:scope, scope)
       |> assign(:harness, harness)
       # One reconcile in flight, at most one waiting. See `accept_manifest/2`.
       |> assign(:reconciling, nil)
       |> assign(:reconciling_manifest, nil)
       |> assign(:reconcile_retries, 0)
       |> assign(:pending_manifest, nil)
       |> assign(:overlay_unchecked, false)
       |> assign(:read_model_due, false)}
    else
      # A changeset is a map too, so it must be matched ahead of the generic
      # refusal clause below — otherwise it passes through as a raw struct
      # instead of a reason a harness can show.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, %{reason: Utils.changeset_error_to_string(changeset)}}

      # A refusal that already built its own payload passes through; the
      # clause below calls `to_string/1`, which raises on a map.
      {:error, %{} = refusal} ->
        {:error, refusal}

      # A join that names no machine. A checkout is identified by
      # {project, device, root}, and a seen copy must name a device
      # (`seen_copies_are_on_a_machine`), so this is refused rather than minted.
      {:error, :no_device} ->
        {:error,
         %{
           reason:
             "This harness did not say which machine it is on, so its checkout " <>
               "cannot be told apart from the same path on another machine. " <>
               "Update the harness — a current one announces itself at boot and " <>
               "sends the id it was issued."
         }}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid topic"}}

  # The app the joining harness says it is running. An absent field means "not
  # reported", not "down", so it writes nothing.
  defp ensure_default_instance(scope, %{root: root} = copy) when is_binary(root) and root != "" do
    case AppInstances.ensure_default(scope, copy) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp ensure_default_instance(_, _), do: :ok

  defp report_app_state(_scope, _copy, nil), do: :ok

  defp report_app_state(scope, copy, %{} = reported) do
    case resolve_reported_instance(scope, copy, reported["instance_id"]) do
      {:ok, instance} ->
        case reported["status"] do
          status when status in ~w(serving erroring down starting) ->
            case AppInstances.record_status(scope, instance, %{
                   instance_id: instance.id,
                   status: status,
                   url: reported["url"],
                   commit: reported["commit"],
                   serving_commit: reported["serving_commit"]
                 }) do
              {:ok, _} -> :ok
              error -> error
            end

          _ ->
            :ok
        end

      {:error, :no_default_instance} ->
        :ok

      error ->
        error
    end
  end

  defp report_app_state(_, _, _), do: :ok

  defp report_app_instances(_scope, _copy, nil), do: :ok

  defp report_app_instances(scope, copy, reports) when is_list(reports) do
    Enum.reduce_while(reports, :ok, fn
      %{"instance_id" => id} = report, :ok when is_binary(id) ->
        case report_app_state(scope, copy, report) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _, :ok ->
        {:halt, {:error, :invalid_app_instance_report}}
    end)
  end

  defp report_app_instances(_, _, _), do: {:error, :invalid_app_instance_report}

  defp resolve_reported_instance(scope, copy, nil) do
    case AppInstances.for_working_copy(scope, copy) do
      nil -> {:error, :no_default_instance}
      instance -> validate_instance_source(instance, copy)
    end
  end

  defp resolve_reported_instance(scope, copy, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> validate_instance_source(AppInstances.get(scope, id), copy)
      _ -> {:error, :invalid_app_instance}
    end
  end

  defp resolve_reported_instance(_, _, _), do: {:error, :invalid_app_instance}

  defp validate_instance_source(
         %{
           working_copy_id: copy_id,
           project_id: project_id,
           device_id: device_id,
           source_root: root
         } = instance,
         copy
       ) do
    if copy_id == copy.id and project_id == copy.project_id and device_id == copy.device_id and
         is_binary(copy.root) and root == Path.expand(copy.root),
       do: {:ok, instance},
       else: {:error, :instance_source_mismatch}
  end

  defp validate_instance_source(_, _), do: {:error, :instance_source_mismatch}

  # Kept against the working copy, since an agent's tool list is computed at
  # start from what its machine said. Absent (an older harness) writes nothing.
  defp record_machine_tools(_harness, nil, _docs), do: :ok

  defp record_machine_tools(harness, names, docs) when is_list(names) do
    WorkingCopies.record_machine_tools(harness, names, docs)
  end

  defp record_machine_tools(_harness, _other, _docs), do: :ok

  # Why the tool list was what it was. Absent is the column's `nil`, not an
  # error.
  defp record_browser_status(harness, %{"status" => status} = payload)
       when is_binary(status) do
    WorkingCopies.record_browser_status(harness, status, payload["error"])
  end

  defp record_browser_status(_harness, _other), do: :ok

  # Kept in step with `CmsHarness.Project.ChannelClient`'s copy. Bump on a
  # change to the join payload, the `handle_in` set, or the shapes those carry.
  # See knowledge/harness/channel, "Contract version".
  # v3 requires UUID instance descriptors, instance-tagged replies, and confirmed discard_app.
  @contract_version 3

  # How long a burst of record writes is gathered into one read-model push.
  @read_model_coalesce_ms 2_000

  @doc """
  The channel contract version this server speaks.

  Public so a test can compare it against `CmsHarness.Project.ChannelClient`'s
  copy; hardcoding either number would not catch a one-sided bump.
  """
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  # Refuses a mismatched contract at the join, once, with both numbers, rather
  # than letting skew surface later as `unmatched topic` on every stop.
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

  # A harness that predates the field: allowed, and logged once per join since
  # the absence is itself a clue to skew.
  defp check_contract(_payload, project_id) do
    Logger.info(
      "[HarnessProject] a harness joined #{project_id} without a contract version; " <>
        "it predates the field. Server speaks v#{@contract_version}."
    )

    :ok
  end

  # Runs the joining harness says it is still executing; only integers it
  # sent. Absent means everything is swept.
  defp claimed_runs(%{"active_runs" => ids}) when is_list(ids),
    do: Enum.filter(ids, &is_integer/1)

  defp claimed_runs(_payload), do: []

  @doc """
  Hand the harness the small slice of the domain that scanning needs.

  `Files.Scanner` needs no database except for a `ReadModel`: component module
  names, the project's story ids, and whether validation is strict. Small and
  slow-changing, so fetched rather than inferred.
  """
  @impl true
  def handle_in("read_model", _payload, socket) do
    scope = socket.assigns.scope
    read_model = %{Files.read_model(scope) | overlay_records: CopyOverlay.records(scope)}
    payload = serialize_read_model(read_model)

    {:reply, {:ok, Map.put(payload, "fingerprint", fingerprint(payload))}, socket}
  end

  # A checkout's file verdicts and repository state (`CopyOverlay`). Shadow:
  # stored, then compared with this server's rows once the copy's manifests
  # have reconciled. Nothing reads it.
  def handle_in("overlay", %{"verdicts" => verdicts} = payload, socket) when is_list(verdicts) do
    case CopyOverlay.report(socket.assigns.scope, payload) do
      {:ok, _report} ->
        socket =
          socket
          |> assign(:overlay_unchecked, true)
          |> check_overlay_when_quiet()
          |> follow_read_model()

        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("[HarnessProject] could not store an overlay: #{inspect(reason)}")
        {:reply, {:error, %{"reason" => "invalid_overlay"}}, socket}
    end
  end

  # A completed model turn from the sprite's proxy, recorded where the operator
  # reads it. Never replies: the harness casts it, and a failure is logged and
  # dropped.
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

    record_turn_tokens(scope, payload)

    {:noreply, socket}
  end

  # A harness's whole observation set, reconciled into File rows. The manifest,
  # not a delta: a delta cannot tell a deletion from an omission. An empty one
  # is refused, since reconciling it would delete every file row and "found
  # nothing" looks like "did not run".
  # See knowledge/harness/channel, "Manifests".
  def handle_in("observations", %{"observations" => []}, socket) do
    {:reply, {:error, %{"reason" => "empty_manifest"}}, socket}
  end

  def handle_in("observations", %{"observations" => observations}, socket)
      when is_list(observations) do
    # A manifest is proof of life: a stable connection never re-joins, so join
    # alone would let `last_seen_at` age past the reclaim window.
    WorkingCopies.mark_alive(socket.assigns.scope.active_working_copy_id)

    case deserialize_observations(observations) do
      {:ok, entries} ->
        {:reply, {:ok, %{"status" => "accepted", "observations" => length(entries)}},
         accept_manifest(socket, entries)}

      {:error, problems} ->
        # E.g. roles this server does not know. Rejected whole, with reasons,
        # rather than landing wrong rows. Synchronous: cheap, and actionable.
        Logger.warning("[HarnessProject] rejected manifest: #{inspect(problems)}")

        {:reply, {:error, %{"reason" => "invalid_manifest", "problems" => problems}}, socket}
    end
  end

  # Corrects `project.module_name` from the checkout's own `mix.exs`, which the
  # server cannot read for a harness-only project. Sent on every sync, so it
  # self-heals. From the **main** copy only: every copy sends it, and a copy
  # holding a different application would otherwise rename the project.
  def handle_in("module_name", %{"module_name" => name}, socket)
      when is_binary(name) and name != "" do
    project = current_project(socket)

    if project && project.module_name != name && main_copy?(socket) do
      case Projects.update_project(socket.assigns.scope, project, %{module_name: name}) do
        {:ok, updated} ->
          {:reply, :ok, put_in(socket.assigns.scope.active_project, updated)}

        {:error, reason} ->
          Logger.warning(
            "[HarnessProject] could not correct module_name to #{inspect(name)} for " <>
              "#{project.id}: #{inspect(reason)}"
          )

          {:reply, :ok, socket}
      end
    else
      {:reply, :ok, socket}
    end
  end

  # A blank or missing name has legitimate causes (checkout mid-write, unusual
  # `mix.exs`), so it is accepted and ignored.
  def handle_in("module_name", _payload, socket), do: {:reply, :ok, socket}

  # Same self-healing shape as `module_name`, for a check `Files` sync cannot
  # answer (it records existence, never a body).
  def handle_in("health_route_status", %{"status" => status}, socket)
      when status in ~w(ok no_health_route health_route_piped) do
    project = current_project(socket)

    if project && project.health_route_status != status do
      # `Repo.update/1` raises Ecto.StaleEntryError rather than returning
      # {:error, _} when the project's own lock_version moved under it --
      # a fresh join's report_root/2 and this correction can race within
      # milliseconds over a loopback connection. Self-healing like the rest
      # of this clause: the row already reflects a write at least as
      # current as this one, and the next status report corrects it anyway.
      try do
        case Projects.update_project(socket.assigns.scope, project, %{
               health_route_status: status
             }) do
          {:ok, updated} ->
            {:reply, :ok, put_in(socket.assigns.scope.active_project, updated)}

          {:error, reason} ->
            Logger.warning(
              "[HarnessProject] could not correct health_route_status to #{inspect(status)} " <>
                "for #{project.id}: #{inspect(reason)}"
            )

            {:reply, :ok, socket}
        end
      rescue
        error in Ecto.StaleEntryError ->
          Logger.warning(
            "[HarnessProject] could not correct health_route_status to #{inspect(status)} " <>
              "for #{project.id}: #{Exception.message(error)}"
          )

          {:reply, :ok, socket}
      end
    else
      {:reply, :ok, socket}
    end
  end

  def handle_in("health_route_status", _payload, socket), do: {:reply, :ok, socket}

  # Whether the application is answering, from the machine that can reach it.
  def handle_in("preview_status", %{"status" => status} = payload, socket)
      when status in ~w(serving erroring down) do
    with {:ok, instance} <-
           resolve_reported_instance(
             socket.assigns.scope,
             socket.assigns.harness,
             payload["instance_id"]
           ),
         {:ok, _} <- AppInstances.record_preview_status(socket.assigns.scope, instance, status) do
      {:reply, :ok, socket}
    else
      _ -> {:reply, :ok, socket}
    end
  end

  # Unprompted, from a first start's background watch: pushed the moment
  # `starting` resolves, rather than waiting for the next app verb to ask.
  def handle_in("app_status", %{"status" => status} = payload, socket)
      when status in ~w(serving erroring down starting) do
    case report_app_state(socket.assigns.scope, socket.assigns.harness, payload) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # An older harness's periodic report. Liveness is Presence now; answered
  # rather than unmatched so such a harness keeps its channel.
  def handle_in("agents_running", _payload, socket), do: {:reply, :ok, socket}

  # Which agents are alive. The channel tracks an agent in `Agents.Presence`
  # while the harness says it is up; Presence drops every key the moment the
  # channel dies, so a harness exit needs no report.
  #
  # The copy's first agent up after a join sweeps again (`consider_once/2`):
  # the sweep on `agents_present` runs before the harness has restored anyone.
  #
  # Every up is also that agent's own bell (`Agents.came_up/2`) — off this
  # process, for the same `:calling_self` reason as the sweep.
  def handle_in("agent_up", %{"agent_id" => id}, socket) when is_binary(id) do
    was_present? = MapSet.member?(present_agents(socket), id)
    socket = track_agents(socket, [id])
    scope = socket.assigns.scope

    if not was_present? and MapSet.member?(present_agents(socket), id) do
      {:ok, _pid} =
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          Agents.came_up(scope, id)
        end)
    end

    {:reply, :ok, consider_once(socket, :first_up)}
  end

  # A down the operator did not ask for is a crash: `Agents.process_ended/3`
  # decides whether it is restarted. Off this process — a restart asks the
  # harness through this channel, and calling from here is `:calling_self`.
  def handle_in("agent_down", %{"agent_id" => id} = payload, socket) when is_binary(id) do
    reason = payload["reason"]
    Logger.info("[AgentPresence] #{id} down on #{copy_id(socket)}: #{reason}")
    scope = socket.assigns.scope

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        Agents.process_ended(scope, id, reason)
      end)

    {:reply, :ok, ended(socket, id, reason)}
  end

  # The harness's whole set, on join: track what is new, untrack what is gone,
  # and sweep the copy for work — a harness that has just (re)connected is the
  # case with something to catch.
  #
  # `gave_up` (a newer harness) names the agents its Keepers gave up on, which
  # stay marked across a reconnect rather than reading as starting again.
  def handle_in("agents_present", %{"agent_ids" => ids} = payload, socket) when is_list(ids) do
    stuck = List.wrap(payload["gave_up"])
    stuck_ids = Enum.map(stuck, & &1["agent_id"])
    tracked = MapSet.union(present_agents(socket), gave_up_agents(socket))
    socket = track_agents(socket, ids)
    gone = MapSet.to_list(MapSet.difference(tracked, MapSet.new(ids ++ stuck_ids)))

    socket =
      Enum.reduce(stuck, untrack_agents(socket, gone), fn entry, socket ->
        mark_gave_up(socket, entry["agent_id"], entry["reason"], entry["at"])
      end)

    scope = socket.assigns.scope

    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Enum.each(ids, &Agents.Mailbox.pump(scope, &1))
    end)

    {:reply, :ok, consider_once(socket, :present)}
  end

  # What the box is carrying, from the box, so a saturated machine does not
  # read as several slow agents. Recorded against the device, not the copy:
  # checkouts on one machine share its processors.
  def handle_in("machine_load", load, socket) when is_map(load) do
    socket.assigns.scope.active_working_copy_id
    |> WorkingCopies.device_of()
    |> Devices.record_load(load)

    {:reply, :ok, socket}
  end

  # Accepted and dropped: older harnesses still send it, and `unknown_event`
  # would falsely signal skew. Delete once no harness sends it.
  def handle_in("git_state", _payload, socket), do: {:reply, :ok, socket}

  # Same self-healing shape as `module_name`, for the project's HEAD: the server
  # has no working directory to run `git` in for a harness-only project.
  def handle_in("head_commit", %{"sha" => sha}, socket)
      when is_binary(sha) and byte_size(sha) == 40 do
    scope = socket.assigns.scope
    project = scope.active_project

    # Certified means at a commit: a branch that moved past its stamp is not
    # ready for QA, and the graph says so as soon as the copy reports it.
    if scope.active_working_copy_id,
      do: release_moved_certifications(scope, scope.active_working_copy_id, sha)

    if project && project.head_commit != sha do
      case Projects.update_project(socket.assigns.scope, project, %{head_commit: sha}) do
        {:ok, updated} ->
          {:reply, :ok, put_in(socket.assigns.scope.active_project, updated)}

        {:error, reason} ->
          Logger.warning(
            "[HarnessProject] could not correct head_commit to #{inspect(sha)} for " <>
              "#{project.id}: #{inspect(reason)}"
          )

          {:reply, :ok, socket}
      end
    else
      {:reply, :ok, socket}
    end
  end

  def handle_in("head_commit", _payload, socket), do: {:reply, :ok, socket}

  # Decide a hook the harness is proxying for Claude Code, with the same
  # `Hooks.*` modules the local controllers call.
  #
  # In a task: task evaluation reads files via `handle_call({:fs_request, …})`
  # on *this* process, so deciding inline is `:calling_self`, and a failed read
  # looks like a missing file.
  # See knowledge/harness/channel, "Deferred replies".
  def handle_in("hook_decision", %{"hook" => hook, "payload" => payload} = msg, socket)
      when is_binary(hook) and is_map(payload) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope
    port = msg["port"]
    payload = with_budget(payload, msg["deadline_ms"])

    {:noreply,
     reply_async(socket, ref, {"decision", hook}, fn ->
       decision_reply(hook, scope, payload, port)
     end)}
  end

  # A skill invocation for this working copy; the light harness has no other
  # route to `/api/skills/start`. Deferred like `hook_decision`, and answered
  # even for an unknown skill.
  def handle_in("skill_start", %{"params" => params} = _msg, socket) when is_map(params) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope

    {:noreply, reply_async(socket, ref, "skill_start", fn -> skill_reply(scope, params) end)}
  end

  # What an analyzer printed on the machine that has the working copy. The
  # harness sends diagnostics, never Problems: `Analysis.record_remote_result/2`
  # puts them through the same `Runners.from_raw/2` a local run uses. The reply
  # is read on the far side, so a rejected result never looks recorded.
  #
  # Deferred: the reconcile reads files through this channel, which inline
  # would be `:calling_self`.
  def handle_in("analysis_result", %{"run_id" => _, "source" => source} = payload, socket) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope

    {:noreply,
     reply_async(socket, ref, {"analysis_result", source}, fn ->
       result_reply(scope, source, payload)
     end)}
  end

  # The commit an analyzer started on, and whether the tree was clean, from the
  # machine holding the checkout. Inline: one row update, and it must land
  # before this run's `analysis_result`, which is deferred.
  # Each event of a run as it happens (story 1141). An event for a run that is
  # not running here is dropped: a late event of a run already closed.
  def handle_in("analysis_event", %{"run_id" => run_id, "event" => %{} = event}, socket)
      when is_integer(run_id) do
    _ = Analysis.record_live_event(socket.assigns.scope, run_id, event)
    {:reply, :ok, socket}
  end

  def handle_in("analysis_started", payload, socket) do
    case Analysis.record_remote_start(socket.assigns.scope, payload) do
      {:ok, _run} ->
        :ok

      {:error, :unknown_run} ->
        Logger.info(
          "[HarnessProject] start of run #{inspect(payload["run_id"])} not recorded: " <>
            Analysis.explain_unknown_run(socket.assigns.scope, payload["run_id"])
        )
    end

    {:reply, :ok, socket}
  end

  # The agent's own `mix test`, routed through here so it is recorded and the
  # stop hook does not run the same suite again. Deferred reply: `await_run/4`
  # takes as long as the suite, and holding the channel starves stop decisions.
  def handle_in("analysis_run", %{"source" => source} = payload, socket)
      when is_binary(source) do
    args = List.wrap(payload["args"] || [])
    ref = socket_ref(socket)
    scope = socket.assigns.scope
    owner = self()
    request_id = make_ref()

    {:noreply,
     reply_async(socket, ref, {"analysis_run", source, request_id}, fn ->
       admitted = fn run_id -> send(owner, {:analysis_admitted, request_id, run_id}) end
       run_for_agent(scope, source, args, admitted)
     end)}
  end

  # Wait until this project's analyzers are idle, then report.
  #
  # Replied out of band like `analysis_run`: the wait is minutes. A channel
  # message (reaching the agent over HTTP) because MCP caps a request at 30s.
  def handle_in("analysis_wait", _payload, socket) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope

    reply =
      fn ->
        result = CodeMySpec.Analysis.await_all(scope, timeout: :timer.minutes(20))
        {:ok, %{"state" => to_string(result), "summary" => wait_summary(scope)}}
      end

    {:noreply, reply_async(socket, ref, "analysis_wait", reply)}
  end

  # Promote this working copy, and answer with what happened. Runs here because
  # the gate reads the database; the disk half goes back as named `fs_request`
  # ops. Deferred: `Promotion.promote/1` calls back into this channel with
  # `{:fs_request, …}`, which inline is `:calling_self`.
  def handle_in("promotion_run", payload, socket) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope
    story_number = payload["story_number"]

    {:noreply,
     reply_async(socket, ref, "promotion_run", fn -> promote_for_caller(scope, story_number) end)}
  end

  @impl true
  # Which agents this working copy is supposed to be running, asked on join.
  # Answered with the desired state, not the last observation, so a stopped
  # agent is simply absent.
  def handle_in("agents_to_restore", _payload, socket) do
    scope = socket.assigns.scope
    ref = socket_ref(socket)

    {:noreply,
     reply_async(socket, ref, "agents_to_restore", fn ->
       result =
         CodeMySpec.Requirements.IncrementalGraph.with_read_deadline(1_000, fn ->
           with {:ok, _pid} <- CodeMySpec.Requirements.GraphWatcher.ensure_watching(scope),
                :ok <- CodeMySpec.Requirements.GraphWatcher.settle(scope),
                %{seeded: true, last_error: nil} <-
                  CodeMySpec.Requirements.GraphWatcher.status(scope.active_project_id) do
             restore_agents(scope)
           else
             _ -> {:error, :graph_rebuilding}
           end
         end)

       case result do
         {:error, :graph_rebuilding} ->
           {:error, %{"reason" => "graph_rebuilding", "retry_after_ms" => 5_000}}

         reply ->
           reply
       end
     end)}
  end

  def handle_in(
        "agent_mailbox",
        %{"operation" => "register", "agent_id" => id, "generation" => generation},
        socket
      )
      when is_binary(generation) do
    scope = socket.assigns.scope

    with {:ok, agent} <- Agents.fetch_agent(scope, id),
         true <- agent.working_copy_id == scope.active_working_copy_id,
         {:ok, _} <- Agents.Mailbox.register(scope, id, generation) do
      {:reply, {:ok, %{}}, socket}
    else
      _ -> {:reply, {:error, %{reason: "mailbox registration refused"}}, socket}
    end
  end

  def handle_in(
        "agent_mailbox",
        %{"operation" => "consume", "agent_id" => id, "ref" => ref, "generation" => generation},
        socket
      ) do
    scope = socket.assigns.scope

    with {:ok, agent} <- Agents.fetch_agent(scope, id),
         true <- agent.working_copy_id == scope.active_working_copy_id,
         {:ok, _} <- Agents.Mailbox.consume(scope, id, ref, generation) do
      {:reply, {:ok, %{}}, socket}
    else
      _ -> {:reply, {:error, %{reason: "mailbox consumption refused"}}, socket}
    end
  end

  # One step an agent took, written to its conversation as it arrives, not
  # buffered: the turns worth watching are the ones that do not finish cleanly.
  def handle_in("agent_turn_event", %{"agent_id" => agent_id, "event" => event}, socket) do
    Agents.record_turn_event(socket.assigns.scope, agent_id, event)
    record_turn_usage(socket.assigns.scope, agent_id, event)
    settle_draft(socket, agent_id, event)
    {:reply, :ok, socket}
  end

  # What an agent is writing, before it is a message. Held and broadcast, never
  # written to the database — the message it becomes is the record. Arrives
  # every 100ms while an agent writes, so the conversation it belongs to is
  # looked up once and cached on the socket rather than read per draft.
  def handle_in("agent_draft", %{"agent_id" => agent_id, "text" => text}, socket)
      when is_binary(text) do
    case draft_conversation(socket, agent_id) do
      {:ok, conversation_id, socket} ->
        Drafts.put(conversation_id, text)
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_in("agent_start_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_start_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("create_working_copy_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_create_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("agent_send_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_send_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("agent_stop_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_stop_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in(event, %{"ref" => ref} = msg, socket)
      when event in [
             "ensure_app_running_result",
             "restart_app_result",
             "reload_app_result",
             "stop_app_result",
             "discard_app_result"
           ] do
    case Map.pop(socket.assigns[:pending_apps] || %{}, ref) do
      {nil, _} ->
        {:reply, {:error, %{reason: "unknown_app_request"}}, socket}

      {{from, instance_id, expected_event}, pending} ->
        result =
          with true <- event == expected_event,
               true <- msg["instance_id"] in [nil, instance_id],
               {:ok, instance} <-
                 resolve_reported_instance(
                   socket.assigns.scope,
                   socket.assigns.harness,
                   instance_id
                 ) do
            decode_instance_result(msg, instance, event)
          else
            _ -> {:error, :instance_source_mismatch}
          end

        GenServer.reply(from, result)
        {:reply, :ok, assign(socket, :pending_apps, pending)}
    end
  end

  def handle_in("tool_call_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_machine_tool(socket), ref)
    if from, do: GenServer.reply(from, decode_machine_tool_result(msg))
    {:reply, :ok, assign(socket, :pending_machine_tool, pending)}
  end

  # The harness's answer to a filesystem request; see `handle_call/3`. An
  # unknown ref (caller gave up) is dropped rather than crashing the channel.
  def handle_in("fs_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(socket.assigns[:pending_fs] || %{}, ref)
    if from, do: GenServer.reply(from, decode_fs_result(msg))
    {:noreply, assign(socket, :pending_fs, pending)}
  end

  # An unknown event is answered, not dropped: silence makes version skew read
  # as latency on the far side.
  def handle_in(event, _payload, socket) do
    Logger.warning("[HarnessProject] unknown event #{inspect(event)}")
    {:reply, {:error, %{"reason" => "unknown_event", "event" => event}}, socket}
  end

  # The DB write behind every app verb's reply, never gating the reply: the
  # far side did act either way.

  # The row as it stands, not the copy the join took: a correction made since
  # would otherwise read as stale and be written again.
  defp current_project(socket) do
    case socket.assigns.scope.active_project do
      %{id: id} -> Projects.get_project_by_id(id)
      nil -> nil
    end
  end

  defp decode_instance_result(msg, instance, event)
       when event in ["stop_app_result", "discard_app_result"] do
    case decode_stop_result(msg) do
      :ok ->
        AppInstances.record_status(%Scope{active_project_id: instance.project_id}, instance, %{
          instance_id: instance.id,
          status: "down"
        })

        :ok

      error ->
        error
    end
  end

  defp decode_instance_result(msg, instance, _event) do
    case decode_app_result(msg) do
      {:ok, info} ->
        info = Map.put(info, :instance_id, instance.id)

        case AppInstances.record_status(
               %Scope{active_project_id: instance.project_id},
               instance,
               info
             ) do
          {:ok, _} -> {:ok, info}
          error -> error
        end

      error ->
        error
    end
  end

  # Sweep the copy for work when the harness re-registers its agents:
  # `Work.consider_*` is edge-triggered and a restart is no edge. At most twice
  # per join — `agents_present` (`:present`) and the first agent up after it
  # (`:first_up`), since the first runs before anything is restored.
  #
  # In a Task: the sweep reaches this copy's holder, which is this channel, so
  # inline is `:calling_self`.
  # See knowledge/harness/channel, "Reconnect sweep".
  defp consider_once(socket, trigger) do
    swept = socket.assigns[:swept] || MapSet.new()

    if MapSet.member?(swept, trigger),
      do: socket,
      else: socket |> assign(:swept, MapSet.put(swept, trigger)) |> sweep()
  end

  defp sweep(socket) do
    scope = socket.assigns.scope
    copy_id = scope.active_working_copy_id

    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Agents.Work.consider_copy(scope, copy_id, :harness_reconnected)

      # And the agents `consider_copy/4` cannot reach: a restart discards the
      # turn but leaves the task held, and admission refuses an agent holding one.
      Agents.Work.resume_held_tasks(scope, copy_id)
      Agents.CompletionHandoffs.recover(scope, copy_id)

      # The retry-time wakes of agents refused until later, which lived in the
      # process a restart took down.
      Agents.RefusalWake.rearm(scope, copy_id)

      # Re-arm the main agent's cadence: its watcher died with the old process,
      # and a reconnect is no state transition, so nothing else restarts it.
      # Idempotent.
      MainAgent.ensure_cadence(scope)
    end)

    socket
  end

  # Unknown copy answers false: a correction not attributable to the main
  # checkout is not applied.
  defp main_copy?(socket) do
    case WorkingCopies.fetch(socket.assigns.scope.active_working_copy_id) do
      {:ok, copy} -> copy.main
      _ -> false
    end
  end

  # A filesystem operation for the working copy this channel serves.
  #
  # The transport half of `ExecutionContexts.Harness`: the harness applies it
  # against the disk that holds the checkout. Reads and writes. Replied out of
  # band: `from` is parked against a ref and answered by `handle_in("fs_result", …)`.
  @impl true
  def handle_call({:fs_request, op, payload}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "fs_request", %{"ref" => ref, "op" => op, "payload" => payload})

    {:noreply, assign(socket, :pending_fs, Map.put(pending_fs(socket), ref, from))}
  end

  # Launching an agent, on the machine that will hold the process. The request
  # is built here rather than by `Agents.Transport.Harness`: its tool index
  # reads the MCP servers, which `Agents` sits below.
  @impl true
  def handle_call({:start_agent, %Agents.Agent{} = agent}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))
    request = LaunchRequest.for(agent, ToolRegistry.registry())

    push(socket, "start_agent", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  def handle_call({:dispatch_mailbox, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))
    push(socket, "mailbox_delivery", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  def handle_call({:request_work_turn, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))
    push(socket, "request_work_turn", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  # A script asked for something that lives on the machine — a browser, today.
  # Same shape as every other push here: ref out, reply correlated back.
  def handle_call({:call_machine_tool, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "tool_call", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_machine_tool, Map.put(pending_machine_tool(socket), ref, from))}
  end

  # Make a checkout on this machine's disk. Addressed to the machine rather
  # than a copy (see `Analysis.host_holder/1`); the harness makes and onboards
  # the worktree and the server records what comes back.
  def handle_call({:create_working_copy, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "create_working_copy", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  # Stopping an agent on its machine. The answer matters: a stop is recorded
  # only if this comes back `:ok`.
  def handle_call({:stop_agent, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "stop_agent", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  # Bring this copy's own app up, restart it, or stop it. Same shape as every
  # request above: ref out, reply correlated back on the `_result` push.
  def handle_call({verb, request}, from, socket)
      when verb in [:ensure_app_running, :restart_app, :reload_app, :stop_app, :discard_app] do
    with :ok <- supported_app_verb(verb, socket),
         {:ok, instance} <- requested_instance(request, socket) do
      ref = Integer.to_string(System.unique_integer([:positive]))
      event = Atom.to_string(verb)
      payload = %{"instance" => AppInstances.descriptor(instance), "ref" => ref}

      payload =
        if verb in [:stop_app, :discard_app], do: payload, else: put_tunnel(payload, instance)

      push(socket, event, payload)

      pending =
        Map.put(socket.assigns[:pending_apps] || %{}, ref, {from, instance.id, "#{event}_result"})

      {:noreply, assign(socket, :pending_apps, pending)}
    else
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  defp supported_app_verb(:reload_app, socket) do
    if HarnessRegistry.supports?(socket.assigns.harness.id, "reload_app"),
      do: :ok,
      else: {:error, :reload_not_supported}
  end

  defp supported_app_verb(_, _), do: :ok

  defp requested_instance(request, socket) do
    descriptor = request[:instance] || request["instance"]

    with %{"instance_id" => id} <- descriptor,
         {:ok, instance} <-
           resolve_reported_instance(socket.assigns.scope, socket.assigns.harness, id),
         true <- descriptor == AppInstances.descriptor(instance) do
      {:ok, instance}
    else
      _ -> {:error, :instance_source_mismatch}
    end
  end

  # The harness holds the tunnel, not the app it launches. Told fresh: read
  # from the row, since `socket.assigns.harness` is only fresh at join.
  defp put_tunnel(request, instance) do
    case tunnel_for(instance) do
      nil -> request
      tunnel -> Map.put(request, "tunnel", tunnel)
    end
  end

  # The one place that decides which tunnel a copy's harness runs, shared by
  # `put_tunnel/2` and the join reply. Every copy on a machine gets that
  # machine's one tunnel. `nil` when there is none.
  defp tunnel_for(copy) do
    case PreviewTunnel.machine_credentials(copy) do
      {:ok, creds} ->
        %{
          "hostname" => creds.hostname,
          "tunnel_id" => creds.tunnel_id,
          "tunnel_secret" => creds.tunnel_secret,
          "account_tag" => creds.account_tag
        }

      :error ->
        nil
    end
  end

  defp pending_fs(socket), do: socket.assigns[:pending_fs] || %{}

  defp pending_agent_stop(socket), do: socket.assigns[:pending_agent_stop] || %{}

  defp pending_machine_tool(socket), do: socket.assigns[:pending_machine_tool] || %{}

  # The machine's answer, in the shape a tool's caller expects; an error stays
  # an error rather than folding into the text.
  defp decode_machine_tool_result(%{"error" => reason}), do: {:error, reason}
  defp decode_machine_tool_result(%{"text" => text}), do: {:ok, text}
  defp decode_machine_tool_result(other), do: {:error, {:unexpected_reply, other}}

  # A created copy is its root and the identity written into it; neither alone
  # lets the server record a checkout.
  defp decode_create_result(%{"status" => "ok", "root" => root, "working_copy_id" => id})
       when is_binary(root) and root != "" and is_binary(id),
       do: {:ok, %{root: root, working_copy_id: id}}

  defp decode_create_result(%{"status" => "error", "reason" => reason}),
    do: {:error, decode_reason(reason)}

  defp decode_create_result(other), do: {:error, {:unexpected_create_result, other}}

  defp decode_start_result(%{"status" => "ok", "agent_id" => agent_id})
       when is_binary(agent_id),
       do: {:ok, %{agent_id: agent_id}}

  defp decode_start_result(%{"status" => "error", "reason" => reason}),
    do: {:error, decode_reason(reason)}

  defp decode_start_result(other), do: {:error, {:unexpected_start_result, other}}

  # The failures a machine can name, and nothing else: atoms are never
  # collected, and arbitrary provider prose reaches this decoder. Anything else
  # stays a string.
  @machine_reasons ~w(
    agent_id_required
    working_copy_missing
    not_running
    still_running
    unknown_provider
    unknown_engine
    no_engine
    credential_missing_api_key
    credential_missing_auth_path
    harness_not_connected
    start_timed_out
    stop_timed_out
    message_timed_out
    already_delivered
    busy
    duplicate
  )

  defp decode_reason(reason) when reason in @machine_reasons, do: String.to_atom(reason)
  defp decode_reason(reason), do: reason

  # What became of a message the operator sent. Anything unreadable is an
  # error, never a default disposition.
  defp decode_send_result(%{"status" => "ok", "disposition" => "started"}), do: {:ok, :started}

  defp decode_send_result(%{"reason" => reason}) when is_binary(reason),
    do: {:error, decode_reason(reason)}

  defp decode_send_result(_msg), do: {:error, :unreadable_send_result}

  defp decode_stop_result(%{"status" => "ok"}), do: :ok

  defp decode_stop_result(%{"status" => "error", "reason" => reason}),
    do: {:error, decode_reason(reason)}

  # A shape this server does not understand is not a stop.
  defp decode_stop_result(other), do: {:error, {:unexpected_stop_result, other}}

  # The `app_*` fields are optional; absent reads as unchanged. `Map.get/2`
  # rather than a second clause: a stricter map clause below would never match.
  defp decode_app_result(%{"status" => "ok", "app_status" => status} = msg)
       when status in ~w(serving erroring down starting) do
    {:ok,
     %{
       status: status,
       url: Map.get(msg, "app_url"),
       commit: Map.get(msg, "app_commit"),
       serving_commit: Map.get(msg, "app_serving_commit"),
       head: Map.get(msg, "app_head"),
       action: Map.get(msg, "app_action"),
       action_reason: Map.get(msg, "app_action_reason")
     }}
  end

  defp decode_app_result(%{"status" => "error", "reason" => reason}),
    do: {:error, decode_reason(reason)}

  defp decode_app_result(other), do: {:error, {:unexpected_app_result, other}}

  # Every deferred reply on this channel, and the promise that one arrives.
  # The task computes the answer; the channel sends it. `async_nolink/2`
  # monitors at spawn (no `:noproc` race), `{ref, result}` arrives before
  # `:DOWN`, and a `:DOWN` still holding an entry is answered `handler_died`.
  # One reply per request, decided in one process.
  # See knowledge/harness/channel, "Deferred replies".
  defp restore_agents(scope) do
    # The same request a fresh start sends, with credential and conversation.
    # On duty only: an off or retired agent is never brought back.
    on_duty =
      scope
      |> Agents.list_on_duty()
      |> Enum.filter(&(&1.working_copy_id == scope.active_working_copy_id))

    # A terminal session is a person's process, never launched here: the
    # harness re-attaches each one still running (story 1124).
    {terminals, running} = Enum.split_with(on_duty, &is_binary(&1.engine_session_id))

    :ok = Agents.account_for_interrupted_turns(scope, running)

    tools = ToolRegistry.registry()
    agents = Enum.map(running, &(scope |> LaunchRequest.hydrate(&1) |> LaunchRequest.for(tools)))

    reattach =
      Enum.map(terminals, fn agent ->
        %{
          "agent_id" => agent.id,
          "session_id" => agent.engine_session_id,
          "engine" => to_string(agent.engine),
          "transcript_path" => agent.transcript_path
        }
      end)

    {:ok, %{"agents" => agents, "terminals" => reattach}}
  end

  defp reply_async(socket, ref, label, fun) do
    task = Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fun)

    assign(
      socket,
      :pending_replies,
      Map.put(pending_replies(socket), task.ref, {ref, label, task.pid})
    )
  end

  # The answer the task computed. Removing the entry here is what makes its
  # absence mean "already answered" when the `:DOWN` follows.
  defp deliver_pending(socket, task_ref, result) do
    case Map.pop(pending_replies(socket), task_ref) do
      {nil, _} ->
        socket

      {{ref, _label, _pid}, pending} ->
        # `:flush` because the `:DOWN` is already on its way and there is
        # nothing left for it to say.
        Process.demonitor(task_ref, [:flush])
        Phoenix.Channel.reply(ref, result)
        assign(socket, :pending_replies, pending)
    end
  end

  # A `:DOWN` still holding an entry is a task that died without answering.
  # One that does not is the ordinary end of a task whose result was delivered
  # above, and there is nothing left to say about it.
  defp resolve_pending(socket, task_ref, reason) do
    case Map.pop(pending_replies(socket), task_ref) do
      {nil, _} ->
        socket

      {{ref, label, _pid}, pending} ->
        Logger.error("[HarnessProject] #{describe(label)} died: #{death_reason(reason)}")

        Phoenix.Channel.reply(
          ref,
          {:error, handler_failure(label, reason)}
        )

        assign(socket, :pending_replies, pending)
    end
  end

  defp pending_replies(socket), do: socket.assigns[:pending_replies] || %{}

  # Admission identifies a running analysis before its waiter can die. A DOWN
  # reply must not query the database from the channel process: losing sandbox
  # ownership there would kill the channel instead of answering the caller.
  defp handler_failure({"analysis_run", _source, _request_id, run_id} = label, reason) do
    %{
      "reason" => "handler_died",
      "at" => describe(label),
      "handler_error" => death_reason(reason),
      "run_id" => run_id,
      "status" => "running"
    }
  end

  defp handler_failure(label, reason) do
    %{
      "reason" => "handler_died",
      "at" => describe(label),
      "handler_error" => death_reason(reason)
    }
  end

  defp describe({"analysis_run", source, _request_id, run_id}),
    do: "analysis_run (#{source}, run #{run_id})"

  defp describe({"analysis_run", source, _request_id}), do: "analysis_run (#{source})"
  defp describe({handler, detail}), do: "#{handler} (#{detail})"
  defp describe(handler), do: handler

  # How long the harness will wait for this answer (c93e5fdc): `Hooks.Stop`
  # bounds its own work against it so the harness is answered, not timed out.
  defp with_budget(payload, ms) when is_integer(ms) and ms > 0,
    do: Map.put(payload, "harness_budget_ms", ms)

  defp with_budget(payload, _unnamed), do: payload

  defp decision_reply(hook, scope, payload, port) do
    case decide_hook(hook, scope, payload, port) do
      {:error, reason} -> {:error, %{"reason" => reason}}
      {200, body} -> {:ok, body}
      {status, body} when is_integer(status) -> {:error, %{"status" => status, "body" => body}}
    end
  end

  # A bad skill invocation comes back as a reply, never a dead channel.
  defp skill_reply(scope, params) do
    case SkillRouter.resolve(scope, params) do
      {:ok, result} -> {:ok, result}
      {:error, reason, available} -> {:error, %{"error" => reason, "available" => available}}
      {:error, reason} -> {:error, %{"error" => reason}}
    end
  end

  # `explain_unknown_run/2` tells "already closed" from "belongs to another
  # checkout", which otherwise read identically.
  defp result_reply(scope, source, payload) do
    case Analysis.record_remote_result(scope, payload) do
      {:ok, run} ->
        {:ok, %{"run_id" => run.id, "status" => to_string(run.status)}}

      {:error, {:refused, reason}} ->
        Agents.notify_main(scope, :teammate_stalled, "#{source} analyzer refused: #{reason}")
        {:ok, %{"run_id" => payload["run_id"], "status" => "refused"}}

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
  end

  # What `File` and `ExecutionContexts.Local` fail with, and nothing else.
  #
  # Callers match on `:enoent` and friends, so these come back as the atoms
  # they left as. A literal map, so nothing off the wire becomes an atom.
  @fs_reasons Map.new(
                ~w(enoent eacces eperm eisdir enotdir eexist enotempty enospc edquot
                   erofs ebusy etxtbsy enametoolong eloop exdev emfile enfile efbig eio
                   einval ebadf enomem espipe emlink badarg not_regular
                   no_working_directory)a,
                &{Atom.to_string(&1), &1}
              )

  # The harness reports outcomes the way the behaviour states them, so this only
  # has to put the shape back together.
  @doc false
  def decode_fs_result(%{"error" => reason}) when is_binary(reason),
    do: {:error, Map.get_lazy(@fs_reasons, reason, fn -> decode_reason(reason) end)}

  # A refusal that arrived with structure keeps it: `Promotion.Steps` answers
  # with a sentence and its evidence, passed through for `Promotion.Runner`.
  def decode_fs_result(%{"error" => %{} = reason}), do: {:error, reason}

  def decode_fs_result(%{"ok" => true, "result" => result}), do: {:ok, result}

  # File contents that are not text, which the harness sends as base64
  # (`ChannelClient.encode_fs_result/1`).
  def decode_fs_result(%{"ok" => true, "result_base64" => encoded}) when is_binary(encoded),
    do: {:ok, Base.decode64!(encoded)}

  def decode_fs_result(%{"ok" => true}), do: :ok
  def decode_fs_result(other), do: {:error, {:unreadable_fs_result, other}}

  defp wait_summary(scope) do
    counts =
      scope
      |> CodeMySpec.Problems.list_project_problems([])
      |> Enum.group_by(& &1.source)
      |> Map.new(fn {source, problems} -> {source, length(problems)} end)

    scope
    |> CodeMySpec.Analysis.status()
    |> Enum.map_join("\n", fn {source, %{state: state} = entry} ->
      "- #{source}: #{state}, #{Map.get(counts, source, 0)} problem(s)" <>
        why_it_failed(state, entry[:run])
    end)
  end

  # Why a failed analyzer failed, on the line that says it failed:
  # `Reconciler.fail/2` persists it to `stats["error"]`. Without it "failed,
  # 0 problem(s)" reads like load. First line only, truncated.
  defp why_it_failed(:failed, %{stats: %{"error" => error}}) when is_binary(error) do
    case String.trim(error) do
      "" -> ""
      text -> "\n    " <> truncate_reason(text)
    end
  end

  defp why_it_failed(_state, _run), do: ""

  @reason_limit 400

  defp truncate_reason(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> then(fn line ->
      if String.length(line) > @reason_limit do
        String.slice(line, 0, @reason_limit) <> "…"
      else
        line
      end
    end)
  end

  # `Analysis` dispatches a run by sending here: the executor in
  # `HarnessRegistry` is this process, so liveness and work share a pid. Can be
  # sent by this process to itself from a stop decision; it lands after that
  # decision, which is made from what is already recorded.
  @impl true
  # Admission, dispatch and DOWN arrive from the same task in order. Keep the
  # identity per request: concurrent callers may request the same source.
  # Losing this waiter must not cancel or fail the independently executing run.
  def handle_info({:analysis_admitted, request_id, run_id}, socket) do
    pending =
      Map.new(pending_replies(socket), fn
        {task_ref, {ref, {"analysis_run", source, ^request_id}, pid}} ->
          {task_ref, {ref, {"analysis_run", source, request_id, run_id}, pid}}

        entry ->
          entry
      end)

    {:noreply, assign(socket, :pending_replies, pending)}
  end

  def handle_info({:run_analysis, runs}, socket) do
    push(socket, "run_analysis", %{"runs" => runs})
    {:noreply, socket}
  end

  # Ask for a fresh manifest. No payload: the channel already names the copy,
  # and a root on the wire would be a second answer.
  # A record the read model holds moved. Coalesced: a burst of writes is one
  # refresh.
  def handle_info(
        {:read_model_changed, _project_id},
        %{assigns: %{read_model_due: true}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:read_model_changed, _project_id}, socket) do
    Process.send_after(self(), :read_model_changed, @read_model_coalesce_ms)
    {:noreply, assign(socket, :read_model_due, true)}
  end

  def handle_info(:read_model_changed, socket) do
    push(socket, "read_model_changed", %{})
    {:noreply, assign(socket, :read_model_due, false)}
  end

  def handle_info(:rescan, socket) do
    push(socket, "rescan", %{})
    {:noreply, socket}
  end

  # A message sent now to a busy agent: the machine stops its turn.
  def handle_info({:interrupt_turn, agent_id}, socket) do
    push(socket, "interrupt_turn", %{"agent_id" => agent_id})
    {:noreply, socket}
  end

  # One run, by id: somebody cancelled it (story 1142).
  def handle_info({:cancel_run, run_id}, socket) do
    push(socket, "cancel_analysis", %{"run_id" => run_id, "reason" => "cancelled"})
    {:noreply, socket}
  end

  def handle_info({:cancel_analysis, reason}, socket) do
    push(socket, "cancel_analysis", %{"reason" => reason})
    {:noreply, socket}
  end

  # This copy was offboarded, so tell the machine to stop serving it.
  #
  # Sent after the offboard commits, so the push carries nothing to look up.
  # Pushed and forgotten: an offboard must work for a machine that is off.
  def handle_info({:offboarded, _working_copy_id}, socket) do
    push(socket, "offboard", %{"instance_disposition" => "discard"})
    {:noreply, socket}
  end

  # Issue 37f35126: `Staffing.mint/2`'s own registration (`WorkingCopies.issue/3`,
  # `report_root/2`) runs in the caller's process, after this channel already
  # replied to the "create_working_copy_result" push that unblocked it -- so
  # the harness's transport-level ack of that push never carried whether
  # registration itself succeeded. This tells it explicitly, pushed and
  # forgotten like `:offboarded` above: a harness that has since disconnected
  # falls back to its own ack-timeout rollback, same as before this existed.
  def handle_info({:working_copy_registered, working_copy_id, outcome}, socket) do
    push(
      socket,
      "create_working_copy_registered",
      encode_registration_outcome(working_copy_id, outcome)
    )

    {:noreply, socket}
  end

  # Reconcile counts, logged here because the reply leaves before they exist.
  def handle_info({ref, counts}, %{assigns: %{reconciling: %Task{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])

    # Named by working copy, so alternating checkouts do not read as one.
    Logger.info(
      "[HarnessProject] reconciled #{socket.assigns.harness.root || socket.assigns.harness.id}: " <>
        "#{counts.upserted} upserted, #{counts.removed} removed, " <>
        "#{counts.changed} changed, #{component_count(counts.components)}"
    )

    {:noreply, next_manifest(socket)}
  end

  # A failed batch rolls back only itself. Keep the already received manifest
  # in this channel and retry once: committed upserts are no-ops, so the same
  # observation set resumes without a filesystem scan or a socket reconnect.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{reconciling: %Task{ref: ref}}} = socket
      ) do
    Logger.error("[HarnessProject] reconcile failed: #{inspect(reason)}")

    socket =
      cond do
        socket.assigns.pending_manifest != nil ->
          next_manifest(socket)

        socket.assigns.reconcile_retries < 1 ->
          entries = socket.assigns.reconciling_manifest
          Logger.warning("[HarnessProject] retrying received manifest after reconcile failure")

          socket
          |> assign(:reconciling, start_reconcile(socket.assigns.scope, entries))
          |> assign(:reconcile_retries, socket.assigns.reconcile_retries + 1)

        true ->
          Logger.error("[HarnessProject] manifest retry failed; waiting for a newer manifest")
          next_manifest(socket)
      end

    {:noreply, socket}
  end

  # A deferred reply's answer, and then its task ending (see `reply_async/4`).
  # Below the reconcile clauses on purpose, or these would swallow its result
  # and its `:DOWN`.
  def handle_info({task_ref, result}, socket) when is_reference(task_ref),
    do: {:noreply, deliver_pending(socket, task_ref, result)}

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, socket),
    do: {:noreply, resolve_pending(socket, task_ref, reason)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp encode_registration_outcome(working_copy_id, :ok),
    do: %{"working_copy_id" => working_copy_id, "status" => "ok"}

  defp encode_registration_outcome(working_copy_id, {:error, reason}),
    do: %{"working_copy_id" => working_copy_id, "status" => "error", "reason" => inspect(reason)}

  # The agent reads this as test output, so the tool's own text is the body. An
  # error still answers in that shape, never as empty output that reads as a pass.
  defp run_for_agent(scope, source, args, admitted) do
    case Analysis.await_run(scope, source, args,
           requested_by: %{kind: "agent_mix_test"},
           on_admitted: admitted
         ) do
      {:ok, %{} = run} ->
        {:ok,
         %{
           "run_id" => run.id,
           "status" => to_string(run.status),
           "output" => run.output || "",
           "exit_status" => run.exit_status,
           "stats" => run.stats || %{}
         }}

      # 783f3709: the agent's own `mix test`/`mix spex` routes through here,
      # so a hold has to be said plainly rather than folded into the generic
      # transport-failure wording below.
      {:error, {:held, hold}} ->
        {:error, %{"reason" => "held", "message" => FleetHolds.refusal(hold)}}

      {:error, reason} ->
        Logger.warning("[HarnessProject] #{source} run for the agent failed: #{inspect(reason)}")
        {:error, %{"reason" => inspect(reason)}}
    end
  end

  # A promotion's outcome as the caller reads it; always `{:ok, …}`. A refusal
  # is an answer (`"refused"`); `{:error, …}` on this wire would mean it could
  # not be attempted, which the HTTP door reports as a 502. Words come from
  # `Responses`, shared with the other doors.
  #
  # Inside the harness's own wait for this reply, so a candidate still queued
  # is answered as queued rather than as a timeout.
  @promotion_wait_ms :timer.minutes(18)

  defp promote_for_caller(scope, story_number) do
    result = PromotionQueue.promote_and_wait(scope, story_number, [], @promotion_wait_ms)

    {:ok, %{"status" => promotion_status(result), "report" => PromotionResponses.text(result)}}
  end

  defp promotion_status({:ok, %{queued: _}}), do: "queued"
  defp promotion_status({:ok, %{queue_outcome: _}}), do: "promoted"
  defp promotion_status({:ok, %{pending: _}}), do: "pending"
  defp promotion_status({:ok, _report}), do: "promoted"
  defp promotion_status({:error, _refusal}), do: "refused"

  # Reconciling a large manifest inline would starve stop decisions queued
  # behind it, so the channel tracks the work instead of doing it. One in
  # flight, one pending, newest wins: `reconcile/2` removes rows absent from
  # its set, so two at once would delete each other's files.
  #
  # Inline under `analysis_mode: :inline` (tests), where a task would be outside
  # the SQL sandbox; the reply is identical either way.
  # See knowledge/harness/channel, "Manifests".
  defp accept_manifest(socket, entries) do
    cond do
      Application.get_env(:code_my_spec, :analysis_mode) == :inline ->
        reconcile(socket.assigns.scope, entries)
        socket

      socket.assigns.reconciling == nil ->
        maybe_start_reconcile(socket, entries)

      true ->
        assign(socket, :pending_manifest, entries)
    end
  end

  # The same question `assigns.reconciling` answers, asked across channels: for
  # a reconcile orphaned when `terminate/2` did not run. Skipped rather than
  # queued (the running one lands the same tree), and logged loudly because
  # this copy's rows are behind until it finishes.
  defp maybe_start_reconcile(socket, entries) do
    working_copy_id = socket.assigns.scope.active_working_copy_id

    case ReconcileRegistry.in_flight(working_copy_id) do
      nil ->
        socket
        |> assign(:reconciling, start_reconcile(socket.assigns.scope, entries))
        |> assign(:reconciling_manifest, entries)
        |> assign(:reconcile_retries, 0)

      %{count: count, started_at: started_at} ->
        Logger.warning(
          "[HarnessProject] skipped a reconcile of #{length(entries)} observations for " <>
            "harness #{working_copy_id}: one of #{count} started at " <>
            "#{DateTime.to_iso8601(started_at)} is still running and outlived the channel " <>
            "that spawned it. Running two at once is what exhausts the pool (1aed7edf). " <>
            "This copy's rows are behind until that one lands; the next manifest re-syncs."
        )

        socket
    end
  end

  # `:unchanged` means the component projection did not run (no file row
  # changed). Words, not "0 components", which would read as none.
  defp component_count(:unchanged), do: "components unchanged (projection skipped)"
  defp component_count(n) when is_integer(n), do: "#{n} components"

  defp start_reconcile(scope, entries) do
    Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fn ->
      # Marked by the task, so the entry lives exactly as long as the work.
      ReconcileRegistry.mark(scope.active_working_copy_id, length(entries))
      reconcile(scope, entries)
    end)
  end

  # FileSync commits bounded batches; each upsert and its component projection
  # land together so requirement checks can read a consistent batch.
  # `CodeMySpecWeb` may not reference `CodeMySpec.Repo`.
  defp reconcile(scope, entries), do: FileSync.reconcile_and_project(scope, entries)

  defp next_manifest(%{assigns: %{pending_manifest: nil}} = socket) do
    socket
    |> assign(:reconciling, nil)
    |> assign(:reconciling_manifest, nil)
    |> assign(:reconcile_retries, 0)
    |> check_overlay_when_quiet()
  end

  defp next_manifest(%{assigns: %{pending_manifest: entries}} = socket) do
    socket
    |> assign(:reconciling, start_reconcile(socket.assigns.scope, entries))
    |> assign(:reconciling_manifest, entries)
    |> assign(:reconcile_retries, 0)
    |> assign(:pending_manifest, nil)
  end

  # -- Agent presence -----------------------------------------------------------

  # Only this copy's agents. One already tracked is skipped: a second `track`
  # is `:already_tracked`, and the match would crash the channel.
  defp track_agents(socket, ids) do
    {recovered, ids} = Enum.split_with(ids, &MapSet.member?(gave_up_agents(socket), &1))
    socket = Enum.reduce(recovered, socket, &recover(&2, &1))

    {own, foreign} =
      ids
      |> Enum.reject(&MapSet.member?(present_agents(socket), &1))
      |> Enum.split_with(&own_agent?(socket, &1))

    for id <- foreign,
        do: Logger.warning("[AgentPresence] #{id} is not an agent of copy #{copy_id(socket)}")

    present =
      for id <- own, reduce: present_agents(socket) do
        present ->
          {:ok, _ref} =
            Agents.Presence.track(self(), presence_topic(socket), id, %{
              working_copy_id: copy_id(socket),
              since: DateTime.utc_now()
            })

          Logger.info("[AgentPresence] #{id} up on #{copy_id(socket)}")
          MapSet.put(present, id)
      end

    assign(socket, :present_agents, present)
  end

  defp untrack_agents(socket, ids) do
    for id <- ids, reduce: socket do
      socket ->
        :ok = Agents.Presence.untrack(self(), presence_topic(socket), id)

        socket
        |> assign(:present_agents, MapSet.delete(present_agents(socket), id))
        |> assign(:gave_up_agents, MapSet.delete(gave_up_agents(socket), id))
    end
  end

  # Its Keeper gave up on a crash loop: kept, marked, so the agent reads as
  # stuck rather than starting until main restarts it. Any other down is gone.
  defp ended(socket, id, "gave_up: " <> reason), do: mark_gave_up(socket, id, reason, nil)
  defp ended(socket, id, _reason), do: untrack_agents(socket, [id])

  # Kept tracked, marked as given up on — `Agents.Presence.gave_up/2` reads it,
  # and nothing counts it as running.
  defp mark_gave_up(socket, id, reason, at) do
    meta = %{
      working_copy_id: copy_id(socket),
      state: :gave_up,
      reason: reason,
      at: parse_at(at)
    }

    cond do
      tracked?(socket, id) ->
        {:ok, _} = Agents.Presence.update(self(), presence_topic(socket), id, meta)

      own_agent?(socket, id) ->
        {:ok, _} = Agents.Presence.track(self(), presence_topic(socket), id, meta)

      true ->
        :ok
    end

    Logger.info("[AgentPresence] #{id} given up on, on #{copy_id(socket)}: #{reason}")

    socket
    |> assign(:present_agents, MapSet.delete(present_agents(socket), id))
    |> assign(:gave_up_agents, MapSet.put(gave_up_agents(socket), id))
  end

  # Back up after being given up on — main restarted it: running again.
  defp recover(socket, id) do
    {:ok, _ref} =
      Agents.Presence.update(self(), presence_topic(socket), id, %{
        working_copy_id: copy_id(socket),
        since: DateTime.utc_now()
      })

    Logger.info("[AgentPresence] #{id} up on #{copy_id(socket)}, after being given up on")

    socket
    |> assign(:gave_up_agents, MapSet.delete(gave_up_agents(socket), id))
    |> assign(:present_agents, MapSet.put(present_agents(socket), id))
  end

  defp tracked?(socket, id),
    do: MapSet.member?(present_agents(socket), id) or MapSet.member?(gave_up_agents(socket), id)

  defp parse_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _ -> DateTime.utc_now()
    end
  end

  defp parse_at(_at), do: DateTime.utc_now()

  defp own_agent?(socket, id) do
    match?(
      {:ok, %{working_copy_id: copy}} when copy == socket.assigns.scope.active_working_copy_id,
      Agents.fetch_agent(socket.assigns.scope, id)
    )
  end

  defp present_agents(socket), do: Map.get(socket.assigns, :present_agents, MapSet.new())
  defp gave_up_agents(socket), do: Map.get(socket.assigns, :gave_up_agents, MapSet.new())
  defp presence_topic(socket), do: Agents.presence_topic(socket.assigns.scope.active_project_id)
  defp copy_id(socket), do: socket.assigns.scope.active_working_copy_id

  @impl true
  # A server drain leaves remote runs open for the returning harness. Other
  # disconnects close them as orphans; a rejoin can reclaim live runs.
  def terminate(reason, socket) do
    shutdown_reconcile(socket)

    case socket.assigns[:scope] do
      %Scope{active_project_id: id} when not is_nil(id) ->
        log_disconnect(reason, socket)

        unless reason == {:shutdown, :draining} do
          Analysis.fail_in_flight(socket.assigns.scope, failure_reason(reason))
        end

        mark_device_down_if_last_copy(socket)

      _ ->
        :ok
    end

    :ok
  end

  # A device is up while any of its working copies holds a channel
  # (`CodeMySpecWeb.DeviceLive.Index.reachable?/1` reads the same registry for
  # the same claim). This copy's own channel is the one actually closing, so
  # it is excluded from "any other copy still connected" rather than trusted
  # to have already left the registry -- `terminate/2` runs before this
  # process's own registry entry is torn down by its exit.
  defp mark_device_down_if_last_copy(socket) do
    with %Scope{active_working_copy_id: working_copy_id} when is_binary(working_copy_id) <-
           socket.assigns.scope,
         {:ok, %{device_id: device_id}} when is_binary(device_id) <-
           WorkingCopies.fetch(working_copy_id) do
      unless other_copy_connected?(device_id, working_copy_id) do
        Devices.mark_down(device_id)
      end
    end

    :ok
  end

  defp other_copy_connected?(device_id, excluded_copy_id) do
    [device_id]
    |> WorkingCopies.ids_by_device()
    |> Map.get(device_id, [])
    |> Enum.reject(&(&1 == excluded_copy_id))
    |> Enum.any?(&match?({:ok, _pid, _instance}, HarnessRegistry.executor_holder(&1)))
  end

  # The reconcile dies with the channel that started it. `async_nolink` does not
  # link it, and an orphan still holding a connection while the rejoin starts
  # another stacks reconciles until the pool is exhausted. Killing it loses
  # nothing: the rejoin re-sends the whole manifest, and reconciles are
  # transactional.
  # See knowledge/harness/channel, "Manifests".
  defp shutdown_reconcile(%{assigns: %{reconciling: %Task{} = task}} = socket) do
    Task.shutdown(task, :brutal_kill)

    # Info: this is the healthy path. The unhealthy one is the skip in
    # `maybe_start_reconcile/2`, which warns.
    Logger.info(
      "[HarnessProject] killed the in-flight reconcile for #{closing_copy(socket)} — its " <>
        "channel is closing and the rejoin re-sends the whole manifest anyway. Left running, " <>
        "it would still hold a connection when the next join starts another (1aed7edf)."
    )

    :ok
  end

  defp shutdown_reconcile(_socket), do: :ok

  # Not `harness_label/1`, which takes a join payload.
  defp closing_copy(%{assigns: %{scope: %Scope{active_working_copy_id: id}}}) when is_binary(id),
    do: "harness #{id}"

  defp closing_copy(socket), do: socket.topic

  defp failure_reason(_reason), do: :harness_disconnected

  # A server drain leaves remote runs for recovery when the harness rejoins.
  defp log_disconnect({:shutdown, :draining}, socket) do
    Logger.info(
      "[HarnessProject] server draining channel topic=#{socket.topic}; remote runs await harness recovery"
    )
  end

  # The harness leaving on purpose is worth a line, but not an alarm.
  defp log_disconnect(reason, socket)
       when reason in [
              :normal,
              :shutdown,
              {:shutdown, :left},
              {:shutdown, :closed},
              {:shutdown, :peer_closed}
            ] do
    Logger.info("[HarnessProject] channel closed (#{inspect(reason)}) topic=#{socket.topic}")
  end

  defp log_disconnect(reason, socket) do
    Logger.error(
      "[HarnessProject] channel DIED topic=#{socket.topic}#{instance_tag(socket)}" <>
        " reason=#{death_reason(reason)}" <>
        " — every in-flight run for this working copy is about to be failed as" <>
        " :harness_disconnected. The analyzers keep running on the harness and" <>
        " their results will be refused as unknown_run. Fix the crash, not the sweep." <>
        instance_hint(socket)
    )
  end

  # Names the harness process behind this channel; the registry entry lasts
  # through `terminate/2`. Tells a harness crash from a stale registration.
  defp instance_tag(socket) do
    case working_copy_instance(socket) do
      nil -> ""
      instance -> " instance=#{instance}"
    end
  end

  # One harness process serves every copy it holds, so a crash drops all of
  # them at once. Named rather than counted: a live count races the same crash.
  defp instance_hint(socket) do
    case working_copy_instance(socket) do
      nil ->
        ""

      instance ->
        " This harness process (instance=#{instance}) serves every working copy it" <>
          " holds, so every other project on it dropped at the same moment — grep" <>
          " instance=#{instance} across web.log to see them, rather than reading" <>
          " this one channel as the whole incident."
    end
  end

  defp working_copy_instance(%{assigns: %{scope: %Scope{active_working_copy_id: id}}})
       when is_binary(id) do
    case HarnessRegistry.executor_holder(id) do
      {:ok, _pid, instance} -> instance
      :error -> nil
    end
  end

  defp working_copy_instance(_socket), do: nil

  # The reason, legibly and untruncated. A crash is `{exception, stacktrace}`,
  # formatted as a banner plus five frames; `is_exception/1` decides that up
  # front rather than a rescue around formatting.
  defp death_reason({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace) do
    Exception.format_banner(:error, exception) <>
      "\n" <> Exception.format_stacktrace(Enum.take(stacktrace, 5))
  end

  defp death_reason(reason), do: inspect(reason, limit: :infinity, printable_limit: 2048)

  # `port` is the harness's own — the analysis curl that `pre-tool-use` rewrites
  # points at `http://localhost:<port>/api/analysis/run`, which only means
  # anything on the machine running the agent. The server cannot know it and
  # must not guess it, so a rewrite without one is refused rather than pointed
  # somewhere plausible.
  defp decide_hook("pre-tool-use", _scope, _payload, nil), do: {:error, "port_required"}

  # `:harness` because that is what answers on this port: `cms_harness`, whose
  # routes are addressed `/api/harnesses/<id>/...`. Not inferred from `cwd`,
  # which every proxied copy carries.
  defp decide_hook("pre-tool-use", scope, payload, port),
    do: {200, PreToolUse.decide(scope, payload, port, :harness)}

  defp decide_hook("stop", scope, payload, _port), do: {200, Stop.decide(scope, payload)}

  # A terminal session's turn opening and its session ending (story 1127): the
  # harness on its machine reads these for the agent's state; the server has
  # nothing to decide.
  defp decide_hook("user-prompt-submit", _scope, _payload, _port), do: {200, %{}}
  defp decide_hook("session-end", _scope, _payload, _port), do: {200, %{}}

  defp decide_hook("session-start", scope, payload, _port),
    do: SessionStart.handle(scope, payload)

  defp decide_hook("post-tool-use", scope, payload, _port),
    do: PostToolUse.handle(scope, payload)

  # No sub-agent roster any more (issue 26b78dca). An older plugin still posts
  # these, so they answer "nothing to say" instead of erroring.
  defp decide_hook("subagent-" <> _event, _scope, _payload, _port), do: {200, %{}}

  defp decide_hook("notification", scope, payload, _port),
    do: NotificationHook.handle(scope, payload)

  defp decide_hook(hook, _scope, _payload, _port), do: {:error, "unknown_hook: #{hook}"}

  # The whole manifest is validated before any of it is written; a partial
  # apply would leave the project half-described.
  defp deserialize_observations(observations) do
    entries = Enum.map(observations, &deserialize_observation/1)

    case Enum.flat_map(entries, &problems/1) |> Enum.uniq() |> Enum.take(20) do
      [] -> {:ok, Enum.map(entries, &Map.delete(&1, :raw_role))}
      problems -> {:error, problems}
    end
  end

  defp problems(%{role: nil, raw_role: raw}), do: ["unknown role: #{inspect(raw)}"]
  defp problems(%{mtime: nil, path: path}), do: ["unparseable mtime on #{path}"]

  # Parseable is not storable: the `:utc_datetime_usec` column raises inside the
  # channel on non-microsecond precision, which the harness sees as a dropped
  # connection and retries forever. Refused, not adjusted, so `stale_paths/2`
  # never compares a value the working copy did not report.
  defp problems(%{mtime: %DateTime{microsecond: {_value, precision}}, path: path})
       when precision != 6 do
    [
      "mtime on #{path} has #{precision}-digit sub-second precision; " <>
        "microsecond precision (6 digits, e.g. 2026-08-12T00:00:00.000000Z) is required"
    ]
  end

  defp problems(_entry), do: []

  # Keys are mapped one at a time and roles matched against the schema's own
  # enum: nothing here calls `String.to_atom` on wire data.
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

  # mtime decides which files are stale; validated, not defaulted.
  defp parse_mtime(%DateTime{} = mtime), do: mtime

  defp parse_mtime(mtime) when is_binary(mtime) do
    case DateTime.from_iso8601(mtime) do
      {:ok, parsed, _offset} -> parsed
      {:error, _} -> nil
    end
  end

  defp parse_mtime(_), do: nil

  # Nothing here may be a struct: `story_ids` crosses as a list, and a
  # component as the fields the harness scanner reads for ownership and
  # proposal validation.
  defp serialize_read_model(%Scanner.ReadModel{} = read_model) do
    %{
      "component_by_module" => read_model.component_by_module,
      "component_by_id" => Map.new(read_model.component_by_id, &serialize_component/1),
      "story_ids" => MapSet.to_list(read_model.story_ids),
      "story_ids_by_number" => read_model.story_ids_by_number,
      "story_by_spec_path" => read_model.story_by_spec_path,
      "strict" => read_model.strict?,
      "overlay_records" => read_model.overlay_records
    }
  end

  defp fingerprint(payload),
    do: payload |> :erlang.term_to_binary() |> :erlang.md5() |> Base.encode16(case: :lower)

  # Told of read-model changes once the harness reports overlays: an older one
  # does not, and would log a push it does not know.
  defp follow_read_model(%{assigns: %{following_read_model: true}} = socket), do: socket

  defp follow_read_model(socket) do
    :ok = GraphInputs.subscribe_read_model(socket.assigns.scope.active_project_id)
    assign(socket, :following_read_model, true)
  end

  # Compared only with no manifest reconciling or queued, so the rows have
  # caught up with the scan the overlay came from.
  defp check_overlay_when_quiet(
         %{assigns: %{overlay_unchecked: true, reconciling: nil, pending_manifest: nil}} = socket
       ) do
    scope = socket.assigns.scope

    if Application.get_env(:code_my_spec, :analysis_mode) == :inline do
      CopyOverlay.check(scope)
    else
      {:ok, _pid} =
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn -> CopyOverlay.check(scope) end)
    end

    assign(socket, :overlay_unchecked, false)
  end

  defp check_overlay_when_quiet(socket), do: socket

  defp serialize_component({id, component}) do
    {id,
     %{"module_name" => Map.get(component, :module_name), "type" => Map.get(component, :type)}}
  end

  # A harness may only hold a project its credential reaches: a deploy key
  # names exactly one project, and a user reaches the projects in accounts they
  # belong to. Never the user's UI-selected project.
  defp authorize(socket, project_id) do
    case {socket.assigns[:deploy_key_project_id], socket.assigns[:device_id]} do
      {nil, nil} ->
        authorize_member(socket.assigns[:scope], project_id)

      {nil, device_id} ->
        authorize_dev_box(device_id, project_id)

      {key_project_id, _} ->
        authorize_deploy_key(socket.assigns[:scope], key_project_id, project_id)
    end
  end

  # A dev box (story 1131) reaches the projects of the account it belongs to and
  # no others. The socket itself carries no user; the project's account owner
  # acts for it here, as for a deploy key, and only on this channel. A box
  # revoked since the socket connected is refused.
  defp authorize_dev_box(device_id, project_id) do
    with %{account_id: account_id} <- Devices.active_dev_box(device_id),
         %Project{account_id: ^account_id} <- Projects.get_project_by_id(project_id),
         %{} = owner <- Accounts.get_account_owner(account_id) do
      pin_to_project(CodeMySpec.UserPreferences.scope_for(owner), project_id)
    else
      _ -> {:error, :unauthorized}
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
  # everything downstream acts on the project the harness asked for.
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

  # Carries the working copy on the scope, with an execution environment that
  # reaches its disk over this socket, so every read and write is about *this*
  # copy by default. Addressed by harness id, not `root`; `cwd` is for
  # relativizing paths, never for opening them. Shared with
  # `ProjectScopeOverride`.
  defp put_harness_scope(scope, harness), do: WorkingCopies.put_scope(scope, harness)

  # One harness serves a working copy at a time, and the refusal names the
  # holder's instance and the checkout's root. Only a *different* OS process
  # is refused; the same one coming back takes its own registration (see
  # `Analysis.register_executor/2`).
  defp take_working_copy(harness, payload) do
    case HarnessRegistry.register_executor(harness.id, payload["instance"], payload["root"]) do
      :ok ->
        # Main's read/write/edit/bash in this copy (`CodeMySpec.CopyTools`).
        if payload["copy_tools"] == true do
          HarnessRegistry.register_verb(harness.id, "copy_tools")
        end

        register_app_verbs(harness, payload)
        register_served_models(harness, payload)

      {:error, {:already_registered, pid}} ->
        Logger.warning(
          "[HarnessProject] refused a second harness on working copy #{harness.root || harness.id} " <>
            "of project #{harness.project_id} (joining instance #{inspect(payload["instance"])}, " <>
            "held by #{inspect(pid)})"
        )

        {:error, working_copy_in_use(harness, pid)}

      # One process, one id, two different checkouts: identities collapsed
      # upstream. Refused naming both roots, never evicted — eviction makes the
      # two copies kill each other's channel in a loop.
      {:error, {:id_collision, _pid, held_root}} ->
        Logger.error(
          "[HarnessProject] refused a join for #{inspect(payload["root"])}: harness " <>
            "#{harness.id} is already held by the same process serving " <>
            "#{inspect(held_root)}. Two working copies are presenting one identity."
        )

        {:error, id_collision(harness, payload["root"], held_root)}
    end
  end

  # App verbs newer than the channel contract, declared at join. A harness
  # that predates `reload_app` declares nothing and is only ever restarted.
  defp register_app_verbs(harness, %{"app_verbs" => verbs}) when is_list(verbs) do
    for verb <- verbs, is_binary(verb), do: HarnessRegistry.register_verb(harness.id, verb)
    :ok
  end

  defp register_app_verbs(_harness, _payload), do: :ok

  # The models each provider serves this harness's logins, where it could read
  # them; "unknown" (or nothing) leaves a provider unverified.
  defp register_served_models(harness, %{"served_models" => models}) when is_map(models) do
    known = for {provider, [_ | _] = ids} <- models, into: %{}, do: {provider, ids}
    HarnessRegistry.register_served_models(harness.id, known)
  end

  defp register_served_models(_harness, _payload), do: :ok

  defp id_collision(harness, joining_root, held_root) do
    %{
      reason: "harness_id_collision",
      working_copy_id: harness.id,
      root: joining_root,
      held_by_root: held_root,
      detail:
        "Two working copies are presenting harness #{harness.id}: this join is for " <>
          "#{inspect(joining_root)} and the id is already held for #{inspect(held_root)}. " <>
          "A harness id names one checkout, so one `.cms_harness.json` was most likely " <>
          "copied from the other checkout. In the checkout that should have its own id, " <>
          "delete `.cms_harness.json` and run `mix cms.harness.onboard` (onboarding " <>
          "keeps an id the file already holds)."
    }
  end

  defp working_copy_in_use(harness, pid) do
    holder =
      case HarnessRegistry.executor_holder(harness.id) do
        {:ok, _pid, instance} when is_binary(instance) -> instance
        _ -> inspect(pid)
      end

    %{
      reason: "working_copy_in_use",
      working_copy_id: harness.id,
      root: harness.root,
      held_by: holder,
      detail:
        "The working copy at #{harness.root || harness.id} is already being served by " <>
          "#{holder}. Two harnesses on one checkout share a single `_build`, and two " <>
          "`mix test` runs in it report failures that are not in the code. Stop that " <>
          "process, or serve a different checkout."
    }
  end

  # Which machine this checkout is on, **looked up, never created**: one
  # install serves many checkouts, and devices are created once by
  # `CmsHarness.Device.announce/0`. An unknown id attaches nothing.
  defp resolve_device(scope, %{"device" => %{"id" => id}}) when is_binary(id) do
    Devices.get_harness_device(scope, id)
  end

  defp resolve_device(_scope, _payload), do: nil

  # The keys that open this project's local `envs/dev.enc.env` and
  # `envs/test.enc.env`, for the harness's machine keyring. Deploy environments'
  # keys stay on the server.
  @local_sops_environments ~w(dev test)

  defp local_age_keys(scope) do
    for env <- @local_sops_environments,
        {:ok, key} <- [ProjectSecrets.fetch_value(scope, "age_private_key_#{env}")],
        is_binary(key) and key != "",
        uniq: true,
        do: key
  end

  # Said by the harness at join, so a refusal can name the checkout.
  defp harness_label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp harness_label(_payload), do: "a harness that did not say where it is"

  # A join without a root is not an error: the root is recorded about the
  # harness, never used to find it.
  #
  # Also corrects agents' `working_copy` snapshots, which `LaunchRequest.for/2`
  # sends verbatim on a restore.
  defp report_root(scope, harness, root) when is_binary(root) and root != "" do
    with {:ok, harness} <- WorkingCopies.report_root(harness, root) do
      {:ok, _count} = Agents.sync_working_copy_root(scope, harness.id, harness.root)
      {:ok, harness}
    end
  end

  defp report_root(_scope, harness, _), do: {:ok, harness}

  # The server's copy of the checkout's configured preview address, kept like
  # `root`. A refusal (not the main copy) is not a join failure; the address is
  # simply not recorded.
  defp report_preview_url(%{main: true} = harness, url) when is_binary(url) and url != "" do
    WorkingCopies.record_preview_url(harness, url)
    {:ok, harness}
  end

  defp report_preview_url(harness, _), do: {:ok, harness}

  # A turn's own tokens, kept whether or not the turn can be placed in a
  # conversation. The agent is found by `agent_role` plus this socket's copy;
  # the wire never names one.
  defp record_turn_tokens(scope, payload) do
    role = payload["agent_role"] || "main"

    case Agents.find_by_working_copy_and_role(scope, scope.active_working_copy_id, role) do
      nil ->
        :ok

      agent ->
        TokenUsage.record(
          scope,
          agent.id,
          agent.story_id,
          agent.provider,
          payload["response"] || %{}
        )

        mirror_failed_tool_results(scope, agent, payload["request"] || %{})
    end
  end

  # An in-app agent's turn spend, for the performance page. Only this copy's
  # agents; a turn that never reached a provider carries no usage.
  defp record_turn_usage(scope, agent_id, %{"kind" => "turn_ended", "usage" => %{} = usage}) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, %{working_copy_id: copy_id} = agent} when copy_id == scope.active_working_copy_id ->
        TokenUsage.record(scope, agent.id, agent.story_id, agent.provider, %{
          "model" => agent.model,
          "usage" => usage
        })

      _ ->
        :ok
    end
  end

  # A terminal session's turn, totalled from its transcript at the turn's end
  # (story 1124); the model is the transcript's own.
  defp record_turn_usage(scope, agent_id, %{"kind" => "turn_usage", "usage" => %{} = usage}) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, %{working_copy_id: copy_id} = agent} when copy_id == scope.active_working_copy_id ->
        TokenUsage.record(scope, agent.id, agent.story_id, agent.provider, %{
          "model" => usage["model"] || agent.model,
          "usage" => usage
        })

      _ ->
        :ok
    end
  end

  defp record_turn_usage(_scope, _agent_id, _event), do: :ok

  # Tool failures on this turn are mirrored onto the agent's conversation
  # (the session conversation has no agent), failures only, so
  # `AgentPerformance.ToolFailures` can read this lane too.
  defp mirror_failed_tool_results(scope, agent, request) do
    request
    |> ConversationRecorder.tool_results()
    |> Enum.filter(& &1.failed?)
    |> Enum.each(fn result ->
      with {:ok, conversation} <-
             Conversations.find_or_create_agent_conversation(
               scope.active_account_id,
               scope.active_project_id,
               agent.id
             ) do
        Conversations.add_tool_result(conversation, result.call_id, result.name, result.text,
          failed?: true,
          agent_role: to_string(agent.role)
        )
      end
    end)
  end

  # Which conversation a recorded turn belongs to: the harness's session id
  # when it sends one, else the session running in this copy, and "sprite" as
  # the last resort.
  defp session_external_id(scope, payload) do
    case payload["session_id"] do
      id when is_binary(id) and id != "" -> id
      _ -> Agents.terminal_session_id_for(scope.active_working_copy_id) || "sprite"
    end
  end

  defp draft_conversation(socket, agent_id) do
    cached = Map.get(socket.assigns, :draft_conversations, %{})

    case cached do
      %{^agent_id => conversation_id} ->
        {:ok, conversation_id, socket}

      _ ->
        case Agents.conversation_id(socket.assigns.scope, agent_id) do
          {:ok, conversation_id} ->
            {:ok, conversation_id,
             assign(socket, :draft_conversations, Map.put(cached, agent_id, conversation_id))}

          _ ->
            :error
        end
    end
  end

  # The draft has been said, or never will be. Only an agent this socket has
  # drafted for can have one to clear.
  @settling_kinds ~w(message turn_ended turn_failed turn_cut_off)

  defp settle_draft(socket, agent_id, %{"kind" => kind}) when kind in @settling_kinds do
    case socket.assigns do
      %{draft_conversations: %{^agent_id => conversation_id}} -> Drafts.clear(conversation_id)
      _ -> :ok
    end
  end

  defp settle_draft(_socket, _agent_id, _event), do: :ok

  # A live code reload can land this module's recompile before PromotionQueue's,
  # or the reverse -- either way there is a window where the function it calls
  # does not exist yet in the running code. 68d37919: that raised straight out
  # of `handle_in/3` and crashed this whole channel process -- one per project,
  # carrying every working copy's events, not just this one's -- which took an
  # unrelated `create_working_copy` down with it, still waiting on this same
  # process to reply, and left a worktree on disk with no record of it.
  # Releasing a stale certification is housekeeping prompted by a routine
  # commit report, not something that report should ever be refused over, so a
  # miss here is logged and dropped rather than left to crash the channel.
  defp release_moved_certifications(scope, working_copy_id, sha) do
    PromotionQueue.release_moved_certifications(scope, working_copy_id, sha)
  rescue
    UndefinedFunctionError ->
      Logger.warning(
        "[HarnessProject] PromotionQueue.release_moved_certifications/3 was undefined for " <>
          "#{working_copy_id} at #{sha} -- likely a code reload race. Certifications stay " <>
          "as they are until the next head_commit report."
      )

      []
  end
end
