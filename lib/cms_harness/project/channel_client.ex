defmodule CmsHarness.Project.ChannelClient do
  @moduledoc """
  One project's channel to the server. While it is joined, this harness owns
  that project.

  **The channel is the lease.** The server takes the project's advisory lock
  when this joins and drops it when the socket closes, on a connection the
  server-side channel process owns. So a harness that panics, is `docker rm
  -f`'d, or loses its network frees the project as its socket closes — no TTL,
  no heartbeat, no clock to agree on. That is why this is a channel rather than
  a series of requests: not throughput, liveness.

  Everything the harness initiates goes through here:

    * `read_model` on join — the small slice of the domain that scanning needs,
      fetched rather than inferred because the harness has no database to
      derive it from
    * `observations` — the whole manifest, never a delta
    * `analysis_result` — what an analyzer printed, for the server to convert
      into Problems
    * hook decisions — a call with a reply, on the critical path of every agent
      turn

  And one thing the *server* initiates: `run_analysis`, naming the analyzers it
  wants run against this working copy. That direction exists because the
  decision about what is stale is a database question and the execution is a
  disk one, and they are on different machines.

  ## Connection state is a published fact, not an assumption

  `connected?/1` exists so that the two things that must not run blind can ask.
  The hook controller refuses rather than allowing; the watcher stops watching
  rather than queueing events it will not remember. Both of them read it from
  here.

  ## A refused join does not retry

  If another harness already holds the project, the server refuses and names
  the holder. Two harnesses syncing one project overwrite each other's files
  and produce a requirement graph matching neither, so the second one stops.
  Reconnecting on a loop would just be that same collision, once a second.
  """

  use Slipstream

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Project.Watcher
  alias CmsHarness.Sync
  alias CodeMySpec.Files.Scanner.ReadModel

  # Long enough for a transatlantic round trip against a busy server, short
  # enough that a hung hook is a hook that eventually answers. It is paid on
  # every agent turn, so it is not generous.
  @default_decision_timeout 10_000

  @backoff [1_000, 2_000, 5_000, 10_000, 30_000]

  # The server needs this and cannot know it. `pre-tool-use` rewrites the agent's
  # analysis command into a curl, and that curl points at this harness's own
  # endpoint — a URL that only means anything on the machine running the agent.
  # The server refuses to rewrite without it rather than pointing it somewhere
  # plausible, which would produce a command that runs and reports against the
  # wrong process.
  #
  # The *bound* port, not the configured one. They agree while the port is fixed
  # at 4005, but a configured `port: 0` means "pick one", and reading the config
  # back would hand the server a literal 0 — a curl to localhost:0, failing in a
  # way that says nothing about why.
  defp local_port do
    case CmsHarness.Web.Endpoint.server_info(:http) do
      {:ok, {_ip, port}} when is_integer(port) and port > 0 -> port
      _ -> CmsHarness.Web.Endpoint.config(:http)[:port]
    end
  end

  defp decision_timeout,
    do: Application.get_env(:code_my_spec, :harness_decision_timeout, @default_decision_timeout)

  # --- Client API ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    Slipstream.start_link(__MODULE__, project, name: via(project.id))
  end

  def via(project_id), do: {:via, Registry, {CmsHarness.Registry, {:channel, project_id}}}

  @doc """
  Whether this project's channel is joined right now.

  `false` covers "never connected", "dropped", and "refused" alike — from the
  caller's point of view they are the same fact: the harness cannot ask the
  server anything about this project.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(project_id) do
    case Registry.lookup(CmsHarness.Registry, {:channel, project_id}) do
      [{pid, _}] -> GenServer.call(pid, :connected?, 5_000)
      [] -> false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  Ask the server to decide a hook.

  Returns `{:error, :not_connected}` or `{:error, :no_reply}` rather than
  anything resembling an answer. The caller turns that into a refusal; this
  must never invent one.
  """
  @doc """
  Send a completed model turn to the server to be recorded.

  Fire and forget, and deliberately so. Recording is evidence for whoever is
  watching, never a step the agent's turn depends on — a cast cannot make the
  turn slower, cannot fail it, and cannot block it behind a server that is
  briefly unreachable. A turn lost from the record is a gap the operator is
  shown; a turn lost to the recorder would be work destroyed.
  """
  @spec record_turn(String.t(), map()) :: :ok
  def record_turn(project_id, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, project_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:record_turn, payload})
      [] -> :ok
    end

    :ok
  end

  @spec decide_hook(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_connected | :no_credential | :no_reply}
  def decide_hook(project_id, hook, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, project_id}) do
      [{pid, _}] -> GenServer.call(pid, {:decide_hook, hook, payload}, decision_timeout() + 2_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc "The read model this project last received. `nil` before the first join."
  @spec read_model(String.t()) :: ReadModel.t() | nil
  def read_model(project_id) do
    case Registry.lookup(CmsHarness.Registry, {:channel, project_id}) do
      [{pid, _}] -> GenServer.call(pid, :read_model, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Scan the working copy and send the manifest.

  Asynchronous: a full scan of a few thousand files takes seconds, and doing it
  in this process would stall the socket that holds the lease.
  """
  @spec request_sync(String.t()) :: :ok
  def request_sync(project_id) do
    case Registry.lookup(CmsHarness.Registry, {:channel, project_id}) do
      [{pid, _}] -> GenServer.cast(pid, :sync)
      [] -> :ok
    end
  end

  @doc false
  # Called from the scanning task with the finished manifest.
  @spec deliver_observations(String.t(), [map()]) :: :ok
  def deliver_observations(project_id, observations) do
    case Registry.lookup(CmsHarness.Registry, {:channel, project_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:observations, observations})
      [] -> :ok
    end
  end

  @doc false
  # Called from the analysis queue with a finished (or failed) run.
  @spec deliver_analysis_result(String.t(), map()) :: :ok
  def deliver_analysis_result(project_id, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, project_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:analysis_result, payload})

      [] ->
        # The channel died between the run starting and finishing. The server
        # closed that run's ledger row when the socket went, so this result has
        # nowhere to land — said out loud rather than dropped silently, because
        # the visible symptom otherwise is an analyzer that appears never to
        # have run.
        Logger.error(
          "[CmsHarness] #{payload["source"]} finished for project #{project_id} but the " <>
            "channel is gone — the result was discarded. It will be re-run on rejoin."
        )

        :ok
    end
  end

  # --- Slipstream callbacks ---

  @impl Slipstream
  def init(project) do
    socket =
      new_socket()
      |> assign(:project, project)
      |> assign(:topic, "harness_project:#{project.id}")
      |> assign(:joined, false)
      |> assign(:refused, nil)
      |> assign(:read_model, nil)
      |> assign(:pending, %{})
      |> assign(:analysis_refs, %{})
      |> assign(:attempts, 0)

    {:ok, socket, {:continue, :connect}}
  end

  @impl Slipstream
  def handle_continue(:connect, socket) do
    case Config.socket_url() do
      {:ok, uri} ->
        {:noreply, connect!(socket, uri: uri)}

      {:error, :no_credential} ->
        # Not a retry loop. Nothing about waiting produces a credential, and a
        # harness quietly retrying forever looks identical to one that is
        # working.
        Logger.error("""
        [CmsHarness] no credential, so this harness is connected to nothing.

        Set CMS_TOKEN (or CMS_DEPLOY_KEY on a sprite) and restart it. Until then
        every hook will refuse and no file change will be recorded.
        """)

        # Recorded, not just logged. Without this the hook path only knows
        # `joined: false` and reports the channel as down — sending whoever
        # reads it to check the network and the server, when the fix is to set
        # an environment variable. A wrong diagnosis costs more than no
        # diagnosis; this project has already lost an hour to one.
        {:noreply, assign(socket, :no_credential?, true)}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok,
     transport().join(socket, socket.assigns.topic, %{
       "label" => Config.label(socket.assigns.project.root)
     })}
  end

  @impl Slipstream
  def handle_join(topic, _reply, socket) do
    Logger.info("[CmsHarness] holding #{socket.assigns.project.root} — joined #{topic}")

    socket =
      socket
      |> assign(:joined, true)
      |> assign(:attempts, 0)
      |> assign(:refused, nil)

    schedule_read_model_refresh()

    # The read model first: a scan without one resolves no owners and validates
    # no specs, so it would produce a manifest that is wrong rather than late.
    case transport().push(socket, topic, "read_model", %{}, decision_timeout()) do
      {:ok, ref} -> {:ok, assign(socket, :read_model_ref, ref)}
      {:error, _} -> {:ok, socket}
    end
  end

  # How often the cached read model is refetched.
  #
  # It used to be fetched once, on join, and never again. A sprite joins before
  # the project has any stories or components, so it held an empty domain for the
  # entire session — and `Scanner.resolve_owners/2` refuses to link a file to a
  # story its read model has never heard of, which is the right rule and exactly
  # wrong against a cache that can no longer change.
  #
  # Drill 12 wrote 32 BDD spec files across 9 stories and not one was linked;
  # `bdd_specs_exist` failed for every story, gating all 69
  # `implementation_file` requirements behind it. Ownership is re-resolved
  # server-side now, so that particular consequence is gone — but the same stale
  # copy still feeds `validate_entry/4`, where an empty `component_by_id` means
  # test-alignment is silently never checked. Fixing the symptom is not fixing
  # the cache.
  @read_model_refresh_ms 60_000

  @doc false
  def read_model_refresh_ms, do: @read_model_refresh_ms

  defp schedule_read_model_refresh,
    do: Process.send_after(self(), :refresh_read_model, @read_model_refresh_ms)

  # A join the server refused. The only one we know how to explain is a project
  # another harness holds; anything else is reported as it arrived.
  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    socket = socket |> assign(:joined, false) |> pause_watcher()

    # Slipstream reports a refused join as `:failed_to_join` and a channel that
    # closed after joining as `:error`; the refusal we know how to explain can
    # arrive either way.
    case reason do
      {kind, %{"reason" => "project_in_use", "held_by" => holder}}
      when kind in [:error, :failed_to_join] ->
        Logger.error("""
        [CmsHarness] not serving #{socket.assigns.project.root} — #{holder} already holds this project.

        Two harnesses syncing one project overwrite each other's files and produce a
        requirement graph matching neither checkout, so this one is stopping rather
        than waiting. That lease frees the moment the other harness exits.
        """)

        {:ok, assign(socket, :refused, :project_in_use)}

      other ->
        Logger.warning("[CmsHarness] #{topic} closed: #{inspect(other)}")
        {:ok, schedule_rejoin(socket)}
    end
  end

  @impl Slipstream
  def handle_reply(ref, reply, %{assigns: %{read_model_ref: ref}} = socket) do
    case reply do
      {:ok, payload} ->
        socket =
          socket |> assign(:read_model, deserialize_read_model(payload)) |> resume_watcher()

        # Only now is a scan meaningful.
        Sync.start(socket.assigns.project, socket.assigns.read_model)
        {:ok, socket}

      other ->
        Logger.error("""
        [CmsHarness] the server would not hand over the read model for #{socket.assigns.project.root}: #{inspect(other)}

        Without it the harness cannot resolve which component or story a file belongs
        to, so it is not scanning rather than scanning wrongly.
        """)

        {:ok, socket}
    end
  end

  def handle_reply(ref, reply, %{assigns: %{observations_ref: ref}} = socket) do
    socket = assign(socket, :observations_ref, nil)

    case reply do
      {:ok, %{"upserted" => upserted, "removed" => removed}} ->
        Logger.info(
          "[CmsHarness] server accepted the manifest for #{socket.assigns.project.root}: " <>
            "#{upserted} upserted, #{removed} removed"
        )

        {:ok, socket}

      other ->
        # Loud, and says what it means: the working copy and the server's
        # picture of it are now different, and nothing downstream can tell.
        Logger.error("""
        [CmsHarness] the server REJECTED the manifest for #{socket.assigns.project.root}: #{inspect(other)}

        The server's picture of this project is now out of step with the disk,
        and the requirement graph is computed from the server's picture. This is
        not "nothing changed" — the sync was refused. Usually version skew
        between this harness and the server.
        """)

        {:ok, socket}
    end
  end

  def handle_reply(ref, reply, socket) do
    case pop_in(socket.assigns.analysis_refs, [ref]) do
      {nil, _} ->
        handle_pending_reply(ref, reply, socket)

      {source, refs} ->
        {:ok, log_analysis_reply(source, reply, assign(socket, :analysis_refs, refs))}
    end
  end

  defp handle_pending_reply(ref, reply, socket) do
    case pop_in(socket.assigns.pending, [ref]) do
      {nil, _} ->
        {:ok, log_unmatched_reply(ref, reply, socket)}

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, normalize_reply(reply))
        {:ok, assign(socket, :pending, pending)}
    end
  end

  # A result the server refused is not a result it recorded. Read rather than
  # dropped, for the same reason the observations reply is read: an unread
  # rejection makes a run that never landed look exactly like one that did, and
  # the whole value of running the analyzer is that those two stay apart.
  defp log_analysis_reply(_source, {:ok, _}, socket), do: socket
  defp log_analysis_reply(_source, :ok, socket), do: socket

  defp log_analysis_reply(source, other, socket) do
    Logger.error("""
    [CmsHarness] the server REJECTED the #{source} result for #{socket.assigns.project.root}: #{inspect(other)}

    That analyzer ran, but nothing was recorded from it. The run is still open on
    the server, so the next stop will report analysis pending rather than clean.
    """)

    socket
  end

  # The one thing the server initiates. It owns the ledger, so it decides which
  # analyzers are stale; this machine owns the disk and the toolchain, so it
  # does the running. Handed straight to the queue — nothing runs in the socket
  # process, which holds the lease.
  @impl Slipstream
  def handle_message(_topic, "run_analysis", %{"runs" => runs}, socket) when is_list(runs) do
    Logger.info(
      "[CmsHarness] server asked for #{Enum.map_join(runs, ", ", & &1["source"])} " <>
        "on #{socket.assigns.project.root}"
    )

    AnalysisServer.enqueue(socket.assigns.project.id, runs)
    {:ok, socket}
  end

  # An event this harness does not implement is version skew, and it is named.
  # The server's own catch-all was made to reply for exactly this reason: a
  # message silently ignored on one side reads as latency on the other.
  def handle_message(_topic, event, _payload, socket) do
    Logger.warning(
      "[CmsHarness] the server sent #{inspect(event)}, which this harness does not " <>
        "implement. Nothing was done about it."
    )

    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    delay = backoff(socket.assigns.attempts)

    Logger.warning(
      "[CmsHarness] disconnected from the CodeMySpec server (#{inspect(reason)}); " <>
        "reconnecting in #{delay}ms. Hooks will refuse and file watching is stopped until then."
    )

    socket =
      socket
      |> assign(:joined, false)
      |> pause_watcher()
      |> fail_pending(:not_connected)

    if socket.assigns.refused do
      {:ok, socket}
    else
      Process.send_after(self(), :reconnect, delay)
      {:ok, update(socket, :attempts, &(&1 + 1))}
    end
  end

  @impl Slipstream
  def handle_info(:refresh_read_model, %{assigns: %{joined: true, topic: topic}} = socket) do
    schedule_read_model_refresh()

    case transport().push(socket, topic, "read_model", %{}, decision_timeout()) do
      {:ok, ref} -> {:noreply, assign(socket, :read_model_ref, ref)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info(:refresh_read_model, socket) do
    schedule_read_model_refresh()
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info(:reconnect, socket) do
    case Config.socket_url() do
      {:ok, uri} ->
        {:ok, socket} = connect(socket, uri: uri)
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:reply_timeout, ref}, socket) do
    case pop_in(socket.assigns.pending, [ref]) do
      {nil, _} ->
        {:noreply, socket}

      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :no_reply})
        {:noreply, assign(socket, :pending, pending)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Slipstream
  def handle_call(:connected?, _from, socket) do
    {:reply, socket.assigns.joined, socket}
  end

  def handle_call(:read_model, _from, socket) do
    {:reply, socket.assigns.read_model, socket}
  end

  def handle_call({:decide_hook, _hook, _payload}, _from, %{assigns: %{joined: false}} = socket) do
    # Why it is not connected, not merely that it is not.
    reason = if socket.assigns[:no_credential?], do: :no_credential, else: :not_connected
    {:reply, {:error, reason}, socket}
  end

  def handle_call({:decide_hook, hook, payload}, from, socket) do
    case push(
           socket,
           socket.assigns.topic,
           "hook_decision",
           %{"hook" => hook, "payload" => payload, "port" => local_port()},
           decision_timeout()
         ) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, decision_timeout())
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _reason} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  @impl Slipstream
  # Dropped rather than queued when the channel is not joined. A recording that
  # arrives minutes late, out of order, after the run it describes has finished,
  # is worse than an admitted gap.
  def handle_cast({:record_turn, _payload}, %{assigns: %{joined: false}} = socket) do
    {:noreply, socket}
  end

  def handle_cast({:record_turn, payload}, socket) do
    case push(socket, socket.assigns.topic, "record_turn", payload) do
      {:ok, _ref} -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_cast(:sync, %{assigns: %{joined: true, read_model: %ReadModel{} = rm}} = socket) do
    Sync.start(socket.assigns.project, rm)
    {:noreply, socket}
  end

  def handle_cast(:sync, socket), do: {:noreply, socket}

  # An empty manifest is refused by the server, and rightly — reconciling one
  # would delete every file row the project has, and over a wire "the scan
  # found nothing" and "the scan did not run" arrive as the same empty list.
  # Catching it here as well means the harness names its own bug rather than
  # reading the server's refusal as a server problem.
  def handle_cast({:observations, []}, socket) do
    Logger.error("""
    [CmsHarness] the scan of #{socket.assigns.project.root} found no files at all, so nothing was sent.

    A project with a lib/ and a test/ cannot observe nothing. This is a harness
    fault — a wrong working directory or an unreadable checkout — not an empty
    project, and sending it would have deleted every file this project has on
    the server.
    """)

    {:noreply, socket}
  end

  def handle_cast({:observations, observations}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "observations",
           %{"observations" => Enum.map(observations, &serialize_observation/1)},
           decision_timeout()
         ) do
      {:ok, ref} ->
        Logger.info(
          "[CmsHarness] sent #{length(observations)} observations for #{socket.assigns.project.root}"
        )

        # The ref is kept so the *reply* can be read. Sending used to be the end
        # of it: the server's answer landed in the generic handle_reply with
        # nothing waiting for it, was logged at debug as "unmatched reply", and
        # dropped. So a manifest the server rejected — an empty one, or one
        # naming a role it does not know — looked exactly like a manifest it
        # accepted, and the harness went on believing the project was synced.
        # That is the failure this whole design is against, sitting on the one
        # path it most matters on.
        {:noreply, assign(socket, :observations_ref, ref)}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send observations: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:analysis_result, payload}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "analysis_result",
           payload,
           decision_timeout()
         ) do
      {:ok, ref} ->
        Logger.info(
          "[CmsHarness] sent the #{payload["source"]} result for " <>
            "#{socket.assigns.project.root} (#{payload["status"]})"
        )

        {:noreply, put_in(socket.assigns.analysis_refs[ref], payload["source"])}

      {:error, reason} ->
        Logger.error(
          "[CmsHarness] could not send the #{payload["source"]} result: #{inspect(reason)}"
        )

        {:noreply, socket}
    end
  end

  # Not queued. The run this belongs to was opened on a connection that is gone,
  # and the server closes those when the socket does — so there is no row left
  # to finish. The rejoin re-runs whatever is still stale.
  def handle_cast({:analysis_result, payload}, socket) do
    Logger.error(
      "[CmsHarness] dropped the #{payload["source"]} result for " <>
        "#{socket.assigns.project.root} — not connected. It will be re-run on rejoin."
    )

    {:noreply, socket}
  end

  # Dropped, deliberately. A manifest is a statement about *now*; queueing one
  # to send after a reconnect would describe a working copy that has since
  # moved on. The rescan on rejoin is the recovery.
  def handle_cast({:observations, _observations}, socket) do
    Logger.warning(
      "[CmsHarness] dropped a manifest for #{socket.assigns.project.root} — not connected. It will be rescanned on rejoin."
    )

    {:noreply, socket}
  end

  # --- Private ---

  defp resume_watcher(socket) do
    Watcher.resume(socket.assigns.project.id)
    socket
  end

  defp pause_watcher(socket) do
    Watcher.pause(socket.assigns.project.id)
    socket
  end

  # The wire, read at call time so a test can swap it per-case. See
  # `CmsHarness.Project.Transport` for why only outbound needed a seam.
  defp transport, do: CmsHarness.Project.Transport.impl()

  defp schedule_rejoin(socket) do
    Process.send_after(self(), :reconnect, backoff(socket.assigns.attempts))
    update(socket, :attempts, &(&1 + 1))
  end

  # Every caller waiting on a reply is told the connection went, rather than
  # being left to time out. "I could not ask" should arrive as fast as the fact
  # is known.
  defp fail_pending(socket, reason) do
    Enum.each(socket.assigns.pending, fn {_ref, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    assign(socket, :pending, %{})
  end

  defp normalize_reply({:ok, payload}) when is_map(payload), do: {:ok, payload}
  defp normalize_reply({:error, _} = error), do: error

  # A bare `:ok` is an *empty* reply, and for a hook that is the most common
  # answer there is: an empty decision map means nothing blocks this stop.
  #
  # Phoenix replies `%{"status" => "ok", "response" => %{}}` and Slipstream
  # collapses an empty response to the atom. Treating that as unreadable — which
  # is what happened — turned "you may stop" into a block on every clean turn,
  # so an agent with nothing left to do could never say so. The second-pass
  # allowance meant runs still ended, but always labelled unverified, which is
  # the wrong answer arrived at by the right safety net.
  defp normalize_reply(:ok), do: {:ok, %{}}
  defp normalize_reply({:ok, :ok}), do: {:ok, %{}}
  defp normalize_reply(other), do: {:ok, other}

  defp log_unmatched_reply(ref, reply, socket) do
    Logger.debug("[CmsHarness] unmatched reply #{inspect(ref)}: #{inspect(reply)}")
    socket
  end

  defp backoff(attempts), do: Enum.at(@backoff, attempts, List.last(@backoff))

  # `story_ids` crosses as a list because a MapSet has no JSON form; the
  # harness rebuilds it. Mirrors `HarnessProjectChannel.serialize_read_model/1`.
  defp deserialize_read_model(payload) do
    %ReadModel{
      component_by_module: payload["component_by_module"] || %{},
      component_by_id: atomize_components(payload["component_by_id"] || %{}),
      story_ids: MapSet.new(payload["story_ids"] || []),
      strict?: payload["strict"] != false
    }
  end

  # `component_by_id` is only ever read for `.module_name`, by the test-alignment
  # check. Structs do not survive JSON, so what arrives is a plain map with
  # string keys; this gives it the one field its reader asks for.
  defp atomize_components(components) do
    Map.new(components, fn {id, component} ->
      {id, %{module_name: component["module_name"] || component[:module_name]}}
    end)
  end

  # Conclusions, not raw material: path, role, fingerprint, validity, owner.
  # Roughly 150 bytes a file. No file content crosses this wire — validation
  # already happened here and only its verdict travels.
  defp serialize_observation(entry) do
    %{
      "path" => entry.path,
      "role" => to_string(entry.role),
      "mtime" => entry.mtime && DateTime.to_iso8601(entry.mtime),
      "size" => entry.size,
      "fingerprint" => entry.fingerprint,
      "valid" => entry.valid,
      "validation_errors" => entry[:validation_errors],
      "component_id" => entry[:component_id],
      "story_id" => entry[:story_id]
    }
  end
end
