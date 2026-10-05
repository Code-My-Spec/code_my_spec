defmodule CodeMySpecWeb.HarnessProjectChannel do
  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
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
  alias CodeMySpec.AgentPerformance.TokenUsage
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.LaunchRequest
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.AgentTasks.SkillRouter
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
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
  alias CodeMySpec.Hooks.SubagentStart
  alias CodeMySpec.Hooks.SubagentStop
  alias CodeMySpec.McpServers.Promotion.Responses, as: PromotionResponses
  alias CodeMySpec.McpServers.ToolRegistry
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
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
             # The device and root are what let a rejoining checkout be
             # recognised rather than minted again. Both were already resolved
             # here and neither was passed, so a join that could not present an
             # id became a new working copy every time.
             label: label,
             device: device,
             root: payload["root"]
           ),
         {:ok, harness} <- report_root(scope, harness, payload["root"]),
         {:ok, harness} <- report_preview_url(harness, payload["preview_url"]),
         {:ok, harness} <- WorkingCopies.attach_device(harness, device),
         :ok <-
           record_machine_tools(harness, payload["machine_tools"], payload["machine_tool_docs"]),
         :ok <- record_browser_status(harness, payload["browser_status"]),
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

      # Then settle what the departure killed: reopen what this harness still
      # holds, run the requested rest again. Registered above, so a re-dispatch
      # lands in this channel's mailbox and is pushed once the join returns
      # (cc578c21).
      Analysis.resume_orphaned(scope, claimed_runs(payload))
      PromotionQueue.copy_joined(scope, harness)

      # The id goes back in the join reply whether it was just minted or
      # recognised. A harness that already holds one gets the same value and
      # writes nothing; one joining a checkout for the first time writes it
      # down, so its next restart is the same harness rather than a second.
      # Every read and write this channel makes is about *this* working copy.
      # Carrying the harness on the scope is what makes that true by default,
      # rather than something each call site has to remember — and forgetting it
      # returns another checkout's files with no error to notice.
      {:ok,
       %{
         working_copy_id: harness.id,
         harness_id: harness.id,
         device_id: device && device.id,
         sops_age_keys: local_age_keys(scope),
         # `harness` here is exactly the "fresh at join" value `put_tunnel/2`
         # warns its own `socket.assigns.harness` is not guaranteed to stay —
         # so this is the one place it is safe to read `main` straight off it
         # rather than re-fetching. See `tunnel_for/1`, shared with that path.
         tunnel: tunnel_for(harness)
       },
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

      # A join that names no machine. Every harness on a current build announces
      # itself at boot and sends the id it was issued, so this is a client old
      # enough to predate devices — and a checkout is identified by
      # {project, device, root}, which cannot be answered without one. Minting
      # anyway is what left this project with rows nothing could attribute to a
      # machine, and a copy that has been seen must now name one:
      # `seen_copies_are_on_a_machine` is `device_id IS NOT NULL OR last_seen_at
      # IS NULL`, so an unseen row may still have none.
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

  # What else this machine can do, by name — a browser, today. Kept against the
  # working copy because that is what an agent is started on, and an agent's
  # tool list is computed at start from what its machine said.
  #
  # Absent from an older harness, which is not the same as an empty list: one
  # says "this machine reported nothing", the other "this machine has no
  # browser". Both end with an agent that has no browser tools, and only the
  # second is a thing the operator can act on.
  defp record_machine_tools(_harness, nil, _docs), do: :ok

  defp record_machine_tools(harness, names, docs) when is_list(names) do
    WorkingCopies.record_machine_tools(harness, names, docs)
  end

  defp record_machine_tools(_harness, _other, _docs), do: :ok

  # Why the list was what it was. Absent from an older harness, which is the
  # `nil` the column already means — not an error, and not a reason to refuse a
  # join over.
  defp record_browser_status(harness, %{"status" => status} = payload)
       when is_binary(status) do
    WorkingCopies.record_browser_status(harness, status, payload["error"])
  end

  defp record_browser_status(_harness, _other), do: :ok

  # The channel contract this server speaks. Kept in step with
  # `CmsHarness.Project.ChannelClient`'s copy — the two *are* the contract, so
  # they are the two places that have to agree. Bump on a change to the join
  # payload, the `handle_in` set, or the shapes those carry.
  @contract_version 2

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
  # governs `active_runs` and `working_copy_id` in the same payload. It is logged
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

    record_turn_tokens(scope, payload)

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
    WorkingCopies.mark_alive(socket.assigns.scope.active_working_copy_id)

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

  # Corrects `project.module_name` from the one place it is never ambiguous —
  # the checkout's own `mix.exs`, read on the machine that can actually reach
  # it. Server-side deploy-readiness checks have no real way to read a
  # harness-only project's files at all (`Environments.mix_exs_app_name/1`
  # resolves to `nil` there — see `CodeMySpec.Provisioning.Steps.app_path/1`),
  # so this is what keeps that fallback correct instead of stuck on whatever
  # onboarding did or did not ask for.
  #
  # Sent on every sync, so a project onboarded before this existed — or with
  # a stale value from before a rename — self-heals on the harness's own
  # schedule rather than needing a repeat onboarding step.
  #
  # From the **main** copy only. "The one place it is never ambiguous" is true
  # of one checkout and false of a project, which has several: every copy sends
  # this on every sync, so without the gate the last one to sync wins. A QA
  # sandbox holding a different application (`:qa_sandbox`) sat on this project
  # for an afternoon and renamed it `QaSandbox`, against 1,091 components all
  # called `CodeMySpec.*` — and it kept renaming it after being un-designated,
  # because being connected was enough. The architecture task then instructed
  # its agent to create components in a namespace that does not exist.
  #
  # The main copy is the project's own answer to "which checkout defines this",
  # which is story 963's whole subject, so the gate is that one rather than a
  # new rule.
  def handle_in("module_name", %{"module_name" => name}, socket)
      when is_binary(name) and name != "" do
    project = socket.assigns.scope.active_project

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

  # A blank or missing name is not the harness telling us anything wrong —
  # `Environments.mix_exs_app_name/1` answers `nil` for plenty of legitimate
  # reasons (checkout mid-write, an unusual `mix.exs`) — so it is accepted
  # and ignored rather than refused as an unrecognised event.
  def handle_in("module_name", _payload, socket), do: {:reply, :ok, socket}

  # Same self-healing shape as `module_name`, for a check `Files` sync cannot
  # answer (it records existence, never a body) and the server cannot read
  # directly for a harness-only project. `Project.changeset/3`'s
  # `validate_inclusion` is what keeps a malformed status from ever landing.
  def handle_in("health_route_status", %{"status" => status}, socket)
      when status in ~w(ok no_health_route health_route_piped) do
    project = socket.assigns.scope.active_project

    if project && project.health_route_status != status do
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
    else
      {:reply, :ok, socket}
    end
  end

  def handle_in("health_route_status", _payload, socket), do: {:reply, :ok, socket}

  # Same self-healing shape as `module_name`/`health_route_status`, for
  # `Steps.image_tag/2`'s `git rev-parse HEAD` — the server has no working
  # directory to run `git` in for a harness-only project.
  # `Project.changeset/3`'s `validate_format` keeps a malformed SHA from ever
  # landing.
  # Whether the application is answering, from the machine that can reach it.
  def handle_in("preview_status", %{"status" => status}, socket)
      when status in ~w(serving erroring down) do
    case WorkingCopies.fetch(socket.assigns.scope.active_working_copy_id) do
      {:ok, copy} ->
        WorkingCopies.record_preview_status(copy, status)
        {:reply, :ok, socket}

      _ ->
        {:reply, :ok, socket}
    end
  end

  # Unprompted, from a first start's background watch — `AppInstance` keeps
  # polling after its own short inline reply window, and pushes this the
  # moment `starting` resolves to `serving` or `erroring`, rather than
  # waiting for the next `ensure_app_running`/`restart_app` call to ask.
  # Same three-plus-one states `record_app_status/2` accepts.
  def handle_in("app_status", %{"status" => status} = payload, socket)
      when status in ~w(serving erroring down starting) do
    case WorkingCopies.fetch(socket.assigns.scope.active_working_copy_id) do
      {:ok, copy} ->
        WorkingCopies.record_app_status(copy, %{
          status: status,
          url: payload["url"],
          commit: payload["commit"]
        })

        {:reply, :ok, socket}

      _ ->
        {:reply, :ok, socket}
    end
  end

  # The 60-second report a harness from before agent presence still sends.
  # Liveness is Presence now (`agent_up` / `agent_down` / `agents_present`),
  # so it says nothing this channel needs; answered rather than unmatched, so
  # such a harness keeps its channel through a deploy's handover.
  def handle_in("agents_running", _payload, socket), do: {:reply, :ok, socket}

  # Which agents are alive (`.code_my_spec/plans/agent-liveness-from-presence.md`).
  # The channel process tracks an agent in `Agents.Presence` while the harness
  # says its process is up, and Presence drops every key this channel tracked
  # the moment the channel dies — a harness exit or a dropped socket needs no
  # report.
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

    {:reply, :ok, untrack_agents(socket, [id])}
  end

  # The harness's whole set, on join: track what is new, untrack what is gone,
  # and sweep the copy for work — a harness that has just (re)connected is the
  # case with something to catch.
  def handle_in("agents_present", %{"agent_ids" => ids}, socket) when is_list(ids) do
    present = present_agents(socket)
    socket = track_agents(socket, ids)
    gone = MapSet.to_list(MapSet.difference(present, MapSet.new(ids)))

    {:reply, :ok, socket |> untrack_agents(gone) |> consider_once(:present)}
  end

  # What the box is carrying, from the box.
  #
  # Story 1057, criterion 3324. A harness already reports facts it observes
  # about itself — its preview, its tools, its head commit — and never what it
  # runs on, so a saturated machine presented as several individually slow
  # agents. That reading's remedy is restarts, which add to what the machine is
  # carrying: the one fault here whose wrong diagnosis deepens it.
  #
  # Recorded against the device, not the working copy. The box is what is
  # saturated, two checkouts on one machine share its processors, and a figure
  # per copy would report the same saturation twice and let the two disagree.
  def handle_in("machine_load", load, socket) when is_map(load) do
    socket.assigns.scope.active_working_copy_id
    |> WorkingCopies.device_of()
    |> Devices.record_load(load)

    {:reply, :ok, socket}
  end

  # Accepted and dropped, for one release.
  #
  # `git_state` used to store `ahead`/`behind`/`dirty` on the working copy and
  # announce a graph change for them. Nothing decided on the stored values and
  # the announcement cost a pass per checkout per sync, so both are gone — a
  # harness has stopped sending this.
  #
  # Older harnesses have not. Falling through to the catch-all below would
  # answer `unknown_event`, which is the version-skew signal and would be a lie
  # here: the server understands the event perfectly well and has decided it has
  # nothing to do. Delete this clause once no harness sends it.
  def handle_in("git_state", _payload, socket), do: {:reply, :ok, socket}

  def handle_in("head_commit", %{"sha" => sha}, socket)
      when is_binary(sha) and byte_size(sha) == 40 do
    project = socket.assigns.scope.active_project

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

    {:noreply,
     reply_async(socket, ref, {"decision", hook}, fn ->
       decision_reply(hook, scope, payload, port)
     end)}
  end

  # A skill invocation for the working copy this channel serves — `4396345b`.
  # `CmsHarness.Web` has no reachable `/api/skills/start`: it never had a
  # command runner, only this channel, so a light-harness session's skill.md
  # curl had nowhere to land. Same shape as `hook_decision` right above —
  # deferred to a task so a crash in `SkillRouter.resolve/2` (or the session it
  # starts) cannot take the channel down, and answered even on an unknown
  # skill rather than left to time out.
  def handle_in("skill_start", %{"params" => params} = _msg, socket) when is_map(params) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope

    {:noreply, reply_async(socket, ref, "skill_start", fn -> skill_reply(scope, params) end)}
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

    {:noreply,
     reply_async(socket, ref, {"analysis_result", source}, fn ->
       result_reply(scope, source, payload)
     end)}
  end

  # The commit an analyzer started on, and whether the tree was clean, from the
  # machine holding the checkout. Inline: one row update, and it must land
  # before this run's `analysis_result`, which is deferred.
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

    {:noreply,
     reply_async(socket, ref, {"analysis_run", source}, fn ->
       run_for_agent(scope, source, args)
     end)}
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

    reply =
      fn ->
        result = CodeMySpec.Analysis.await_all(scope, timeout: :timer.minutes(20))
        {:ok, %{"state" => to_string(result), "summary" => wait_summary(scope)}}
      end

    {:noreply, reply_async(socket, ref, "analysis_wait", reply)}
  end

  # Promote this working copy, and answer with what happened.
  #
  # The promotion has to run *here*. `Promotion.gate/1` and `gate_target/3`
  # read the database and the harness has none, which is also why the disk half
  # goes back the other way as three named `fs_request` ops rather than as a
  # command — see `Promotion.Runner` and `Environments.Harness.cmd/4`, which
  # refuses on purpose.
  #
  # Replied out of band for the same measured reason `analysis_wait` above is,
  # and one more that is specific to this: `Promotion.promote/1` calls
  # `Runner`, which calls back into *this* channel with `{:fs_request, …}`.
  # Answered inline, that is a `GenServer.call` to self — OTP exits at once
  # with `{:calling_self, …}`, which `Analysis.harness_fs_request/4` has a whole
  # clause explaining because a reconcile already made this mistake once. The
  # task is what keeps the caller and the answerer two processes.
  #
  # No `@contract_version` bump. An older harness never sends this, and a newer
  # harness against an older server gets the `unknown_event` reply, which names
  # the skew — the same additive reasoning `active_runs` on the join payload is
  # built on. Bumping would refuse every deployed harness for an event none of
  # them use.
  def handle_in("promotion_run", payload, socket) do
    ref = socket_ref(socket)
    scope = socket.assigns.scope
    story_number = payload["story_number"]

    {:noreply,
     reply_async(socket, ref, "promotion_run", fn -> promote_for_caller(scope, story_number) end)}
  end

  # The harness's answer to a filesystem request. See `handle_call/3` below.
  # What the machine did about the stop. An unknown ref is dropped rather than
  # crashing the channel: it means the caller already gave up, and taking the
  # socket down over a late answer would disconnect every agent on that copy.
  @impl true
  # Which agents this working copy is supposed to be running.
  #
  # Asked on join, because a harness that has just come up holds nothing and the
  # record is the intent. Answering with the desired state — not with what
  # anybody last observed — is what makes `running` a command rather than a
  # guess, and it is why a stopped agent is simply absent from the answer
  # instead of needing to be suppressed.
  def handle_in("agents_to_restore", _payload, socket) do
    scope = socket.assigns.scope

    # The same request a fresh start sends. This built its own map, and the map
    # it built carried neither the credential nor the conversation — so an agent
    # restored after a harness restart came back with nothing to authenticate
    # with and no memory of anything it had been told.
    # On duty only: an off or retired agent is never brought back (39af5611).
    running =
      scope
      |> Agents.list_on_duty()
      |> Enum.filter(&(&1.working_copy_id == scope.active_working_copy_id))

    # Before hydrating, not after. An agent that was mid-turn is told here what
    # became of that turn, and hydration is what reads the conversation into
    # the launch request — so writing first is what makes the notice part of
    # the history the agent comes back holding, rather than a line it would
    # only find by re-reading the page.
    # Kept for the sweep that follows the re-registration, which is when the
    # agents are back to take the turns this restart discarded (5a977f41).
    interrupted = Agents.interrupted_turns(running)
    :ok = Agents.account_for_interrupted_turns(scope, running)

    tools = ToolRegistry.registry()
    agents = Enum.map(running, &(scope |> LaunchRequest.hydrate(&1) |> LaunchRequest.for(tools)))

    {:reply, {:ok, %{"agents" => agents}},
     assign(
       socket,
       :interrupted_turns,
       Map.merge(socket.assigns[:interrupted_turns] || %{}, interrupted)
     )}
  end

  # One step an agent took, written to its conversation as it arrives.
  #
  # Not buffered until the turn completes. Buffering passes every scenario about
  # watching a turn that succeeds and loses everything on the turns worth
  # watching — an agent going wrong is exactly the turn that does not finish
  # cleanly.
  #
  # Replied to rather than ignored so the machine knows the step landed, but the
  # machine does not wait on it: it casts.
  def handle_in("agent_turn_event", %{"agent_id" => agent_id, "event" => event}, socket) do
    Agents.record_turn_event(socket.assigns.scope, agent_id, event)
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

  def handle_in("agent_message_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_message_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("agent_send_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_send_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("agent_withdraw_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_withdraw_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("agent_stop_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    if from, do: GenServer.reply(from, decode_stop_result(msg))
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("ensure_app_running_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    result = decode_app_result(msg)
    if from, do: GenServer.reply(from, result)
    record_app_result(socket, result)
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("restart_app_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    result = decode_app_result(msg)
    if from, do: GenServer.reply(from, result)
    record_app_result(socket, result)
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("reload_app_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    result = decode_app_result(msg)
    if from, do: GenServer.reply(from, result)
    record_app_result(socket, result)
    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("stop_app_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_agent_stop(socket), ref)
    result = decode_stop_result(msg)
    if from, do: GenServer.reply(from, result)

    if result == :ok,
      do: record_app_result(socket, {:ok, %{status: "down", url: nil, commit: nil}})

    {:reply, :ok, assign(socket, :pending_agent_stop, pending)}
  end

  def handle_in("tool_call_result", %{"ref" => ref} = msg, socket) do
    {from, pending} = Map.pop(pending_machine_tool(socket), ref)
    if from, do: GenServer.reply(from, decode_machine_tool_result(msg))
    {:reply, :ok, assign(socket, :pending_machine_tool, pending)}
  end

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

  # The DB write behind every app verb's reply — never behind the reply
  # itself, so the caller sees "ok" even on the store write's own failure:
  # the far side really did start/stop the app either way, and a `from` still
  # waiting must not be lied to about that over a WorkingCopies write.
  defp record_app_result(socket, {:ok, %{status: _status} = info}) do
    case WorkingCopies.fetch(socket.assigns.scope.active_working_copy_id) do
      {:ok, copy} -> WorkingCopies.record_app_status(copy, info)
      _ -> :ok
    end

    :ok
  end

  defp record_app_result(_socket, {:error, _reason}), do: :ok

  # The one moment we know what is running on this copy, which is the moment to
  # ask whether any of it should be working.
  #
  # `Work.consider_*` is edge-triggered — a graph change, a finished task,
  # continuous being switched on — and a restart is none of those. So a promote
  # parked the whole fleet until the main agent's cadence came round, twenty
  # minutes by default, at exactly the point a restart has just stranded
  # reservations and discarded turns. Measured on the math project 2026-09-22:
  # three promotes, and after each one every role sat idle over work that was
  # ready the whole time.
  #
  # Here rather than at application boot, which is where this was tried first
  # and did not work. The boot task runs while the agent rows still say what the
  # last shutdown left them saying; the harness reconnects and re-registers them
  # a moment later, so the sweep asked an empty board and woke nobody. This
  # message *is* the re-registration, so by the time it returns there is
  # something to ask about.
  #
  # Twice per join at most, keyed by what triggered it: the join's
  # `agents_present` (`:present`) and the copy's first agent coming up after it
  # (`:first_up`) — the first runs before the harness has restored anyone.
  # Admission is guarded but not free — `graph_work?/2` is a graph read per
  # idle agent.
  #
  # In a Task because `Transport.Harness` resolves this copy's holder and calls
  # it, and the holder is this channel: calling from here is `:calling_self`,
  # which kills the channel and cancels every agent's turn on the copy. That is
  # the outage this session started with.
  defp consider_once(socket, trigger) do
    swept = socket.assigns[:swept] || MapSet.new()

    if MapSet.member?(swept, trigger),
      do: socket,
      else: socket |> assign(:swept, MapSet.put(swept, trigger)) |> sweep()
  end

  defp sweep(socket) do
    scope = socket.assigns.scope
    copy_id = scope.active_working_copy_id
    interrupted = socket.assigns[:interrupted_turns] || %{}

    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      # First, so a turn the restart discarded is handed back before anything
      # else is offered in its place (5a977f41).
      Agents.Work.redeliver_interrupted_turns(scope, interrupted)

      Agents.Work.consider_copy(scope, copy_id, :harness_reconnected)

      # And the agents `consider_copy/4` cannot reach: a restart discards the
      # turn but leaves the task held, and admission refuses an agent holding
      # one. That combination is the thing a reconnect is most likely to have
      # just created, and it is the one case this sweep used to walk straight
      # past.
      Agents.Work.resume_held_tasks(scope, copy_id)

      # The retry-time wakes of agents refused until later, which lived in the
      # process a restart took down.
      Agents.RefusalWake.rearm(scope, copy_id)

      # 1b450fc3: every existing caller of `ensure_cadence/1` (`agents.ex`
      # watch_over/2, set_copy_continuous/3, set_agent_continuous/3) fires on a
      # state *transition* — an agent starting, continuous flipping on. None of
      # them fire on a bare reconnect, because nothing transitions: an agent
      # that was already running and already continuous before the crash is
      # still running and still continuous after it, from the server's own
      # row's point of view. The cadence GenServer that watched it lived in the
      # BEAM process that died, and nothing about "the harness came back" looks
      # like a transition to any of the three triggers above. Measured: no
      # `[Cadence]` check-in in web.log for six hours across two projects both
      # configured at 1200s, `:4000` having restarted five times in that
      # window.
      #
      # A reconnect is the shape already established for restart-survival here
      # (`consider_copy/4`, `resume_held_tasks/2` above), so this copies it
      # rather than adding a fourth transition-shaped trigger: idempotent
      # (`DynamicSupervisor.start_child` treats `:already_started` as success),
      # and it re-arms on every harness that comes back regardless of which one
      # crashed. Not a redesign of the trigger — John is weighing replacing or
      # supplementing polling cadence with event-based wakes, and this reaches
      # for the existing one rather than pre-empting that; the liveness
      # property (a restart doesn't leave the watcher dead) is what has to
      # survive, not this particular call site.
      MainAgent.ensure_cadence(scope)
    end)

    socket
  end

  # Unknown copy answers false. A correction we cannot attribute to the main
  # checkout is one we should not apply, and the cost of being wrong here is a
  # project renamed out from under 1,091 components.
  defp main_copy?(socket) do
    case WorkingCopies.fetch(socket.assigns.scope.active_working_copy_id) do
      {:ok, copy} -> copy.main
      _ -> false
    end
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

  # Ending an agent's process group, on the machine that has it.
  #
  # Same shape as `fs_request` and for the same reason: the far side has to do
  # real work — signal, wait out a grace period, escalate — and the answer is
  # the whole point. `Agents.turn_off_agent/3` records `:stopped` only if this comes
  # back `:ok`, so a reply that never arrives must not read as success.
  # Launching an agent, on the machine that will hold the process.
  #
  # The reply carries the process group id and the boot it belongs to, which
  # `Agents.record_started/3` writes together. Until this existed that function
  # had no callers at all: `start_agent/2` minted a config directory and left a
  # row at `:starting` that no machine was ever told about.
  #
  # The request is built here rather than by `Agents.Transport.Harness`: its
  # tool index reads the MCP servers, which `Agents` sits below.
  @impl true
  def handle_call({:start_agent, %Agents.Agent{} = agent}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))
    request = LaunchRequest.for(agent, ToolRegistry.registry())

    push(socket, "start_agent", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  @impl true
  def handle_call({:message_agent, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "message_agent", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  def handle_call({:dispatch_message, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "send_message", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  def handle_call({:request_work_turn, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))
    push(socket, "request_work_turn", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  def handle_call({:withdraw_message, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "withdraw_message", Map.put(request, "ref", ref))

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

  # Make a checkout on this machine's disk.
  #
  # Every other request here names a checkout that exists. This one asks for one
  # to exist, so the address is the machine rather than the copy — see
  # `Analysis.host_holder/1`. The harness makes the worktree beside the
  # repository it already holds and onboards it; the server records what comes
  # back. The caller made one call (criterion 3100).
  def handle_call({:create_working_copy, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "create_working_copy", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  def handle_call({:stop_agent, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "stop_agent", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  # Story 1108: bring this copy's own app up, restart it, or stop it. Same
  # shape as every request above — ref out, reply correlated back on the
  # `_result` push — because the mechanism (find the pid holding the channel,
  # ask it, wait for a correlated reply) is identical to asking the machine to
  # start or stop an agent.
  def handle_call({:ensure_app_running, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(
      socket,
      "ensure_app_running",
      request |> put_main(socket) |> put_tunnel(socket) |> Map.put("ref", ref)
    )

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  def handle_call({:restart_app, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(
      socket,
      "restart_app",
      request |> put_main(socket) |> put_tunnel(socket) |> Map.put("ref", ref)
    )

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  # A promote's default: migrate and hot-reload the running app in place, then
  # the after-promote hook, as a restart does. Pushed only to a harness that
  # declared `reload_app` at join; an older one would never reply.
  def handle_call({:reload_app, request}, from, socket) do
    if HarnessRegistry.supports?(socket.assigns.harness.id, "reload_app") do
      ref = Integer.to_string(System.unique_integer([:positive]))

      push(
        socket,
        "reload_app",
        request |> put_main(socket) |> put_tunnel(socket) |> Map.put("ref", ref)
      )

      {:noreply,
       assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
    else
      {:reply, {:error, :reload_not_supported}, socket}
    end
  end

  def handle_call({:stop_app, request}, from, socket) do
    ref = Integer.to_string(System.unique_integer([:positive]))

    push(socket, "stop_app", Map.put(request, "ref", ref))

    {:noreply,
     assign(socket, :pending_agent_stop, Map.put(pending_agent_stop(socket), ref, from))}
  end

  # Story 1108: main's app is never stopped for idling. The harness has no
  # way to know it is main on its own — only the server designates one — so
  # it is told fresh on every start/restart rather than asked to remember.
  defp put_main(request, socket),
    do: Map.put(request, "main", socket.assigns.harness.main == true)

  # The harness holds the tunnel, not the app it launches (2026-09-29, John:
  # "the harness should hold the tunnel, not the generated app" — an app
  # restart no longer needs to bounce cloudflared with it). Same "told fresh,
  # never remembered" reasoning as `put_main/2`: main-ness can be
  # redesignated, and only the copy confirmed main *right now* may ever be
  # told to run a connector — a stale cached answer here is a stray
  # connector, the exact hazard this project has already shipped a fix for
  # once. Read straight from the row rather than `socket.assigns.harness`,
  # which was only ever guaranteed fresh at join.
  #
  # A sibling sharing another copy's tunnel (criterion 1586) holds the same
  # `preview_tunnel_id`/`secret` on its own row — `stored_credentials/1` alone
  # cannot tell the two apart, which is exactly why the `main: true` guard is
  # here and not there. It must never run a connector of its own; its
  # hostname reaches the shared tunnel through main's, over the ingress rule
  # the server already manages via Cloudflare's API.
  defp put_tunnel(request, socket) do
    case WorkingCopies.fetch(socket.assigns.harness.id) do
      {:ok, copy} ->
        case tunnel_for(copy) do
          nil -> request
          tunnel -> Map.put(request, "tunnel", tunnel)
        end

      _ ->
        request
    end
  end

  # The one place that decides whether a copy holds a tunnel and what its
  # credentials are — shared by `put_tunnel/2` (the long-lived
  # `ensure_app_running`/`restart_app` path) and the join reply below, so the
  # two can never compute a different answer for the same copy. `nil` for
  # anything but the designated main, and for main itself the moment
  # `PreviewTunnel.stored_credentials/1` finds nothing DB-backed for it (this
  # repo's own main today — its dev tunnel is still `config/dev.exs`'s
  # hardcoded bootstrap).
  defp tunnel_for(%{main: true} = copy) do
    case PreviewTunnel.stored_credentials(copy) do
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

  defp tunnel_for(_copy), do: nil

  defp pending_fs(socket), do: socket.assigns[:pending_fs] || %{}

  defp pending_agent_stop(socket), do: socket.assigns[:pending_agent_stop] || %{}

  defp pending_machine_tool(socket), do: socket.assigns[:pending_machine_tool] || %{}

  # The machine's answer, in the shape a tool's caller expects. An error is kept
  # as an error rather than folded into the text: a browser that refused and a
  # browser that answered "no such element" are different things to an agent
  # deciding what to do next.
  defp decode_machine_tool_result(%{"error" => reason}), do: {:error, reason}
  defp decode_machine_tool_result(%{"text" => text}), do: {:ok, text}
  defp decode_machine_tool_result(other), do: {:error, {:unexpected_reply, other}}

  # Both halves of the pair or neither. A group id recorded without its boot
  # cannot later be told from a recycled number, and the only safe thing to do
  # with one of those is nothing — so a reply carrying only half is not a start.
  # The id the machine confirms it is running. It used to be a process group id
  # and the boot it belonged to; a supervised agent needs neither, and the id
  # was already on the row.
  # A created copy is its root and the identity written into it. Both, because
  # neither alone lets the server record a checkout: the root without the id
  # cannot be matched to the file the harness wrote, and the id without the root
  # is a row that is not a checkout.
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

  # The failures a machine can name, and nothing else.
  #
  # `String.to_atom/1` here would mint an atom per distinct message, and atoms
  # are never collected. Harmless while every reason was one of ours; not
  # harmless now that a provider's error — prose, with a timestamp and a quoted
  # upstream body in it — reaches this decoder.
  #
  # Callers match on these; anything else is for a human to read, so it stays a
  # string rather than becoming a permanent entry in a finite table.
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
    withdraw_timed_out
    already_delivered
  )

  defp decode_reason(reason) when reason in @machine_reasons, do: String.to_atom(reason)
  defp decode_reason(reason), do: reason

  # What became of a message the operator sent. Anything this server cannot
  # read is an error rather than a default disposition: reporting "delivered"
  # for an answer we did not understand is the failure this story is about.
  defp decode_send_result(%{"status" => "ok", "disposition" => "started"}), do: {:ok, :started}
  defp decode_send_result(%{"status" => "ok", "disposition" => "queued"}), do: {:ok, :queued}

  defp decode_send_result(%{"reason" => reason}) when is_binary(reason),
    do: {:error, decode_reason(reason)}

  defp decode_send_result(_msg), do: {:error, :unreadable_send_result}

  defp decode_withdraw_result(%{"status" => "ok"}), do: :ok

  defp decode_withdraw_result(%{"status" => "already_delivered"}),
    do: {:error, :already_delivered}

  defp decode_withdraw_result(%{"reason" => reason}) when is_binary(reason),
    do: {:error, decode_reason(reason)}

  defp decode_withdraw_result(_msg), do: {:error, :unreadable_withdraw_result}

  defp decode_message_result(%{"status" => "ok", "reply" => reply}) when is_binary(reply),
    do: {:ok, reply}

  defp decode_message_result(%{"status" => "error", "reason" => reason}),
    do: {:error, decode_reason(reason)}

  # A shape this server does not understand is not an answer. Reporting one as
  # success would tell an operator their instruction landed when nothing knows
  # whether it did.
  defp decode_message_result(other), do: {:error, {:unexpected_message_result, other}}

  defp decode_stop_result(%{"status" => "ok"}), do: :ok

  defp decode_stop_result(%{"status" => "error", "reason" => reason}),
    do: {:error, decode_reason(reason)}

  # A shape this server does not understand is not a stop. Reporting one would
  # clear `os_pid` on a process that is still running, which is the state
  # nothing can recover from.
  defp decode_stop_result(other), do: {:error, {:unexpected_stop_result, other}}

  # Story 1108. `app_url`/`app_commit` are optional in the reply — a report
  # that only confirmed the app is still serving has neither reason to
  # change, same as `WorkingCopies.record_app_status/2` treats them.
  # `Map.get/2` rather than a second clause: a map pattern matches on "at
  # least these keys," so a stricter-looking clause added below this one
  # would never be reached.
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
  #
  # Five handlers answer from a task rather than inline, because the work takes
  # longer than the channel can be held for — a decision, a skill, a suite run,
  # a 20-minute analyzer wait. `socket_ref/1` is what lets the answer outlive
  # the call that asked for it.
  #
  # Silence is the one answer they must never give. Deciding inline, a crash
  # took the channel down and the harness saw the socket close — bad, but loud.
  # From an unwatched task it kills nothing and sends nothing, and the harness
  # sits out its full timeout on every turn, which reads as latency rather than
  # as a crash.
  #
  # Three of them bought that promise with a blanket `rescue` around the reply
  # function. It was the wrong instrument twice over. It caught only what raised
  # *inside* that function, so a task killed by its supervisor, an exit, or a
  # throw still answered nothing — and the ownership error this found in testing
  # is exactly that shape. And a rescue that turns every exception into
  # `"decision_crashed"` is indistinguishable from a decision that was made.
  #
  # The channel monitors what it starts instead. A task that ends any way but
  # `:normal` is answered by the process that is already watching it, which
  # covers every way of dying rather than one, and leaves the reply functions
  # free to return error tuples for the failures they actually have.
  # The task computes the answer; the channel sends it.
  #
  # `async_nolink/2` rather than `start_child` + `Process.monitor`, because
  # those two are not one step and the gap between them is a race the fast path
  # wins. A pre-tool-use decision that is a few map lookups finishes before the
  # monitor is established, and `Process.monitor/1` on an already-dead process
  # delivers `:noproc` immediately — so a handler that answered correctly was
  # then reported dead and a second, contradicting reply was sent after it.
  #
  # Not theoretical: 29 of them in the three minutes after this shipped,
  # `decision (pre-tool-use) died: :noproc` against decisions that had already
  # succeeded. `async_nolink` monitors at spawn, so there is no gap to lose.
  #
  # The task also stops replying for itself. `{ref, result}` arrives before the
  # `:DOWN`, so the channel sends the answer and drops the entry, and a `:DOWN`
  # that still finds an entry means the task died without producing one. One
  # reply per request, decided in one process, whichever way it goes.
  defp reply_async(socket, ref, label, fun) do
    task = Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fun)

    assign(socket, :pending_replies, Map.put(pending_replies(socket), task.ref, {ref, label}))
  end

  # The answer the task computed. Sending it here is what makes the entry's
  # absence mean "already answered" — `Task.Supervisor.async_nolink/2` follows
  # every result with a `:DOWN`, and the two have to be told apart by something.
  defp deliver_pending(socket, task_ref, result) do
    case Map.pop(pending_replies(socket), task_ref) do
      {nil, _} ->
        socket

      {{ref, _label}, pending} ->
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

      {{ref, label}, pending} ->
        Logger.error("[HarnessProject] #{describe(label)} died: #{death_reason(reason)}")

        Phoenix.Channel.reply(
          ref,
          {:error, %{"reason" => "handler_died", "at" => describe(label)}}
        )

        assign(socket, :pending_replies, pending)
    end
  end

  defp pending_replies(socket), do: socket.assigns[:pending_replies] || %{}

  defp describe({handler, detail}), do: "#{handler} (#{detail})"
  defp describe(handler), do: handler

  defp decision_reply(hook, scope, payload, port) do
    case decide_hook(hook, scope, payload, port) do
      {:error, reason} -> {:error, %{"reason" => reason}}
      {200, body} -> {:ok, body}
      {status, body} when is_integer(status) -> {:error, %{"status" => status, "body" => body}}
    end
  end

  # Same crash-safety reasoning as `decision_reply/4` above: a bad skill
  # invocation (an unknown skill, a session that fails to start) must come
  # back as a reply, never as a dead channel.
  defp skill_reply(scope, params) do
    case SkillRouter.resolve(scope, params) do
      {:ok, result} -> {:ok, result}
      {:error, reason, available} -> {:error, %{"error" => reason, "available" => available}}
      {:error, reason} -> {:error, %{"error" => reason}}
    end
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
  end

  # What `File` and `Environments.Local` fail with, and nothing else.
  #
  # Callers match on `:enoent` and friends, so these come back as the atoms they
  # left as. Without them a missing file arrived as `"enoent"` and every such
  # match fell through on a harness: `ArchitectureDesign` read a missing proposal
  # as unreadable and never chose initial mode (8e3669fc).
  #
  # A literal map, so the atoms are this module's and nothing off the wire is
  # ever turned into one. Anything unlisted keeps its string.
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

  # A refusal that arrived with structure keeps it. `Promotion.Steps` answers
  # with a sentence and its evidence — the uncommitted files, the conflicted
  # paths — and the agent needs both. Passed through as a map for
  # `Promotion.Runner` to key, rather than flattened into a reason atom that
  # would have to be parsed back apart.
  def decode_fs_result(%{"error" => %{} = reason}), do: {:error, reason}

  def decode_fs_result(%{"ok" => true, "result" => result}), do: {:ok, result}
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

  # Why a failed analyzer failed, on the line that says it failed.
  #
  # `failed, 0 problem(s)` is indistinguishable from a crashed analyzer, a
  # killed process, or a machine under load — and when it happened the machine
  # *was* under load, so the agent attributed it to contention and carried on
  # stopping against green local runs. The real reason was one string away:
  #
  #     the server REJECTED the exunit result: {:test_suite_did_not_run, 1,
  #       "** (RuntimeError) The test database `code_my_spec_testhac99571fa`
  #        is 2 migration(s) behind."}
  #
  # That message was written to `harness.log` and thrown away on the way here.
  # `Reconciler.fail/2` has always persisted it to `stats["error"]`, and
  # `Analysis.status/1` has always returned the run — this line simply never
  # read it. Four sweeps' worth of stop hooks reported an analyzer that had
  # silently stopped verifying the working copy, and the only tell was a log
  # file the agent has no reason to open (`d1f74ee7`).
  #
  # Truncated because an analyzer failure can carry a whole stacktrace, and a
  # summary that scrolls is one nobody reads. The first line is where these
  # tools put the sentence that names the cause.
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

  # The other thing the server initiates. Same shape and same reason as
  # `run_analysis`: this side owns the record, that side owns the disk.
  #
  # No payload. The harness already knows which working copy this channel is
  # for, and a root on the wire would be a second answer to a question the
  # topic has already answered — the class of bug story 891 exists to remove.
  def handle_info(:rescan, socket) do
    push(socket, "rescan", %{})
    {:noreply, socket}
  end

  # This copy was offboarded, so tell the machine to stop serving it.
  #
  # `WorkingCopies.offboard/2` sends this after the transaction commits, so the
  # row is already gone by the time it arrives — which is why the push carries
  # nothing to look up. The harness knows which root this channel is for.
  #
  # Pushed and forgotten. An offboard has to work on a machine that is off, and
  # a copy whose machine is gone is precisely the one an operator most needs to
  # remove — so nothing here may wait, and nothing may fail the offboard that
  # has already happened. Issue 03ea1ee5.
  def handle_info({:offboarded, _working_copy_id}, socket) do
    push(socket, "offboard", %{})
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
        "#{counts.changed} changed, #{component_count(counts.components)}"
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

  # A deferred reply's answer, and then its task ending. `reply_async/4`
  # explains why the channel holds both rather than the task replying for
  # itself.
  #
  # Below the reconcile clauses on purpose: that task is tracked in
  # `:reconciling` and is not one of these, and a catch-all here would swallow
  # its result and its DOWN both.
  def handle_info({task_ref, result}, socket) when is_reference(task_ref),
    do: {:noreply, deliver_pending(socket, task_ref, result)}

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, socket),
    do: {:noreply, resolve_pending(socket, task_ref, reason)}

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
    case Analysis.await_run(scope, source, args, requested_by: %{kind: "agent_mix_test"}) do
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

  # A promotion's outcome as the caller reads it, and it always answers
  # `{:ok, …}`.
  #
  # A refusal is an answer. The gate declining, a conflict, uncommitted work —
  # each of those is the promotion working correctly and naming the thing the
  # caller has to act on, so it travels as a result with `refused` in it rather
  # than as a channel error. `{:error, …}` on this wire means the promotion
  # could not be attempted at all, and the HTTP door turns that into a 502;
  # collapsing the two would report a gate refusal as a broken server.
  #
  # The same split `run_for_agent/3` above makes: a failing suite is an
  # `{:ok, run}` carrying a non-zero exit status, not an error.
  #
  # The words come from `Responses`, which is where the other two doors get
  # theirs. A third rendering of "what happened to your promotion" is a third
  # thing to keep in step, and this module exists because two already were.
  # Inside the harness's own 20-minute wait for this reply, so a candidate still
  # queued is answered as queued rather than as a timeout.
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

  # The same question `assigns.reconciling` answers, asked across channels.
  #
  # `terminate/2` kills the reconcile when a channel goes away, so in the
  # ordinary case nothing is in flight here and this is a lookup that finds
  # nothing. It exists for the case where `terminate/2` did not get to run — a
  # killed node, a channel that vanished without draining — because that is
  # exactly when an orphaned reconcile is still holding a connection and a
  # second one would start the stacking again (`1aed7edf`).
  #
  # Skipping rather than queueing: the harness re-sends the whole manifest on
  # every join, so the running reconcile is landing the same tree this one
  # carries. Queueing it across processes would mean holding another channel's
  # work with nothing to deliver it to when that channel is already gone.
  #
  # Logged, and not quietly, because a skipped reconcile means this working
  # copy's rows are older than the manifest that just arrived. That is fine for
  # the seconds until the running one finishes and wrong to let pass unseen.
  defp maybe_start_reconcile(socket, entries) do
    working_copy_id = socket.assigns.scope.active_working_copy_id

    case ReconcileRegistry.in_flight(working_copy_id) do
      nil ->
        assign(socket, :reconciling, start_reconcile(socket.assigns.scope, entries))

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

  # `:unchanged` means the component projection did not run, because no file
  # row was written or deleted and components are derived from those alone.
  # Said in words rather than as a number: "0 components" would read as a
  # project that has none, which is the alarming version of the healthy case.
  defp component_count(:unchanged), do: "components unchanged (projection skipped)"
  defp component_count(n) when is_integer(n), do: "#{n} components"

  defp start_reconcile(scope, entries) do
    Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fn ->
      # Marked by the task, not by this function, so the entry lives exactly as
      # long as the work and needs no cleanup — when the task exits, registered
      # or crashed, the marker goes with it.
      ReconcileRegistry.mark(scope.active_working_copy_id, length(entries))
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

  # -- Agent presence -----------------------------------------------------------

  # Only this copy's agents: an id the harness reports for another copy, or for
  # an agent this project does not have, is not this channel's to track. One
  # already tracked is skipped — a second `track` is `:already_tracked`, and a
  # repeated up must not take the channel, and every agent's presence, with it.
  defp track_agents(socket, ids) do
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
    present =
      for id <- ids, reduce: present_agents(socket) do
        present ->
          :ok = Agents.Presence.untrack(self(), presence_topic(socket), id)
          MapSet.delete(present, id)
      end

    assign(socket, :present_agents, present)
  end

  defp own_agent?(socket, id) do
    match?(
      {:ok, %{working_copy_id: copy}} when copy == socket.assigns.scope.active_working_copy_id,
      Agents.fetch_agent(socket.assigns.scope, id)
    )
  end

  defp present_agents(socket), do: Map.get(socket.assigns, :present_agents, MapSet.new())
  defp presence_topic(socket), do: Agents.presence_topic(socket.assigns.scope.active_project_id)
  defp copy_id(socket), do: socket.assigns.scope.active_working_copy_id

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
  # are no longer `:running` and are refused — unless the rejoining harness
  # claims them, which reopens them; requested runs it does not claim are run
  # again (`Analysis.resume_orphaned/2`).
  def terminate(reason, socket) do
    shutdown_reconcile(socket)

    case socket.assigns[:scope] do
      %Scope{active_project_id: id} when not is_nil(id) ->
        log_disconnect(reason, socket)
        Analysis.fail_in_flight(socket.assigns.scope, failure_reason(reason))

      _ ->
        :ok
    end

    :ok
  end

  # The reconcile dies with the channel that started it.
  #
  # `async_nolink` deliberately does not link the task to this process, so
  # without this it keeps running under `TaskSupervisor` after the channel is
  # gone — and the rejoin gets a *fresh channel with empty assigns*, sees no
  # reconcile in flight, and starts another on top of the orphan. The
  # `reconciling`/`pending_manifest` pair serialises reconciles within one
  # channel and cannot see across two.
  #
  # That is the join storm in `1aed7edf`: a rejoin every ~1.2s, each starting a
  # full reconcile that holds a connection for the 9-10s it takes, until the
  # pool is exhausted and `insert_all` into `files` dies with
  # `client ... timed out because it queued and checked out the connection for
  # longer than 60000ms`. The crash closes the channel, the close triggers a
  # rejoin, and the next attempt is exactly as slow as the last — so it does not
  # self-clear. Observed for 15+ minutes across two working copies, ending only
  # when the harness was killed by hand.
  #
  # Killing it loses nothing. The harness re-sends the entire manifest on every
  # join — `holding` is followed by `scanned N files` and `sent N observations`
  # in harness.log, on every one — and `reconcile_and_project/2` runs in a
  # transaction, so a killed reconcile rolls back rather than leaving a half
  # projection. The work is redone by the join that replaces it, which was going
  # to redo it anyway.
  defp shutdown_reconcile(%{assigns: %{reconciling: %Task{} = task}} = socket) do
    Task.shutdown(task, :brutal_kill)

    # Logged because a fix that works silently cannot be told from one that
    # never runs. The test proves the mechanism; this is the only thing that
    # says it is happening here, on this machine, on the closes that actually
    # occur. Info rather than warning: this is the healthy path — the reconcile
    # is redone by the join that replaces it — and the unhealthy version of the
    # same situation is the skip in `maybe_start_reconcile/2`, which warns.
    Logger.info(
      "[HarnessProject] killed the in-flight reconcile for #{closing_copy(socket)} — its " <>
        "channel is closing and the rejoin re-sends the whole manifest anyway. Left running, " <>
        "it would still hold a connection when the next join starts another (1aed7edf)."
    )

    :ok
  end

  defp shutdown_reconcile(_socket), do: :ok

  # Not `harness_label/1`, which already exists for join payloads. Same idea,
  # different input, and merging them would make one function that takes either
  # a socket or a payload.
  defp closing_copy(%{assigns: %{scope: %Scope{active_working_copy_id: id}}}) when is_binary(id),
    do: "harness #{id}"

  defp closing_copy(socket), do: socket.topic

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
      "[HarnessProject] channel DIED topic=#{socket.topic}#{instance_tag(socket)}" <>
        " reason=#{death_reason(reason)}" <>
        " — every in-flight run for this working copy is about to be failed as" <>
        " :harness_disconnected. The analyzers keep running on the harness and" <>
        " their results will be refused as unknown_run. Fix the crash, not the sweep." <>
        instance_hint(socket)
    )
  end

  # Names the harness process behind this channel, when the registry still has
  # it — which it does for the whole of `terminate/2`, since a `Registry` entry
  # outlives the process that owns it until the process actually exits.
  #
  # Without this, `:peer_closed` here and a stale channel registration present
  # identically from the addressee's side: both drop channels and fail tool
  # calls with a transport error, and neither project's own log says which one
  # happened. Two sessions independently guessed wrong, in opposite directions,
  # on the same incident (225860ce).
  defp instance_tag(socket) do
    case working_copy_instance(socket) do
      nil -> ""
      instance -> " instance=#{instance}"
    end
  end

  # One harness process serves every working copy it holds, so a crash there
  # drops all of them at once — a signature invisible from any single project's
  # log, which is what turned a 34-second-later recovery into the suspected
  # cause. Named rather than counted: a live count racing the same crash that
  # is killing its own siblings' channels would undercount whichever have not
  # been through this same callback yet, and a wrong number reads as more
  # certain than a grep.
  defp instance_hint(socket) do
    case working_copy_instance(socket) do
      nil ->
        ""

      instance ->
        " This harness process (instance=#{instance}) serves every working copy it" <>
          " holds, so every other project on it dropped at the same moment — grep" <>
          " instance=#{instance} across server.log to see them, rather than reading" <>
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
  # `is_exception/1` rather than a rescue around the formatting. Not every
  # two-tuple with a list in it is a crash, and asking whether this one is
  # answers that up front — where a rescue answered it by trying and failing,
  # and would have swallowed a genuine formatting bug alongside.
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

  # `:harness` because that is what answers on this port: a decision made here is
  # returned down the channel to `cms_harness`, whose routes are all addressed
  # `/api/harnesses/<id>/...`. It used to be inferred from the scope carrying a
  # `cwd` — which every proxied copy does, since it describes the agent's disk —
  # so the rewrite pointed at the packaged server's bare route and 404'd (60b50e40).
  defp decide_hook("pre-tool-use", scope, payload, port),
    do: {200, PreToolUse.decide(scope, payload, port, :harness)}

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
  # Shared with `ProjectScopeOverride`, which set only `active_working_copy_id` and
  # left MCP tools able to name a working copy they could not read.
  defp put_harness_scope(scope, harness), do: WorkingCopies.put_scope(scope, harness)

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
    case HarnessRegistry.register_executor(harness.id, payload["instance"], payload["root"]) do
      :ok ->
        register_app_verbs(harness, payload)

      {:error, {:already_registered, pid}} ->
        Logger.warning(
          "[HarnessProject] refused a second harness on working copy #{harness.root || harness.id} " <>
            "of project #{harness.project_id} (joining instance #{inspect(payload["instance"])}, " <>
            "held by #{inspect(pid)})"
        )

        {:error, working_copy_in_use(harness, pid)}

      # One process, one id, two different checkouts. Not a second harness —
      # the same one, whose working copies have collapsed onto a single
      # identity upstream.
      #
      # Evicting here is what produced the 2026-08-20 outage: each join killed
      # the sibling's channel, the victim rejoined and killed it back, 1078
      # times at roughly one a second with every stop hook refused. Refusing
      # names both roots, which is a thing an operator can act on.
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

  defp id_collision(harness, joining_root, held_root) do
    %{
      reason: "harness_id_collision",
      working_copy_id: harness.id,
      root: joining_root,
      held_by_root: held_root,
      detail:
        "Two working copies are presenting harness #{harness.id}: this join is for " <>
          "#{inspect(joining_root)} and the id is already held for #{inspect(held_root)}. " <>
          "A harness id names one checkout, so one of these read its identity from " <>
          "somewhere other than its own `.cms_harness.json` — most often `CMS_HARNESS_ID` " <>
          "inherited from the session that started the daemon. Restart the harness from " <>
          "an environment without it, and check each checkout's `.cms_harness.json`."
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

  # Which machine this checkout is on — **looked up, never created**.
  #
  # Creating a device here was the first cut of this and it is the wrong grain:
  # one install serves many checkouts, so a per-join announce mints a machine
  # per working copy. Eight worktrees on one laptop would be eight laptops, and
  # the device list becomes a slower copy of the list it exists to summarise.
  # Onboarding is `CmsHarness.Device.announce/0`, once, when the harness comes
  # up — `POST /api/devices`, which needs no project and so can happen before
  # any checkout exists. Criterion 2847 is that rule.
  #
  # So the join only reports an association. An unknown id attaches nothing
  # rather than inventing a machine, which keeps "this checkout is on a device
  # we know about" from being something a checkout can assert into existence.
  defp resolve_device(scope, %{"device" => %{"id" => id}}) when is_binary(id) do
    Devices.get_device(scope, id)
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

  defp harness_label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp harness_label(_payload), do: "a harness that did not say where it is"

  # A join that does not name a root is not an error — a harness built before
  # the field existed does not send one, and its identity is unaffected either
  # way, because the root is recorded about the harness rather than used to
  # find it.
  #
  # Corrects any agent's stale `working_copy` snapshot in the same beat as
  # the working copy's own root, not just at read time — `LaunchRequest.for/2`
  # sends `agent.working_copy` verbatim on a restore, so a row started against
  # the old path would otherwise keep offering it forever, and restore fails
  # with `:working_copy_missing` against a checkout that just joined correctly.
  defp report_root(scope, harness, root) when is_binary(root) and root != "" do
    with {:ok, harness} <- WorkingCopies.report_root(harness, root) do
      {:ok, _count} = Agents.sync_working_copy_root(scope, harness.id, harness.root)
      {:ok, harness}
    end
  end

  defp report_root(_scope, harness, _), do: {:ok, harness}

  # Story 968. The checkout's config is the source; this is the server's copy of
  # it, kept the way `root` is, so the web app can render a frame at an address
  # without reading anybody's disk.
  #
  # A refusal is not a join failure. `record_preview_url/2` rejects a copy that
  # is not the main one, and a worktree presenting an address is a
  # misconfiguration in *its* config — dropping the join over it would take a
  # working checkout off the harness to punish a field nothing depends on. The
  # address simply is not recorded, which is what the rule asks for.
  defp report_preview_url(harness, url) when is_binary(url) and url != "" do
    case WorkingCopies.record_preview_url(harness, url) do
      {:ok, harness} -> {:ok, harness}
      _ -> {:ok, harness}
    end
  end

  defp report_preview_url(harness, _), do: {:ok, harness}

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
  # A turn's own tokens, kept whether or not the proxy can also place it in a
  # conversation -- `payload["agent_role"]` plus the copy already running on
  # this socket is how `record_turn` finds "which agent", since the wire
  # never names one directly.
  defp record_turn_tokens(scope, payload) do
    role = payload["agent_role"] || "main"

    case Agents.find_by_working_copy_and_role(scope, scope.active_working_copy_id, role) do
      nil ->
        :ok

      agent ->
        TokenUsage.record(scope, agent.id, agent.story_id, agent.provider, payload["response"] || %{})
    end
  end

  defp session_external_id(scope, payload) do
    case payload["session_id"] do
      id when is_binary(id) and id != "" -> id
      _ -> Sessions.external_id_for_harness(scope.active_working_copy_id) || "sprite"
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
end
