defmodule CodeMySpecWeb.HarnessProjectChannel do
  @moduledoc """
  The **data plane** for one project: the channel a light harness holds while
  it owns that project's files.

  Distinct from `HarnessChannel`, which is account-scoped and relays an agent's
  conversation to the operator inbox. This one is project-scoped and carries
  the work — sync results, analysis results, and the lease itself.

  ## The channel is the lease

  Joining takes the project's advisory lock, on a connection this channel
  process owns. Postgres drops that lock when the connection closes, and the
  connection is linked to the channel — so a harness that panics, is killed, or
  simply loses its network frees the project as its socket closes. There is no
  deadline to wait out and no heartbeat to miss.

  That is the reason a channel carries this rather than REST. Not throughput —
  liveness. REST has no "this client is still here" signal, so a lease over
  REST needs an expiry and a heartbeat, which is a timer compensating for a
  deadline.

  A second harness on the same project is refused at join, told who holds it.
  It does not queue: two harnesses syncing one project overwrite each other's
  files and produce a requirement graph matching neither checkout, so the
  second one should stop, not wait.
  """

  use CodeMySpecWeb, :channel

  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.AgentHarness.ConversationRecorder
  alias CodeMySpec.Analysis
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Files.FileSync
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
  alias CodeMySpec.Leases
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope

  @impl true
  def join("harness_project:" <> project_id, payload, socket) do
    label = harness_label(payload)

    with {:ok, scope} <- authorize(socket, project_id),
         {:ok, harness} <- Harnesses.issue(scope, payload["harness_id"], label: label),
         {:ok, holder} <- start_lease_holder(),
         :ok <- Leases.acquire(scope, label, holder),
         :ok <- Analysis.register_executor(project_id) do
      # Anything still `:running` belongs to a previous connection. Its queue
      # was on a harness that has gone, so nothing will ever finish it — and an
      # open run makes every later stop report analysis pending, which allows
      # the stop while saying results will apply next time, on a next time that
      # never arrives. This is the one moment it is provably safe to close them.
      Analysis.fail_in_flight(scope, :harness_reconnected)

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
       |> assign(:scope, %{scope | active_harness_id: harness.id})
       |> assign(:harness, harness)
       |> assign(:lease_holder, holder)}
    else
      {:error, {:held_by, holder}} ->
        Logger.warning("[HarnessProject] refused #{project_id} — already held by #{holder}")
        {:error, %{reason: "project_in_use", held_by: holder}}

      {:error, {:already_registered, _pid}} ->
        # The lease was acquired but the executor slot was not, which means two
        # channels for one project got past the lease. Refused rather than
        # served: the second harness would run analyzers whose results the
        # server would attribute to runs it dispatched to the first.
        Logger.error("[HarnessProject] #{project_id} already has an analysis executor registered")
        {:error, %{reason: "project_in_use", held_by: "another harness on this server"}}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid topic"}}

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
        payload["session_id"] || "sprite",
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
    case deserialize_observations(observations) do
      {:ok, entries} ->
        scope = socket.assigns.scope
        summary = FileSync.reconcile(scope, entries)

        # Reconciling files is only half of a sync. The other half turns those
        # files into components and — the part that matters here — writes
        # `component_id` back onto each File row.
        #
        # Without it every `implementation_file` requirement stays unsatisfied
        # forever: the check is scoped to a component's own files, and a file
        # nothing owns is invisible to it. Drill 11 finished the entire project
        # chain, wrote every module, passed 157 tests, and still showed 15
        # implementation requirements open with all 66 implementation files
        # synced and not one of them linked.
        #
        # The local path has always run both (see `Tools.SyncProject`). This one
        # ran only the first, and could not have run the second until
        # `ComponentSync` stopped needing to read the files itself — the
        # component identity now travels in the File record, which is what makes
        # this line possible at all.
        {:ok, components} = ComponentSync.sync_from_files(scope)

        {:reply,
         {:ok,
          %{
            "upserted" => summary.upserted,
            "removed" => summary.removed,
            "changed" => length(summary.changed_entries),
            "components" => length(components.all_components)
          }}, socket}

      {:error, problems} ->
        # Usually version skew: a harness classifying files into roles this
        # server has never heard of. Writing those as nil would land wrong rows
        # and surface later as a requirement graph nobody can explain, so the
        # manifest is rejected whole and the reasons are named.
        Logger.warning("[HarnessProject] rejected manifest: #{inspect(problems)}")

        {:reply, {:error, %{"reason" => "invalid_manifest", "problems" => problems}}, socket}
    end
  end

  # Decide a hook the harness is proxying for Claude Code.
  #
  # The decision is database work — blocking problems, config modes, session and
  # task state — so it lives here, while the analyzers that feed it shell out
  # against a working copy and stay on the harness. This is the same split the
  # local controllers already use; they call the identical `Hooks.*` modules, so
  # the two paths cannot drift in what they decide, only in how they are reached.
  #
  # On the critical path of every agent turn, so it does exactly one thing.
  def handle_in("hook_decision", %{"hook" => hook, "payload" => payload} = msg, socket)
      when is_binary(hook) and is_map(payload) do
    case decide_hook(hook, socket.assigns.scope, payload, msg["port"]) do
      {:error, reason} ->
        {:reply, {:error, %{"reason" => reason}}, socket}

      {200, body} ->
        {:reply, {:ok, body}, socket}

      {status, body} when is_integer(status) ->
        {:reply, {:error, %{"status" => status, "body" => body}}, socket}
    end
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
  def handle_in("analysis_result", %{"run_id" => _, "source" => source} = payload, socket) do
    case Analysis.record_remote_result(socket.assigns.scope, payload) do
      {:ok, run} ->
        {:reply, {:ok, %{"run_id" => run.id, "status" => to_string(run.status)}}, socket}

      {:error, :unknown_run} ->
        # Either the run was already closed (its channel dropped and rejoined)
        # or it belongs to another project. Not applied: reconciling it would
        # rewrite this source's Problems off a run nobody is waiting for.
        Logger.warning("[HarnessProject] #{source} result for a run this server is not tracking")

        {:reply, {:error, %{"reason" => "unknown_run"}}, socket}

      {:error, reason} ->
        Logger.warning("[HarnessProject] #{source} result rejected: #{inspect(reason)}")
        {:reply, {:error, %{"reason" => inspect(reason)}}, socket}
    end
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

  def handle_info(_message, socket), do: {:noreply, socket}

  # Everything this harness had running dies with it: the queue was on the other
  # machine. Leaving those rows `:running` would make every later stop for this
  # project report analysis pending — an allow, with a note that results apply
  # next time, forever.
  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:scope] do
      %Scope{active_project_id: id} when not is_nil(id) ->
        Analysis.fail_in_flight(socket.assigns.scope, :harness_disconnected)

      _ ->
        :ok
    end

    :ok
  end

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
  defp harness_label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp harness_label(_payload), do: "a harness that did not say where it is"

  # Linked, deliberately. This process dying is what releases the lock, so the
  # holder must not outlive the channel — and a holder that cannot start must
  # fail the join rather than silently leave the project unguarded.
  defp start_lease_holder do
    Leases.Session.start_link(name: nil)
  end
end
