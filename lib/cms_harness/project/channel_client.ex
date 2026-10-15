defmodule CmsHarness.Project.ChannelClient do
  @moduledoc """
  One working copy's channel to the server. While it is joined, this harness is
  the one serving that checkout.

  **A channel rather than a series of requests, for liveness.** The server holds
  an executor slot for this working copy while the socket is open and releases
  it when the socket closes, so a harness that panics, is `docker rm -f`'d, or
  loses its network frees the copy as its socket goes — no TTL, no heartbeat, no
  clock to agree on. The in-flight analysis ledger keys off the same signal.

  Everything the harness initiates goes through here:

    * `read_model` on join — the small slice of the domain that scanning needs,
      fetched rather than inferred because the harness has no database to
      derive it from
    * `observations` — the whole manifest, never a delta
    * `analysis_started` — the commit an analyzer started on, and whether the
      tree was clean
    * `analysis_result` — what an analyzer printed, for the server to convert
      into Problems, and the commit it finished on
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

  ## A refused join keeps trying

  The server refuses a second harness on the same *working copy* (two on one
  `_build` corrupt it); two harnesses on one *project* are ordinary. The
  refusal clears when the holder exits, so this retries at the capped backoff
  and never gives up.

  See knowledge/harness/channel, "Joining".
  """

  use Slipstream

  require Logger

  alias CmsHarness.Agents.Engine
  alias CmsHarness.Agents.Liveness
  alias CmsHarness.Agents.ToolResults
  alias CmsHarness.Channel
  alias CmsHarness.Config
  alias CmsHarness.Credentials
  alias CmsHarness.HarnessConfig
  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Project.DraftBuffer
  alias CmsHarness.Project.Transport
  alias CmsHarness.Project.Watcher
  alias CmsHarness.Sync
  alias CmsHarness.WorkingCopies.Create
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Utils.MapAccess

  @backoff [1_000, 2_000, 5_000, 10_000, 30_000]

  # How long one dial has to end in a join. Slipstream times neither the
  # websocket upgrade nor the join reply, so an unanswered attempt would sit
  # forever with no disconnect to retry from. Short of Slipstream's ~60s
  # heartbeat timeout, which only starts after upgrade.
  @default_join_timeout 20_000

  # Kept in step with `CodeMySpecWeb.HarnessProjectChannel`'s copy. Bump only
  # on a change to the join payload, the `handle_in` set, or their shapes.
  # See knowledge/harness/channel, "Contract version".
  @contract_version 2

  @doc """
  The channel contract version this harness speaks.

  Public so a test can compare it against
  `CodeMySpecWeb.HarnessProjectChannel`'s copy — see that function for why the
  comparison, rather than either value, is the thing worth asserting.
  """
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  # How many refusals are reported quietly before one loud explanation; not a
  # give-up count. Spanning the backoff this is ~48s, long enough that an
  # ordinary restart handover (old channel process still holding the slot)
  # never produces the loud message.
  @refusal_retries 4

  defp join_timeout,
    do: Application.get_env(:code_my_spec, :harness_join_timeout, @default_join_timeout)

  # --- Client API ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    Slipstream.start_link(__MODULE__, project, name: Channel.via(project.root))
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
      |> assign(:refusals, 0)
      |> assign(:silences, 0)

    :ok = Liveness.subscribe()
    {:ok, socket, {:continue, :connect}}
  end

  @impl Slipstream
  def handle_continue(:connect, socket) do
    case Config.socket_url(socket.assigns.project.root) do
      {:ok, uri} ->
        # Names the address each attempt dials, so a harness aimed at the
        # wrong server is distinguishable from one being refused. Token redacted.
        Logger.info("[CmsHarness] connecting to #{redact_token(uri)}")

        {:noreply,
         socket |> connect!(uri: uri, headers: connect_headers(socket)) |> arm_join_deadline()}

      {:error, :no_credential} ->
        # Not a retry loop: waiting produces no credential.
        Logger.error("""
        [CmsHarness] no credential, so this harness is connected to nothing.

        Run `mix cms.harness.onboard` in the working copy, which records its
        deploy key in .cms_harness.json, and restart it. Until then every hook
        will refuse and no file change will be recorded.
        """)

        # Recorded so the hook path reports a missing credential rather than
        # "channel down", which sends readers to the network instead.
        {:noreply, assign(socket, :no_credential?, true)}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    project = socket.assigns.project
    browser = CmsHarness.Browser.probe(project.root)

    {:ok,
     transport().join(socket, socket.assigns.topic, %{
       "label" => Config.label(project.root),
       # Which working copy this is. `nil` on a checkout's first join: the
       # server mints one and `handle_join/3` writes it down.
       "harness_id" => project.working_copy_id,
       # Reported data, not identity: nothing resolves a harness by it.
       "root" => project.root,
       # Where the main checkout's preview answers, from the copy's own
       # config, so the web app can frame it. `nil` from every other copy.
       "preview_url" => project[:preview_url],
       # Which machine this copy is on. Reported, never created: an id the
       # server does not recognise attaches nothing. `nil` means no device
       # announced, an ordinary state.
       "device" => %{"id" => CmsHarness.Device.recorded_id()},
       # The machine's browser MCP tools, for the script catalog rather than
       # the agent's own tool list. On join because it is a machine property
       # the server needs before any agent starts. `[]` with no browser.
       "machine_tools" => browser.names,
       # Their schemas, once per join, so `tool_docs` answers without a round
       # trip to a possibly busy machine.
       "machine_tool_docs" => browser.docs,
       # Why the list is what it is: tells "no browser" from "browser would
       # not answer".
       "browser_status" => browser_status(browser.status),
       # Which OS process holds this socket, so the server can tell a rejoin
       # (same instance, may take its own registration) from a rival harness
       # on the same working copy (refused).
       "instance" => instance(),
       # Runs still in flight here. The server's join sweep closes only what
       # goes unclaimed: a dropped socket does not kill the analyzers.
       "active_runs" => AnalysisServer.in_flight(project.root),
       # The app this copy is actually running, from the harness's own
       # `state.json`. A reply or push lost to a restart or reconnect leaves the
       # server holding a stale commit; the join is where it converges. `nil`
       # when this copy never ran an app.
       "app" => CmsHarness.AppInstance.reported(project.root),
       # App verbs newer than the contract version. The server pushes one only
       # to a harness that declared it: an unknown push is logged here and
       # never answered, which would hold a promote for its whole timeout.
       "app_verbs" => ["reload_app"],
       # Lets the server name a contract mismatch outright. Absent means a
       # harness that predates the field.
       "contract_version" => @contract_version
     })}
  end

  # Flattened for the wire, with the reason attached where there is one.
  defp browser_status({:unreachable, reason}),
    do: %{"status" => "unreachable", "error" => reason}

  defp browser_status(status), do: %{"status" => to_string(status)}

  # Host as well as pid: pids are only unique per machine, and a sprite and a
  # laptop can hold checkouts that were cloned with the same id file.
  defp instance do
    {:ok, host} = :inet.gethostname()
    "#{host}:#{System.pid()}"
  end

  @impl Slipstream
  def handle_join(topic, reply, socket) do
    Logger.info("[CmsHarness] holding #{socket.assigns.project.root} — joined #{topic}")

    # `attempts` is deliberately NOT reset here: a join is not proof the
    # connection works. It resets on the read-model reply.
    # See knowledge/harness/channel, "Joining".
    install_age_keys(reply)
    ensure_join_tunnel(reply, socket.assigns.project.root)

    socket =
      socket
      |> persist_issued_identity(reply)
      |> assign(:joined, true)
      |> assign(:joined_at, System.monotonic_time(:second))
      |> assign(:refusals, 0)
      |> assign(:refused, nil)
      |> assign(:silences, 0)
      |> assign(:read_model_refused, false)

    schedule_read_model_refresh()
    schedule_preview_check()
    schedule_machine_load_check()
    report_agents_present(socket)

    for id <- Liveness.present(socket.assigns.project.root) do
      case Engine.whereis(id) do
        {:ok, pid} -> send(pid, :mailbox_ready)
        _ -> :ok
      end
    end

    # The read model first: a scan without one resolves no owners and validates
    # no specs, so it would produce a manifest that is wrong rather than late.
    case transport().push(socket, topic, "read_model", %{}, Channel.decision_timeout()) do
      {:ok, ref} ->
        socket = socket |> assign(:read_model_ref, ref) |> assign(:read_model_reason, :join)
        {:ok, ask_what_to_restore(socket, topic)}

      {:error, _} ->
        {:ok, ask_what_to_restore(socket, topic)}
    end
  end

  # So `just init-worktree` can decrypt this project's `envs/*.enc.env`.
  defp install_age_keys(%{"sops_age_keys" => [_ | _] = keys}) do
    case CmsHarness.SopsKeyring.install(keys) do
      {:ok, _added} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[CmsHarness] could not write the sops keyring (#{inspect(reason)}); new working " <>
            "copies of this project will not be able to decrypt their env files"
        )
    end
  end

  defp install_age_keys(_reply), do: :ok

  # The join reply carries the same `tunnel` an `ensure_app_running` /
  # `restart_app` push does, so a harness restart brings a main copy's
  # connector back. Reuses `tunnel_opt/1` so the two paths cannot disagree.
  defp ensure_join_tunnel(reply, root) do
    case Keyword.get(tunnel_opt(reply), :tunnel) do
      nil -> :ok
      tunnel -> CmsHarness.AppInstance.ensure_tunnel_only(root, tunnel)
    end
  end

  # The id the server issued for this working copy, written down so a restart
  # presents the same one rather than being issued a second.
  #
  # Only ever *adds* an identity. A different id from the server is logged, not
  # adopted: this copy's rows are filed under the id on disk.
  defp persist_issued_identity(socket, reply) do
    root = socket.assigns.project.root

    case {socket.assigns.project.working_copy_id, issued_id(reply)} do
      {_same, nil} ->
        socket

      {nil, issued} ->
        config = %{
          working_copy_id: issued,
          project_id: socket.assigns.project.id,
          root: root
        }

        case HarnessConfig.write(root, config) do
          :ok -> put_in(socket.assigns.project.working_copy_id, issued)
          {:error, _} -> socket
        end

      {held, issued} when held == issued ->
        socket

      {held, issued} ->
        Logger.error("""
        [CmsHarness] the server issued #{issued} for #{root}, but this working copy \
        already holds #{held}. Keeping #{held}.

        Its files and problems are filed under #{held}; adopting the new id would
        orphan them silently. One of the two records is wrong and this cannot
        tell which.
        """)

        socket
    end
  end

  defp issued_id(%{"harness_id" => id}) when is_binary(id) and id != "", do: id
  defp issued_id(_reply), do: nil

  # How often the cached read model is refetched. A copy that joins before the
  # project has stories or components would otherwise hold an empty domain all
  # session, and `validate_entry/4` would silently check nothing.
  @read_model_refresh_ms 60_000

  @doc "Public so a test can assert against the real interval rather than a copy."
  def read_model_refresh_ms, do: @read_model_refresh_ms

  defp schedule_read_model_refresh,
    do: Process.send_after(self(), :refresh_read_model, @read_model_refresh_ms)

  # Preview health has its own clock: an app crashes and recovers while nobody
  # edits a file, so tying it to the scan left it stale.
  @preview_check_ms 60_000

  @doc "Public so a test can assert against the real interval rather than a copy."
  def preview_check_ms, do: @preview_check_ms

  defp schedule_preview_check,
    do: Process.send_after(self(), :measure_preview, @preview_check_ms)

  # Machine load has its own clock too: it changes while nobody touches a file.
  @machine_load_check_ms 60_000

  @doc "Public so a test can assert against the real interval rather than a copy."
  def machine_load_check_ms, do: @machine_load_check_ms

  defp schedule_machine_load_check,
    do: Process.send_after(self(), :measure_machine_load, @machine_load_check_ms)

  # Presence: the server tracks an agent while this channel says it is up
  # (`agent_up` / `agent_down` as `Liveness` sees them). A fresh join is told
  # the whole set at once; an empty set is true, and nothing acts on absence.
  defp report_agents_present(socket) do
    transport().push(
      socket,
      socket.assigns.topic,
      "agents_present",
      %{
        "agent_ids" => Liveness.present(socket.assigns.project.root),
        # The ones its Keepers gave up on, so they stay stuck across the
        # reconnect rather than reading as starting again.
        "gave_up" => Liveness.gave_up(socket.assigns.project.root)
      },
      5_000
    )

    socket
  end

  # A join the server refused. The only one we know how to explain is a project
  # another harness holds; anything else is reported as it arrived.
  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    socket = socket |> assign(:joined, false) |> assign(:join_attempt, nil) |> pause_watcher()

    # Slipstream reports a refused join as `:failed_to_join` and a channel that
    # closed after joining as `:error`; the refusal we know how to explain can
    # arrive either way.
    case reason do
      # `project_in_use` is the older server's name for the same refusal.
      {kind, %{"reason" => reason, "held_by" => holder}}
      when kind in [:error, :failed_to_join] and
             reason in ["working_copy_in_use", "project_in_use"] ->
        {:ok, refused(socket, holder)}

      # A valid credential for a different project: the socket connects and the
      # join is refused. Logged naming the credential, which is the fix.
      {kind, %{"reason" => "unauthorized"}} when kind in [:error, :failed_to_join] ->
        {:ok, schedule_rejoin(unauthorized(socket, topic))}

      other ->
        Logger.warning("[CmsHarness] #{topic} closed: #{inspect(other)}")
        {:ok, schedule_rejoin(socket)}
    end
  end

  # Named by which credential answered, because the remedy differs and the
  # harness cannot see the project a deploy key belongs to — only the server
  # resolves that (`Projects.get_project_by_deploy_key/1`).
  defp unauthorized(socket, topic) do
    project = socket.assigns.project

    Logger.error("""
    [CmsHarness] #{topic} refused the join as unauthorized.

    #{credential_note(project)}

    The socket connected, so the credential itself is valid — a deploy key
    reaches exactly one project, and this working copy belongs to another.
    """)

    socket
  end

  defp credential_note(project) do
    case Credentials.for_working_copy(project.root) do
      {:ok, _token, :configured_deploy_key} ->
        "This harness presented its configured deploy key (`:harness_deploy_key` " <>
          "or `--deploy-key`), which is issued per project and " <>
          "belongs to whatever started the daemon. Give this copy its own:\n\n" <>
          "    cd #{project.root} && mix cms.harness.onboard\n\n" <>
          "which records the project's key in its .cms_harness.json. On a machine " <>
          "with no local database to read it from, the key is at " <>
          "<server>/app/projects/#{project.id}/edit — Generate fills the field, " <>
          "Save is what stores the hash."

      {:ok, _token, :working_copy_key} ->
        "This harness presented the deploy_key recorded in " <>
          "#{project.root}/.cms_harness.json. The server does not accept it for " <>
          "project #{project.id}, so it is the wrong key or it has been rotated — " <>
          "Save a new one and onboard this copy again."

      {:ok, _token, :user_token} ->
        "This harness presented its configured user token (`:harness_token`). A " <>
          "user token reaches every project its user can access, so a refusal " <>
          "means this user has no access to #{project.id} — or the token has " <>
          "expired, which it does silently because a configured token is never refreshed."

      {:error, :no_credential} ->
        "This harness has no credential at all for #{project.root}."
    end
  end

  # The join's read model always earns a scan: it resolves owners and validates
  # specs, so the first manifest waits for it. A 60s refresh scans only when
  # the read model changed; the watcher covers the disk.
  defp maybe_sync(socket, previous, read_model) do
    if socket.assigns[:read_model_reason] != :refresh or previous != read_model do
      Sync.start(socket.assigns.project, read_model)
    end
  end

  @impl Slipstream
  def handle_reply(ref, reply, %{assigns: %{read_model_ref: ref}} = socket) do
    socket = stamp_server_reply(socket)

    case reply do
      {:ok, payload} ->
        previous = Map.get(socket.assigns, :read_model)
        read_model = deserialize_read_model(payload)

        # The join has done what it exists for; the backoff may reset.
        # See knowledge/harness/channel, "Joining".
        socket =
          socket
          |> assign(:read_model, read_model)
          |> assign(:attempts, 0)
          |> resume_watcher()

        maybe_sync(socket, previous, read_model)
        {:ok, assign(socket, :read_model_refusals, 0)}

      # Structural, so retrying on the refresh tick cannot succeed: stop asking
      # until the next join, and say it loudly only the first time.
      {:error, %{"reason" => "unmatched topic"}} = refusal ->
        refusals = Map.get(socket.assigns, :read_model_refusals, 0)
        log_read_model_refused(socket, refusal, refusals)

        {:ok, assign(socket, read_model_refused: true, read_model_refusals: refusals + 1)}

      other ->
        Logger.error("""
        [CmsHarness] the server would not hand over the read model for #{socket.assigns.project.root}: #{inspect(other)}

        Without it the harness cannot resolve which component or story a file belongs
        to, so it is not scanning rather than scanning wrongly.
        """)

        {:ok, socket}
    end
  end

  def handle_reply(ref, reply, %{assigns: %{restore_ref: ref}} = socket) do
    socket = socket |> stamp_server_reply() |> assign(:restore_ref, nil)

    case reply do
      {:ok, %{"agents" => agents}} when is_list(agents) ->
        {:ok, socket |> assign(:restored, true) |> start_restore(agents)}

      other ->
        # Not fatal, but said out loud so agents do not silently never return.
        Logger.warning(
          "[CmsHarness] could not learn which agents to restore for " <>
            "#{socket.assigns.project.root}: #{inspect(other)}. None were started; " <>
            "anything that should be running has to be started again by hand."
        )

        {:ok, socket}
    end
  end

  def handle_reply(ref, reply, %{assigns: %{observations_ref: ref}} = socket) do
    socket = socket |> stamp_server_reply() |> assign(:observations_ref, nil)

    case reply do
      # The server reconciles after replying, so a big manifest cannot hold the
      # channel; counts are logged server-side.
      {:ok, %{"status" => "accepted", "observations" => count}} ->
        Logger.info(
          "[CmsHarness] server accepted the manifest for #{socket.assigns.project.root}: " <>
            "#{count} observations queued to reconcile"
        )

        {:ok, socket}

      # An older server's reply shape; still an acceptance.
      {:ok, %{"upserted" => upserted, "removed" => removed}} ->
        Logger.info(
          "[CmsHarness] server accepted the manifest for #{socket.assigns.project.root}: " <>
            "#{upserted} upserted, #{removed} removed"
        )

        {:ok, socket}

      # Any reply that says "accepted" was accepted, whatever else it carries:
      # a newer server's shape must never be logged as a rejection.
      {:ok, %{"status" => "accepted"} = reply} ->
        Logger.warning(
          "[CmsHarness] server accepted the manifest for #{socket.assigns.project.root}, " <>
            "in a shape this harness does not recognise: #{inspect(reply)}. The sync is " <>
            "fine; this harness is older than the server. Rebuild it to stop guessing at " <>
            "replies."
        )

        {:ok, socket}

      # A manifest that lands after the channel left its topic: ordinary
      # shutdown or reconnect, not a rejection. Its own clause so the
      # catch-all's diagnosis does not mislead.
      {:error, %{"reason" => "unmatched topic"}} ->
        Logger.info(
          "[CmsHarness] manifest for #{socket.assigns.project.root} arrived after the " <>
            "channel left its topic — the harness is shutting down or reconnecting. " <>
            "Nothing is wrong and nothing was lost; the next join re-syncs."
        )

        {:ok, socket}

      other ->
        # Loud: the server's picture of the copy now differs from the disk.
        # Names the reply and does not guess at the cause.
        Logger.error("""
        [CmsHarness] the server REJECTED the manifest for #{socket.assigns.project.root}: #{inspect(other)}

        The server's picture of this project is now out of step with the disk,
        and the requirement graph is computed from the server's picture. This is
        not "nothing changed" — the sync was refused, for the reason above.
        """)

        {:ok, socket}
    end
  end

  # The server received create_working_copy_result -- whatever it makes of it
  # from here is its own concern, but the harness now knows its reply arrived,
  # so there is nothing left for `{:create_ack_timeout, ref}` to roll back.
  def handle_reply(ref, _reply, %{assigns: %{pending_create_ack: pending}} = socket)
      when is_map_key(pending, ref) do
    {:ok, assign(socket, :pending_create_ack, Map.delete(pending, ref))}
  end

  def handle_reply(ref, reply, socket) do
    socket = stamp_server_reply(socket)

    case pop_in(socket.assigns.analysis_refs, [ref]) do
      {nil, _} ->
        handle_pending_reply(ref, reply, socket)

      {source, refs} ->
        {:ok, log_analysis_reply(source, reply, assign(socket, :analysis_refs, refs))}
    end
  end

  # Counted across rejoins and reset only by a read model handed over, so a
  # join loop logs one error, not one per join.
  defp log_read_model_refused(socket, refusal, 0) do
    Logger.error("""
    [CmsHarness] the server would not hand over the read model for #{socket.assigns.project.root}: #{inspect(refusal)}

    The topic is unmatched, so this is not retried until the next join. Without a
    read model the harness is not scanning rather than scanning wrongly.
    """)
  end

  defp log_read_model_refused(socket, refusal, refusals) do
    Logger.debug(
      "[CmsHarness] read model for #{socket.assigns.project.root} refused again " <>
        "(#{refusals + 1} in a row): #{inspect(refusal)}"
    )
  end

  defp handle_pending_reply(ref, reply, socket) do
    case pop_in(socket.assigns.pending, [ref]) do
      {nil, _} ->
        {:ok, log_unmatched_reply(ref, reply, socket)}

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, normalize_reply(reply))

        # An answered decision is the only proof the channel carries traffic.
        {:ok,
         socket
         |> assign(:pending, pending)
         |> assign(:silences, 0)
         |> maybe_rejoin(reply)}
    end
  end

  # The server says there is no channel on that topic while we believe we are
  # joined. Trust the server: drop the *socket*, not just the topic, because
  # Slipstream still thinks the topic is joined and a rejoin would be a silent
  # no-op. `handle_disconnect/2` then runs the ordinary reconnect path.
  # See knowledge/harness/channel, "Unmatched topic and silence".
  defp maybe_rejoin(socket, {:error, %{"reason" => "unmatched topic"}}) do
    Logger.warning("""
    [CmsHarness] the server has no channel for #{socket.assigns.project.root} \
    (#{socket.assigns.topic}), though this harness believed it was joined. Reconnecting. \
    Hooks refuse until it lands.\
    """)

    socket = socket |> assign(:joined, false) |> pause_watcher()

    transport().disconnect(socket)
  end

  defp maybe_rejoin(socket, _reply), do: socket

  # A result the server refused is not a result it recorded, so the reply is
  # read: a run that never landed must not look like one that did.
  defp log_analysis_reply(_source, {:ok, _}, socket), do: socket
  defp log_analysis_reply(_source, :ok, socket), do: socket

  defp log_analysis_reply(source, {:error, %{"reason" => reason}} = reply, socket)
       when is_binary(reason) do
    log_by_kind(superseded?(reason), source, reply, socket)
  end

  defp log_analysis_reply(source, other, socket), do: log_rejection(source, other, socket)

  # A supersede is a scheduling fact, not a rejection: logged at info, as the
  # server's `Reconciler.supersede/2` does. Still worth a line, since repeated
  # supersedes mean work done twice and discarded.
  defp superseded?(reason), do: String.starts_with?(reason, "{:superseded")

  defp log_by_kind(false, source, reply, socket), do: log_rejection(source, reply, socket)

  defp log_by_kind(true, source, _reply, socket) do
    Logger.info(
      "[CmsHarness] the #{source} result for #{socket.assigns.project.root} was superseded — " <>
        "another run for this source was already queued and answers for both. Nothing is " <>
        "wrong; this analyzer's work was duplicated and discarded."
    )

    socket
  end

  defp log_rejection(source, other, socket) do
    Logger.error("""
    [CmsHarness] the server REJECTED the #{source} result for #{socket.assigns.project.root}: #{inspect(other)}

    No findings were recorded from this result. Rejected analyzer payloads mark
    their run failed; a missing or otherwise unrecognized run cannot establish
    its status. Consult the rejection reason and server run ledger before retrying.
    """)

    socket
  end

  # The server owns the ledger and decides what is stale; this machine runs it.
  # Handed straight to the queue: nothing runs in the socket process.
  @impl Slipstream
  def handle_message(_topic, "run_analysis", %{"runs" => runs}, socket) when is_list(runs) do
    Logger.info(
      "[CmsHarness] server asked for #{Enum.map_join(runs, ", ", & &1["source"])} " <>
        "on #{socket.assigns.project.root}"
    )

    AnalysisServer.enqueue(socket.assigns.project.root, runs)
    {:ok, socket}
  end

  @impl Slipstream
  # This copy was offboarded on the server, so stop serving it.
  #
  # No `ref` and no reply: an offboard must not fail because the machine is
  # slow or unreachable. Stopped from another process because the subtree being
  # stopped contains this one; `Task.start/1` lets the callback return first.
  def handle_message(_topic, "offboard", _payload, socket) do
    root = socket.assigns.project.root

    Logger.info("[CmsHarness] server offboarded #{root} — releasing its channel and watchers")

    # The copy's own app and cloned database are disposable artifacts, unlike
    # the user's checkout. Discard first, in one task: stopping the copy takes
    # its app with it, and a discard that lost that race never dropped the
    # database. Best-effort; nothing here holds up the offboard.
    Task.start(fn ->
      CmsHarness.AppInstance.discard(root)
      CmsHarness.Projects.stop_serving(root)
    end)

    {:ok, socket}
  end

  # A message sent now to a busy agent: stop its turn so the message is the
  # next one. Off this process, because stopping waits on the
  # agent's turn to shut down and this one carries every hook and report.
  def handle_message(_topic, "interrupt_turn", %{"agent_id" => agent_id}, socket) do
    Task.Supervisor.start_child(Sync.task_supervisor(socket.assigns.project.root), fn ->
      CmsHarness.Agents.interrupt(agent_id)
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "cancel_analysis", payload, socket) do
    root = socket.assigns.project.root
    reason = Map.get(payload, "reason") || "cancelled by the server"
    AnalysisServer.cancel(root, reason)
    {:ok, socket}
  end

  # The server asking for a fresh manifest. Through `request_sync/1`, the same
  # entry point the watcher uses, so a server-triggered scan and a
  # write-triggered scan are the same scan.
  def handle_message(_topic, "rescan", _payload, socket) do
    Logger.info("[CmsHarness] server asked for a rescan of #{socket.assigns.project.root}")

    Channel.request_sync(socket.assigns.project.root)
    {:ok, socket}
  end

  # Promotion's disk work, on the borrowed disk like `fs_request`, but answered
  # from a task (a build takes minutes and this process carries every hook
  # decision) and against a root named in the payload, checked against the
  # roots this harness serves.
  # See knowledge/harness/channel, "Server-initiated work".
  def handle_message(
        _topic,
        "fs_request",
        %{"ref" => ref, "op" => "promotion_" <> _ = op} = msg,
        socket
      ) do
    payload = msg["payload"] || %{}
    topic = socket.assigns.topic
    client = self()

    Task.Supervisor.start_child(Sync.task_supervisor(socket.assigns.project.root), fn ->
      GenServer.cast(client, {:promotion_result, topic, ref, apply_promotion(op, payload)})
    end)

    {:ok, socket}
  end

  # A filesystem operation the server cannot perform, scoped to this channel's
  # own root, applied with the same `Environments` API and answered inline.
  def handle_message(_topic, "fs_request", %{"ref" => ref, "op" => op} = msg, socket) do
    payload = msg["payload"] || %{}
    env = Environment.new(:local, socket.assigns.project.root)

    result = apply_fs(env, op, payload)

    push(socket, socket.assigns.topic, "fs_result", Map.put(encode_fs_result(result), "ref", ref))

    {:ok, socket}
  end

  # Make a checkout on this machine: the file half happens here, the record
  # half on the server. Answered from a task so a new checkout does not stall
  # this copy's reports and manifests.
  def handle_message(_topic, "create_working_copy", %{"ref" => ref} = msg, socket) do
    topic = socket.assigns.topic
    parent = self()
    root = socket.assigns.project.root

    Task.start(fn ->
      result = Create.run(root, msg)

      send(parent, {:create_working_copy_result, topic, ref, root, result})
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "start_agent", %{"ref" => ref} = msg, socket) do
    parent = self()
    topic = socket.assigns.topic
    id = msg["agent_id"]
    launching = socket.assigns[:launching] || %{}

    if Map.has_key?(launching, id) do
      push(
        socket,
        topic,
        "agent_start_result",
        Map.put(encode_start_result({:error, :already_starting}), "ref", ref)
      )

      {:ok, socket}
    else
      # Engine registration calls back through this channel. Never block the
      # channel waiting for init, or neither half can complete the handshake.
      Task.start(fn ->
        result = CmsHarness.Agents.launch(msg)
        send(parent, {:agent_start_result, topic, ref, id, result})
      end)

      {:ok, assign(socket, :launching, Map.put(launching, id, []))}
    end
  end

  # Hand an agent a message and say what became of it, without waiting for the
  # turn.
  #
  # The engine must obtain a durable consumption acknowledgement through this
  # channel, so keep the channel free while waiting for it.
  def handle_message(topic, "mailbox_delivery", %{"ref" => ref} = msg, socket) do
    root = socket.assigns.project.root
    parent = self()

    Task.Supervisor.start_child(Sync.task_supervisor(root), fn ->
      result = CmsHarness.Agents.send_message(msg["agent_id"], msg["message_ref"], msg["message"])
      send(parent, {:mailbox_send_result, topic, ref, result})
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "request_work_turn", %{"ref" => ref} = msg, socket) do
    result =
      CmsHarness.Agents.request_work_turn(
        msg["agent_id"],
        msg["message_ref"],
        msg["message"]
      )

    push(
      socket,
      socket.assigns.topic,
      "agent_send_result",
      Map.put(encode_send_result(result), "ref", ref)
    )

    {:ok, socket}
  end

  def handle_message(_topic, "stop_agent", %{"ref" => ref} = msg, socket),
    do: {:ok, stop_or_hold(socket, msg["agent_id"], ref)}

  # Bring this copy's own app up, restart it, or stop it. Answered from a task:
  # a first start can clone a database, which would stall this channel.
  def handle_message(_topic, "ensure_app_running", %{"ref" => ref} = msg, socket) do
    dispatch_app_call(socket, ref, "ensure_app_running_result", fn ->
      CmsHarness.AppInstance.ensure_running(
        socket.assigns.project.root,
        [main?: msg["main"] == true] ++ tunnel_opt(msg)
      )
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "restart_app", %{"ref" => ref} = msg, socket) do
    dispatch_app_call(socket, ref, "restart_app_result", fn ->
      CmsHarness.AppInstance.restart(
        socket.assigns.project.root,
        [main?: msg["main"] == true] ++ tunnel_opt(msg)
      )
    end)

    {:ok, socket}
  end

  # A promote's default: reload main's app in place rather than restart it.
  # Answers `reload_app_result`; `AppInstance.reload/2` restarts instead when
  # it cannot reload, and says so.
  def handle_message(_topic, "reload_app", %{"ref" => ref} = msg, socket) do
    dispatch_app_call(socket, ref, "reload_app_result", fn ->
      CmsHarness.AppInstance.reload(
        socket.assigns.project.root,
        [main?: msg["main"] == true] ++ tunnel_opt(msg)
      )
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "stop_app", %{"ref" => ref}, socket) do
    dispatch_app_call(socket, ref, "stop_app_result", fn ->
      CmsHarness.AppInstance.stop_app(socket.assigns.project.root)
    end)

    {:ok, socket}
  end

  # A script on the server asked for a tool on this machine (the browser).
  # Answered from a task: the caller sets the deadline, and a long browser wait
  # inline would stall this copy's traffic and miss heartbeats.
  def handle_message(_topic, "tool_call", %{"ref" => ref} = msg, socket) do
    topic = socket.assigns.topic
    root = socket.assigns.project.root
    parent = self()

    Task.start(fn ->
      result = CmsHarness.Browser.call(root, msg["tool"], msg["arguments"] || %{}, msg["timeout"])

      send(parent, {:tool_call_result, topic, ref, result})
    end)

    {:ok, socket}
  end

  # An event this harness does not implement is version skew, and it is named.
  def handle_message(_topic, event, _payload, socket) do
    Logger.warning(
      "[CmsHarness] the server sent #{inspect(event)}, which this harness does not " <>
        "implement. Nothing was done about it."
    )

    {:ok, socket}
  end

  # Supervised, not a bare `Task.start`: an unsupervised, unlinked task has
  # nothing tracking it once spawned, which is exactly the shape of defect
  # 9839ae69 names elsewhere in this project's own test suite -- here it is
  # production code instead. `ensure_app_running`/`restart_app`/`reload_app`/
  # `stop_app` all answer through this, and the project's own `Task.Supervisor`
  # (started beside this channel under `Project.Supervisor`) already exists
  # for exactly this, the same one `Sync.start/2` and the analysis server use.
  defp dispatch_app_call(socket, ref, event, fun) do
    topic = socket.assigns.topic
    root = socket.assigns.project.root
    parent = self()

    Task.Supervisor.start_child(Sync.task_supervisor(root), fn ->
      send(parent, {:app_call_result, topic, ref, event, fun.()})
    end)
  end

  # `msg["tunnel"]` carries main's own credentials exactly when
  # `HarnessProjectChannel.put_tunnel/2` decided this copy holds one. Converted
  # to the atom-keyed shape `AppInstance.Runner` expects, so nothing downstream
  # touches a string key.
  defp tunnel_opt(%{
         "tunnel" => %{"hostname" => h, "tunnel_id" => id, "tunnel_secret" => secret} = t
       })
       when is_binary(h) and is_binary(id) and is_binary(secret) do
    [
      tunnel: %{
        hostname: h,
        tunnel_id: id,
        tunnel_secret: secret,
        account_tag: t["account_tag"] || ""
      }
    ]
  end

  defp tunnel_opt(_msg), do: []

  # An error stays an error across the wire, distinct from a text answer.
  defp encode_tool_result({:ok, text}), do: %{"text" => text}
  defp encode_tool_result({:error, reason}), do: %{"error" => to_string_reason(reason)}

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)

  # One clause per named operation, and deliberately no general `cmd`: analysis
  # owns command execution here. App restarts go through the app verbs.
  defp apply_promotion("promotion_precheck", %{"root" => root} = payload),
    do: with_served_root(root, &Steps.precheck(Environment.new(:local, &1), &1, payload["main"]))

  defp apply_promotion("promotion_current", %{"root" => root}),
    do: with_served_root(root, &Steps.current(Environment.new(:local, &1), &1))

  defp apply_promotion("promotion_merge", %{"root" => root, "branch" => branch}),
    do: with_served_root(root, &Steps.merge(Environment.new(:local, &1), &1, branch))

  defp apply_promotion(
         "promotion_build_batch",
         %{"root" => root, "base" => base, "commits" => commits}
       )
       when is_list(commits),
       do:
         with_served_root(
           root,
           &Steps.build_batch(Environment.new(:local, &1), &1, base, commits)
         )

  defp apply_promotion(
         "promotion_contained",
         %{"root" => root, "base" => base, "commits" => commits}
       )
       when is_list(commits),
       do:
         with_served_root(
           root,
           &Steps.contained(Environment.new(:local, &1), &1, base, commits)
         )

  # Healed like an analyzer run: a candidate that moves `mix.lock` leaves the
  # gate's `deps/` stale, and mix refuses every command until something fetches.
  defp apply_promotion("promotion_reset_test_databases", %{"root" => root}),
    do: with_served_root(root, &reset_test_databases/1)

  # The gate's asset build, healed for stale deps the same way.
  defp apply_promotion("promotion_build_assets", %{"root" => root}),
    do: with_served_root(root, &build_assets/1)

  defp apply_promotion("promotion_changed", %{"root" => root, "from" => from, "to" => to}),
    do: with_served_root(root, &Steps.changed(Environment.new(:local, &1), &1, from, to))

  defp apply_promotion("promotion_submodule", %{"root" => root, "source" => source} = payload) do
    merge = %{
      before: payload["before"],
      after: payload["after"],
      version: payload["version"]
    }

    with_served_root(root, fn root ->
      with_served_root(
        source,
        &Steps.sync_submodule(Environment.new(:local, root), root, &1, merge)
      )
    end)
  end

  defp apply_promotion(op, _payload),
    do: {:error, %{reason: "this harness does not implement #{op}"}}

  defp reset_test_databases(root) do
    env = Environment.new(:local, root)

    reset = fn ->
      Steps.reset_test_databases(env, root, CmsHarness.TestDatabase.partitions(root))
    end

    env
    |> CmsHarness.Analysis.heal(fn -> reset_as_text(reset.()) end)
    |> reset_as_map()
  end

  defp build_assets(root) do
    env = Environment.new(:local, root)

    env
    |> CmsHarness.Analysis.heal(fn -> reset_as_text(Steps.build_assets(env, root)) end)
    |> reset_as_map()
  end

  defp reset_as_text({:error, %{reason: reason}}), do: {:error, reason}
  defp reset_as_text(result), do: result

  defp reset_as_map({:error, reason}) when is_binary(reason), do: {:error, %{reason: reason}}
  defp reset_as_map(result), do: result

  # A root this harness does not serve is refused: the server may name the
  # running copy's path, not any path on this machine.
  defp with_served_root(root, fun) do
    if root in CmsHarness.Projects.list() do
      fun.(root)
    else
      {:error,
       %{
         reason:
           "this machine does not serve a working copy at #{root}, so it will not " <>
             "run a promotion there."
       }}
    end
  end

  defp apply_fs(env, "read_file", %{"path" => p}), do: CodeMySpec.Environments.read_file(env, p)

  defp apply_fs(env, "write_file", %{"path" => p, "content" => c}),
    do: CodeMySpec.Environments.write_file(env, p, c)

  defp apply_fs(env, "delete_file", %{"path" => p}),
    do: CodeMySpec.Environments.delete_file(env, p)

  defp apply_fs(env, "list_directory", %{"path" => p}),
    do: CodeMySpec.Environments.list_directory(env, p)

  defp apply_fs(env, "ensure_dir", %{"path" => p}), do: CodeMySpec.Environments.ensure_dir(env, p)
  defp apply_fs(env, "stat", %{"path" => p}), do: CodeMySpec.Environments.stat(env, p)
  defp apply_fs(env, "glob", %{"pattern" => p}), do: {:ok, CodeMySpec.Environments.glob(env, p)}

  # An unknown op is an error, not silence: the server is waiting on a reply.
  defp apply_fs(_env, op, _payload), do: {:error, :"unsupported_fs_op_#{op}"}

  @doc """
  Public only so a test can feed it a result `CmsHarness.Agents.launch/1`
  actually produced.
  """
  def encode_start_result({:ok, %{agent_id: agent_id}}),
    do: %{"status" => "ok", "agent_id" => agent_id}

  def encode_start_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  # Once per harness process: a reconnect loses no agent, and every ask writes a
  # "harness restarted" notice into each agent's thread.
  defp ask_what_to_restore(%{assigns: %{restored: true}} = socket, _topic), do: socket

  defp ask_what_to_restore(socket, topic) do
    case transport().push(socket, topic, "agents_to_restore", %{}, Channel.decision_timeout()) do
      {:ok, ref} -> assign(socket, :restore_ref, ref)
      {:error, _} -> socket
    end
  end

  # One at a time, so a restore cannot stampede the box. Off this process: a
  # launch waits on the agent's MCP session, and inline it held every
  # `stop_agent` behind the restore. This process owns the queue and the task
  # asks for the next agent, so a stop can remove one before it launches.
  defp start_restore(socket, []), do: socket

  defp start_restore(socket, agents) do
    client = self()
    {:ok, _task} = Task.start_link(fn -> run_restore(client) end)
    assign(socket, :restore_queue, agents)
  end

  defp run_restore(client) do
    case GenServer.call(client, :next_restore, :infinity) do
      {:launch, agent} ->
        restore_one(agent)
        run_restore(client)

      :done ->
        :ok
    end
  end

  defp restore_one(agent) do
    case CmsHarness.Agents.launch(agent) do
      {:ok, _} ->
        Logger.info("[CmsHarness] restored agent #{agent["agent_id"]}")

      {:error, reason} ->
        Logger.warning(
          "[CmsHarness] could not restore agent #{agent["agent_id"]} in " <>
            "#{agent["working_copy"]}: #{inspect(reason)}"
        )
    end
  end

  # A stop for the agent being launched waits for that launch, then stops it.
  # One still queued is dropped and answered stopped: it never runs.
  defp stop_or_hold(%{assigns: %{restoring: id}} = socket, id, ref) when is_binary(id),
    do: assign(socket, :held_stops, [ref | socket.assigns[:held_stops] || []])

  defp stop_or_hold(socket, agent_id, ref) do
    launching = socket.assigns[:launching] || %{}

    case Map.fetch(launching, agent_id) do
      {:ok, refs} -> assign(socket, :launching, Map.put(launching, agent_id, [ref | refs]))
      :error -> stop_unlaunched(socket, agent_id, ref)
    end
  end

  defp stop_unlaunched(socket, agent_id, ref) do
    queue = socket.assigns[:restore_queue] || []

    case Enum.split_with(queue, &(&1["agent_id"] == agent_id)) do
      {[_queued | _], rest} ->
        socket |> assign(:restore_queue, rest) |> push_stop_result(ref, :ok)

      {[], _queue} ->
        push_stop_result(socket, ref, CmsHarness.Agents.halt(agent_id))
    end
  end

  # The task asking again means the last launch returned.
  defp stop_held(%{assigns: %{restoring: id}} = socket) when is_binary(id) do
    socket =
      case socket.assigns[:held_stops] || [] do
        [] ->
          socket

        refs ->
          result = CmsHarness.Agents.halt(id)
          Enum.reduce(refs, socket, &push_stop_result(&2, &1, result))
      end

    assign(socket, restoring: nil, held_stops: [])
  end

  defp stop_held(socket), do: socket

  defp push_stop_result(socket, ref, result) do
    transport().push(
      socket,
      socket.assigns.topic,
      "agent_stop_result",
      Map.put(encode_stop_result(result), "ref", ref),
      5_000
    )

    socket
  end

  defp push_liveness(socket, :up, agent_id, _reason),
    do:
      transport().push(socket, socket.assigns.topic, "agent_up", %{"agent_id" => agent_id}, 5_000)

  defp push_liveness(socket, :down, agent_id, reason),
    do: push_down(socket, agent_id, inspect(reason))

  # Its Keeper gave up on a crash loop: the one down the server acts on.
  defp push_liveness(socket, :gave_up, agent_id, reason),
    do: push_down(socket, agent_id, "gave_up: " <> inspect(reason))

  defp push_down(socket, agent_id, reason) do
    transport().push(
      socket,
      socket.assigns.topic,
      "agent_down",
      %{"agent_id" => agent_id, "reason" => reason},
      5_000
    )
  end

  # Atoms and strings keep their shape; anything else is inspected rather than
  # crashing the channel reporting it.
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: to_string(reason)
  defp reason_text(%{error: error}) when is_binary(error), do: error
  defp reason_text(reason), do: inspect(reason)

  @doc """
  One Alloy turn event, as it goes on the wire.

  Only what a watcher needs, and only things that survive JSON; the envelope
  itself carries atoms, pids and the whole turn state.

  Public because it is the wire shape: anything else producing one must use
  this rather than a copy that drifts.
  """
  @spec encode_turn_event(map()) :: map()
  def encode_turn_event(%{event: :compacted} = envelope) do
    # Not a step and not text: what survived a compaction is kept as messages,
    # not flattened into `"text"`.
    %{
      "kind" => "compacted",
      "turn" => Map.get(envelope, :turn),
      "messages" => Map.get(envelope, :messages, [])
    }
  end

  def encode_turn_event(envelope) do
    %{
      "kind" => to_string(Map.get(envelope, :event, "step")),
      "seq" => Map.get(envelope, :seq),
      "turn" => Map.get(envelope, :turn),
      # Turn boundaries carry the durable identity and owning engine generation.
      "ref" => Map.get(envelope, :ref),
      "generation" => Map.get(envelope, :generation),
      "text" => turn_event_text(envelope),
      # The call as data beside the prose in `text`: edits are attributed
      # from it, and the page renders it as a tool call.
      "tool" => tool_meta(envelope),
      # What the turn cost, on `turn_ended` only.
      "usage" => usage_meta(Map.get(envelope, :usage))
    }
  end

  defp usage_meta(%{} = usage), do: Map.new(usage, fn {key, value} -> {to_string(key), value} end)
  defp usage_meta(_usage), do: nil

  # The whole call, untruncated: this is the conversation a restart resumes
  # from.
  defp tool_meta(%{payload: %{name: name} = payload}) when is_binary(name) do
    %{
      "id" => Map.get(payload, :id),
      "name" => name,
      "path" => touched_path(Map.get(payload, :input)),
      "input" => Map.get(payload, :input) || %{},
      "result" => result_text(Map.get(payload, :result)),
      "error" => error_text(Map.get(payload, :error))
    }
  end

  defp tool_meta(_envelope), do: nil

  # The path a call names, when it names one. Narrower than
  # `primary_argument/1`: a non-path here would be recorded as an edited file.
  # String and atom keys both, for the reason given on `@naming_arguments`.
  defp touched_path(input) when is_map(input) do
    Enum.find_value([{"file_path", :file_path}, {"path", :path}], fn {string_key, atom_key} ->
      case Map.get(input, string_key) || Map.get(input, atom_key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp touched_path(_input), do: nil

  # What a call returned, as text. Absent on `tool_start`; text or content
  # blocks on `tool_end`, and an error struct when a tool failed without words.
  defp result_text(nil), do: nil
  defp result_text(text) when is_binary(text), do: text

  defp result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{type: "text", text: text} -> text
      %{type: "image"} -> "← image"
      other -> inspect(other)
    end)
  end

  defp result_text(other), do: ToolResults.describe(other)

  defp error_text(nil), do: nil
  defp error_text(error), do: ToolResults.describe(error)

  defp turn_event_text(envelope) do
    case envelope do
      %{name: name} when is_binary(name) ->
        name

      %{text: text} when is_binary(text) ->
        text

      %{content: content} when is_binary(content) ->
        content

      %{payload: %{name: name} = payload} when is_binary(name) ->
        tool_text(name, payload)

      # What the model said alongside the calls it asked for (`:assistant_message`).
      %{payload: %{text: text}} when is_binary(text) ->
        text

      # `ref` and `generation` travel as their own fields (above); left in, a
      # turn boundary read as `%{ref: ..., generation: ...}` in the transcript.
      other ->
        other
        |> Map.drop([:v, :seq, :turn, :correlation_id, :event, :ref, :generation])
        |> inspect_rest()
    end
  end

  # Nothing left once bookkeeping is dropped (e.g. `turn_started`) is `nil`,
  # which the server skips, not the text `%{}`.
  defp inspect_rest(rest) when map_size(rest) == 0, do: nil
  defp inspect_rest(rest), do: inspect(rest)

  @draft_flush_ms 100

  defp schedule_draft_flush(%{assigns: %{draft_flush: ref}} = socket) when ref != nil, do: socket

  defp schedule_draft_flush(socket),
    do: assign(socket, :draft_flush, Process.send_after(self(), :flush_drafts, @draft_flush_ms))

  defp drafts(socket), do: Map.get(socket.assigns, :drafts, DraftBuffer.new())

  # A tool call, as a person would say it: `read mix.exs`.
  defp tool_text(name, payload) do
    case primary_argument(Map.get(payload, :input)) do
      nil -> name
      argument -> "#{name} #{argument}"
    end
  end

  # The one argument worth putting beside the tool's name; the rest is left off.
  # String and atom keys both (arguments arrive decoded from JSON on one path,
  # built in memory on another), written out rather than derived with
  # `String.to_existing_atom/1`, which can raise inside a reporter.
  @naming_arguments [
    {"file_path", :file_path},
    {"path", :path},
    {"command", :command},
    {"pattern", :pattern},
    {"query", :query},
    {"url", :url}
  ]

  defp primary_argument(input) when is_map(input) do
    Enum.find_value(@naming_arguments, fn {string_key, atom_key} ->
      case Map.get(input, string_key) || Map.get(input, atom_key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp primary_argument(_input), do: nil

  defp encode_send_result({:ok, :started}),
    do: %{"status" => "ok", "disposition" => "started"}

  defp encode_send_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  defp encode_create_result({:ok, %{root: root, working_copy_id: id}}),
    do: %{"status" => "ok", "root" => root, "working_copy_id" => id}

  defp encode_create_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  defp encode_stop_result(:ok), do: %{"status" => "ok"}

  defp encode_stop_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  # Absent fields are omitted rather than sent as `nil`: the server's
  # `decode_app_result/1` reads absence as "unchanged".
  defp encode_app_result({:ok, %{status: status} = info}) do
    %{"status" => "ok", "app_status" => status}
    |> maybe_put("app_url", Map.get(info, :url))
    |> maybe_put("app_commit", Map.get(info, :commit))
    |> maybe_put("app_serving_commit", Map.get(info, :serving_commit))
    |> maybe_put("app_head", Map.get(info, :head))
    |> maybe_put("app_action", Map.get(info, :action))
    |> maybe_put("app_action_reason", Map.get(info, :action_reason))
  end

  defp encode_app_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # `HarnessProjectChannel.decode_fs_result/1` turns these back into atoms
  # from a fixed list; the round trip is pinned in `FsResultReasonTest`.
  @doc false
  def encode_fs_result(:ok), do: %{"ok" => true}
  # Bytes that are not text travel as base64; raw binary in the JSON reply
  # crashes the channel. `decode_fs_result/1` on the server reverses it.
  def encode_fs_result({:ok, result}) when is_binary(result) do
    if String.valid?(result),
      do: %{"ok" => true, "result" => result},
      else: %{"ok" => true, "result_base64" => Base.encode64(result)}
  end

  def encode_fs_result({:ok, result}), do: %{"ok" => true, "result" => result}
  # A refusal with structure keeps it. A promotion fails with a map of
  # evidence; `to_string/1` on it raises and takes the channel down.
  def encode_fs_result({:error, %{} = reason}), do: %{"error" => stringify_keys(reason)}
  def encode_fs_result({:error, reason}), do: %{"error" => to_string(reason)}

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # `token=` runs to the next `&` or the end of the query string — `vsn`
  # follows it today, but nothing here should assume it always will.
  defp redact_token(uri), do: String.replace(uri, ~r/token=[^&]*/, "token=[redacted]")

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
      |> assign(:join_attempt, nil)
      |> pause_watcher()
      |> fail_pending(:not_connected)

    # Always reschedule, `refused` or not: a refusal clears when the holder
    # exits. `:refused` only tells the health endpoint why nothing is served.
    Process.send_after(self(), :reconnect, delay)
    {:ok, update(socket, :attempts, &(&1 + 1))}
  end

  @impl Slipstream
  # The startup result, handed back by the task that launched the engine.
  # Pushed from here rather than from that task, because this process owns the
  # socket.
  def handle_info({:agent_start_result, topic, ref, id, result}, socket) do
    transport().push(
      socket,
      topic,
      "agent_start_result",
      Map.put(encode_start_result(result), "ref", ref),
      5_000
    )

    {stops, launching} = Map.pop(socket.assigns[:launching] || %{}, id, [])
    socket = assign(socket, :launching, launching)

    socket =
      case stops do
        [] ->
          socket

        refs ->
          stopped = CmsHarness.Agents.halt(id)
          Enum.reduce(refs, socket, &push_stop_result(&2, &1, stopped))
      end

    {:noreply, socket}
  end

  def handle_info({:mailbox_send_result, topic, ref, result}, socket) do
    transport().push(
      socket,
      topic,
      "agent_send_result",
      Map.put(encode_send_result(result), "ref", ref),
      5_000
    )

    {:noreply, socket}
  end

  # 68d37919: pushed with a tracked native reply instead of a bare `push/3`,
  # so a create this call actually made (never a failed one -- nothing to
  # roll back there) can be undone if the server never acknowledges having
  # received it. The `pending_create_ack` clause of `handle_reply/3` below
  # clears this the moment the ack arrives; `handle_info({:create_ack_timeout,
  # ...})` is what fires if it never does.
  def handle_info({:create_working_copy_result, topic, ref, root, result}, socket) do
    payload = Map.put(encode_create_result(result), "ref", ref)
    timeout = Channel.create_ack_timeout()

    case transport().push(socket, topic, "create_working_copy_result", payload, timeout) do
      {:ok, native_ref} ->
        Process.send_after(self(), {:create_ack_timeout, native_ref}, timeout)
        {:noreply, remember_create_ack(socket, native_ref, root, result)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # The ack for a create_working_copy_result never arrived within
  # Channel.create_ack_timeout/0. Still pending means it genuinely never
  # came (handle_reply's own clause would have cleared it otherwise); roll
  # back what this call made, if nothing has touched it since.
  def handle_info({:create_ack_timeout, native_ref}, socket) do
    case Map.pop(socket.assigns[:pending_create_ack] || %{}, native_ref) do
      {nil, _pending} ->
        {:noreply, socket}

      {{root, target, base_head}, pending} ->
        Create.rollback_if_untouched(root, target, base_head)
        {:noreply, assign(socket, :pending_create_ack, pending)}
    end
  end

  def handle_info({:tool_call_result, topic, ref, result}, socket) do
    push(socket, topic, "tool_call_result", Map.put(encode_tool_result(result), "ref", ref))

    {:noreply, socket}
  end

  def handle_info({:app_call_result, topic, ref, "stop_app_result" = event, result}, socket) do
    push(socket, topic, event, Map.put(encode_stop_result(result), "ref", ref))
    {:noreply, socket}
  end

  def handle_info({:app_call_result, topic, ref, event, result}, socket) do
    push(socket, topic, event, Map.put(encode_app_result(result), "ref", ref))
    {:noreply, socket}
  end

  # Refused as unmatched on this join: the timer chain ends here, and the next
  # join starts a fresh one.
  def handle_info(:refresh_read_model, %{assigns: %{read_model_refused: true}} = socket),
    do: {:noreply, socket}

  def handle_info(:refresh_read_model, %{assigns: %{joined: true, topic: topic}} = socket) do
    schedule_read_model_refresh()

    case transport().push(socket, topic, "read_model", %{}, Channel.decision_timeout()) do
      {:ok, ref} ->
        {:noreply, socket |> assign(:read_model_ref, ref) |> assign(:read_model_reason, :refresh)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info(:refresh_read_model, socket) do
    schedule_read_model_refresh()
    {:noreply, socket}
  end

  # In a task, never inline: the measurement is a `curl` with a five-second
  # timeout, and this process carries hook decisions and analyzer replies.
  def handle_info(:measure_preview, %{assigns: %{joined: true}} = socket) do
    schedule_preview_check()
    root = socket.assigns.project.root

    Task.Supervisor.start_child(Sync.task_supervisor(root), fn ->
      Sync.measure_checkout(root)
    end)

    {:noreply, socket}
  end

  def handle_info(:measure_preview, socket) do
    schedule_preview_check()
    {:noreply, socket}
  end

  # In a task for the same reason as `:measure_preview`: it shells out.
  def handle_info(:measure_machine_load, %{assigns: %{joined: true}} = socket) do
    schedule_machine_load_check()
    root = socket.assigns.project.root

    Task.Supervisor.start_child(Sync.task_supervisor(root), fn ->
      Sync.measure_machine_load(root)
    end)

    {:noreply, socket}
  end

  def handle_info(:measure_machine_load, socket) do
    schedule_machine_load_check()
    {:noreply, socket}
  end

  # An agent in this copy came up or went down (`Liveness`). Another copy's
  # agent is its own channel's to report; while not joined, the next join's
  # `agents_present` carries the set.
  @impl Slipstream
  def handle_info({:agent_liveness, kind, agent_id, root, reason}, socket) do
    if socket.assigns.joined and Path.expand(socket.assigns.project.root) == root,
      do: push_liveness(socket, kind, agent_id, reason)

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info(:reconnect, socket) do
    case Config.socket_url(socket.assigns.project.root) do
      {:ok, uri} ->
        {:ok, socket} = connect(socket, uri: uri, headers: connect_headers(socket))
        {:noreply, arm_join_deadline(socket)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # A dial that has not joined by now never will: neither the upgrade nor the
  # join reply has a timeout of its own. Only the current attempt's deadline
  # counts; one from an attempt that already ended is stale.
  def handle_info({:join_deadline, ref}, %{assigns: %{joined: false, join_attempt: ref}} = socket)
      when is_reference(ref) do
    Logger.warning(
      "[CmsHarness] #{socket.assigns.project.root} did not join #{socket.assigns.topic} " <>
        "within #{join_timeout()}ms of dialing (#{dial_stage(socket)}); dropping the " <>
        "attempt and reconnecting."
    )

    {:noreply, abandon_dial(socket)}
  end

  def handle_info({:join_deadline, _ref}, socket), do: {:noreply, socket}

  def handle_info({:reply_timeout, ref}, socket) do
    case pop_in(socket.assigns.pending, [ref]) do
      {nil, _} ->
        {:noreply, socket}

      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :no_reply})

        socket
        |> assign(:pending, pending)
        |> update(:silences, &(&1 + 1))
        |> drop_socket_if_silent()
    end
  end

  def handle_info(:flush_drafts, %{assigns: %{joined: true}} = socket) do
    {payloads, drafts} = DraftBuffer.take(drafts(socket))
    Enum.each(payloads, &push(socket, socket.assigns.topic, "agent_draft", &1))
    {:noreply, socket |> assign(:drafts, drafts) |> assign(:draft_flush, nil)}
  end

  def handle_info(:flush_drafts, socket),
    do: {:noreply, socket |> assign(:drafts, DraftBuffer.new()) |> assign(:draft_flush, nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Consecutive hook decisions the server never answered. One is a slow server;
  # two with nothing answered between is a channel carrying no traffic, which
  # nothing else will report. The silence twin of `maybe_rejoin/2`.
  # See knowledge/harness/channel, "Unmatched topic and silence".
  @silence_limit 2

  # Drops the socket rather than rejoining the topic, for the reason
  # `maybe_rejoin/2` sets out: with `join_status` still joined locally,
  # `Slipstream.join/3` is a silent no-op. Cost of being wrong is one reconnect.
  defp drop_socket_if_silent(socket) do
    if socket.assigns.silences >= @silence_limit do
      Logger.warning("""
      [CmsHarness] #{socket.assigns.silences} hook decisions in a row went unanswered for \
      #{socket.assigns.project.root}, though this harness believed it was joined. The channel \
      is not carrying traffic. Reconnecting; hooks refuse until it lands.\
      """)

      socket = socket |> assign(:joined, false) |> assign(:silences, 0) |> pause_watcher()

      {:noreply, transport().disconnect(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl Slipstream
  def handle_call(:next_restore, _from, socket) do
    socket = stop_held(socket)

    case socket.assigns[:restore_queue] do
      [agent | rest] ->
        {:reply, {:launch, agent},
         assign(socket, restore_queue: rest, restoring: agent["agent_id"])}

      _done ->
        {:reply, :done, socket |> assign(:restore_queue, nil)}
    end
  end

  def handle_call(:connected?, _from, socket) do
    {:reply, socket.assigns.joined, socket}
  end

  # Seconds since the server last answered anything, or nil if it never has.
  # Evidence rather than `joined`, which is only this process's belief.
  # Recorded passively on existing replies, so asking cannot hang.
  def handle_call(:server_replied_ago, _from, socket) do
    ago =
      case socket.assigns[:last_server_reply_at] do
        at when is_integer(at) -> System.monotonic_time(:second) - at
        _ -> nil
      end

    {:reply, ago, socket}
  end

  def handle_call(:joined_ago, _from, socket) do
    ago =
      case {socket.assigns.joined, socket.assigns[:joined_at]} do
        {true, at} when is_integer(at) -> System.monotonic_time(:second) - at
        _ -> nil
      end

    {:reply, ago, socket}
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
           %{"hook" => hook, "payload" => payload, "port" => Config.local_port()},
           Channel.decision_timeout()
         ) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, Channel.decision_timeout())
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _reason} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  def handle_call({:mailbox, _params}, _from, %{assigns: %{joined: false}} = socket),
    do: {:reply, {:error, :not_connected}, socket}

  def handle_call({:mailbox, params}, from, socket) do
    case Engine.whereis(params["agent_id"]) do
      {:ok, pid} when pid == elem(from, 0) -> mailbox_request(params, from, socket)
      _ -> {:reply, {:error, :stale_engine}, socket}
    end
  end

  def handle_call({:start_skill, _params}, _from, %{assigns: %{joined: false}} = socket) do
    reason = if socket.assigns[:no_credential?], do: :no_credential, else: :not_connected
    {:reply, {:error, reason}, socket}
  end

  def handle_call({:start_skill, params}, from, socket) do
    case push(
           socket,
           socket.assigns.topic,
           "skill_start",
           %{"params" => params},
           Channel.decision_timeout()
         ) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, Channel.decision_timeout())
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _reason} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  def handle_call({:await_analysis, _source, _args}, _from, %{assigns: %{joined: false}} = socket) do
    reason = if socket.assigns[:no_credential?], do: :no_credential, else: :not_connected
    {:reply, {:error, reason}, socket}
  end

  def handle_call(:await_idle, _from, %{assigns: %{joined: false}} = socket) do
    reason = if socket.assigns[:no_credential?], do: :no_credential, else: :not_connected
    {:reply, {:error, reason}, socket}
  end

  # Same out-of-band reply as `:await_analysis`: the server answers when the
  # analyzers go idle, which is minutes away.
  def handle_call(:await_idle, from, socket) do
    case push(socket, socket.assigns.topic, "analysis_wait", %{}, Channel.analysis_timeout()) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, Channel.analysis_timeout())
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _reason} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  # Same `pending` machinery as a hook decision, on a timeout two orders of
  # magnitude longer. The reply outlives this call by design: `handle_reply/3`
  # finds `from` and answers then.
  def handle_call({:await_analysis, source, args}, from, socket) do
    case push(
           socket,
           socket.assigns.topic,
           "analysis_run",
           %{"source" => source, "args" => args},
           Channel.analysis_timeout()
         ) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, Channel.analysis_timeout())
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _reason} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  def handle_call({:await_promotion, _story}, _from, %{assigns: %{joined: false}} = socket) do
    reason = if socket.assigns[:no_credential?], do: :no_credential, else: :not_connected
    {:reply, {:error, reason}, socket}
  end

  # Out of band like the two above, and it must be: the promotion sends its disk
  # work back down this channel as `fs_request`, so blocking here deadlocks.
  def handle_call({:await_promotion, story_number}, from, socket) do
    payload = %{"story_number" => story_number}

    case push(socket, socket.assigns.topic, "promotion_run", payload, Channel.promotion_timeout()) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, Channel.promotion_timeout())
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _reason} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  # One step of a turn, keyed by agent, while the turn is still running. Not
  # `record_turn`, which carries a finished request/response pair after the fact.
  @impl Slipstream
  def handle_cast({:turn_event, agent_id, envelope}, %{assigns: %{joined: true}} = socket) do
    push(socket, socket.assigns.topic, "agent_turn_event", %{
      "agent_id" => agent_id,
      "event" => encode_turn_event(envelope)
    })

    # Dropped here so a flush still pending cannot push a draft after the
    # message it became; the push for this event went out first, and the server
    # clears its copy on it.
    drafts = DraftBuffer.settle(drafts(socket), agent_id, Map.get(envelope, :event))
    {:noreply, assign(socket, :drafts, drafts)}
  end

  # Dropped rather than queued when not joined: a replayed backlog reads as the
  # agent doing those steps now.
  def handle_cast({:turn_event, _agent_id, _envelope}, socket), do: {:noreply, socket}

  # A fragment of what an agent is writing, flushed on a timer: a push per
  # fragment is a push every few characters.
  def handle_cast({:draft, agent_id, turn, text}, %{assigns: %{joined: true}} = socket) do
    socket
    |> assign(:drafts, DraftBuffer.add(drafts(socket), agent_id, turn, text))
    |> schedule_draft_flush()
    |> then(&{:noreply, &1})
  end

  def handle_cast({:draft, _agent_id, _turn, _text}, socket), do: {:noreply, socket}

  @impl Slipstream
  # Dropped rather than queued when not joined: a late, out-of-order recording
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

  # Never sent: reconciling an empty manifest would delete every file row, and
  # "found nothing" and "did not run" look the same. The server refuses it too;
  # catching it here names the harness's own fault.
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
           Channel.decision_timeout()
         ) do
      {:ok, ref} ->
        Logger.info(
          "[CmsHarness] sent #{length(observations)} observations for #{socket.assigns.project.root}"
        )

        # Kept so the reply is read: a rejected manifest must not look accepted.
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
           Channel.decision_timeout()
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

  # Not queued: the server closes a departed connection's unclaimed runs, and
  # the rejoin re-runs whatever is still stale.
  def handle_cast({:analysis_result, payload}, socket) do
    Logger.error(
      "[CmsHarness] dropped the #{payload["source"]} result for " <>
        "#{socket.assigns.project.root} — not connected. It will be re-run on rejoin."
    )

    {:noreply, socket}
  end

  # Dropped: a manifest describes *now*. The rescan on rejoin is the recovery.
  def handle_cast({:observations, _observations}, socket) do
    Logger.warning(
      "[CmsHarness] dropped a manifest for #{socket.assigns.project.root} — not connected. It will be rescanned on rejoin."
    )

    {:noreply, socket}
  end

  def handle_cast({:module_name, name}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "module_name",
           %{"module_name" => name},
           Channel.decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send module_name: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # Dropped, same reasoning as a dropped manifest: the next sync after
  # reconnect reports it again.
  def handle_cast({:module_name, _name}, socket), do: {:noreply, socket}

  def handle_cast({:health_route_status, status}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "health_route_status",
           %{"status" => status},
           Channel.decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send health_route_status: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:health_route_status, _status}, socket), do: {:noreply, socket}

  # Not queued when disconnected: the server closes a departed harness's runs,
  # so there is no open row for a late start to land on.
  def handle_cast({:analysis_started, payload}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "analysis_started",
           payload,
           Channel.decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error(
          "[CmsHarness] could not send the start of #{payload["source"]} run " <>
            "#{payload["run_id"]}: #{inspect(reason)}"
        )

        {:noreply, socket}
    end
  end

  def handle_cast({:analysis_started, _payload}, socket), do: {:noreply, socket}

  def handle_cast({:head_commit, sha}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "head_commit",
           %{"sha" => sha},
           Channel.decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send head_commit: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:head_commit, _sha}, socket), do: {:noreply, socket}

  def handle_cast({:machine_load, load}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "machine_load",
           load,
           Channel.decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send machine_load: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:machine_load, _load}, socket), do: {:noreply, socket}

  def handle_cast({:preview_status, status}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "preview_status",
           %{"status" => status},
           Channel.decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send preview_status: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:preview_status, _status}, socket), do: {:noreply, socket}

  def handle_cast({:app_status, payload}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "app_status",
           payload,
           Channel.decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send app_status: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:app_status, _payload}, socket), do: {:noreply, socket}

  def handle_cast({:promotion_result, topic, ref, result}, %{assigns: %{joined: true}} = socket) do
    push(socket, topic, "fs_result", Map.put(encode_fs_result(result), "ref", ref))
    {:noreply, socket}
  end

  # Disconnected before the work finished; the server's call times out and
  # says so.
  def handle_cast({:promotion_result, _topic, _ref, _result}, socket), do: {:noreply, socket}

  # --- Private ---

  defp stamp_server_reply(socket),
    do: assign(socket, :last_server_reply_at, System.monotonic_time(:second))

  defp resume_watcher(socket) do
    Watcher.resume(socket.assigns.project.root)
    socket
  end

  defp pause_watcher(socket) do
    Watcher.pause(socket.assigns.project.root)
    socket
  end

  # The wire, read at call time so a test can swap it per-case. See
  # `CmsHarness.Project.Transport` for why only outbound needed a seam.
  defp connect_headers(socket), do: Config.connect_headers(socket.assigns.project.root)

  defp transport, do: Transport.impl()

  # This working copy is already being served, usually by the process this one
  # is replacing. Quiet for the first few attempts, and it never stops trying.
  # `:refused` is for the health endpoint; it does not gate the reconnect.
  defp refused(socket, holder) do
    socket = socket |> update(:refusals, &(&1 + 1)) |> assign(:refused, :working_copy_in_use)
    attempt = socket.assigns.refusals

    log_refusal(socket, holder, attempt)
    schedule_rejoin(socket)
  end

  defp log_refusal(socket, holder, attempt) when attempt <= @refusal_retries do
    Logger.warning(
      "[CmsHarness] #{socket.assigns.project.root} is already served by #{holder} — retrying " <>
        "(#{attempt}/#{@refusal_retries}); a restarting harness frees it within seconds"
    )
  end

  defp log_refusal(socket, holder, attempt) when attempt == @refusal_retries + 1 do
    Logger.error("""
    [CmsHarness] not serving #{socket.assigns.project.root} — #{holder} is already on it.

    Still held after #{@refusal_retries} retries, so this is a second harness on one
    working copy rather than a process changing hands. They cannot share `_build`:
    two `mix test` runs in one build tree corrupt it into reporting failures that
    are not in the code.

    This one keeps retrying quietly and takes over the moment the other exits.
    Nothing is being watched or synced from here until then.
    """)
  end

  # Quiet from here. It is retrying at the capped backoff and has already said so.
  defp log_refusal(_socket, _holder, _attempt), do: :ok

  # Each dial gets its own ref, so a deadline outliving its attempt is ignored.
  defp arm_join_deadline(socket) do
    ref = make_ref()
    Process.send_after(self(), {:join_deadline, ref}, join_timeout())
    assign(socket, :join_attempt, ref)
  end

  # Upgraded: drop the socket, and `handle_disconnect/2` retries as for any
  # drop. (A rejoin after a refusal dials with the old socket still up, so this
  # may drop that one instead; the next dial still recovers.) Not upgraded:
  # Slipstream holds no handle to drop and will send no disconnect, so the
  # stalled connection is abandoned and the same retry runs.
  defp abandon_dial(socket) do
    if Slipstream.Socket.connected?(socket) do
      transport().disconnect(socket)
    else
      {:ok, socket} = handle_disconnect(:join_timeout, transport().abandon(socket))
      socket
    end
  end

  defp dial_stage(socket) do
    if Slipstream.Socket.connected?(socket),
      do: "the socket upgraded, the join was never answered",
      else: "the websocket upgrade was never answered"
  end

  defp schedule_rejoin(socket) do
    Process.send_after(self(), :reconnect, backoff(socket.assigns.attempts))
    update(socket, :attempts, &(&1 + 1))
  end

  # Every caller waiting on a reply is told the connection went, rather than
  # being left to time out.
  defp fail_pending(socket, reason) do
    Enum.each(socket.assigns.pending, fn {_ref, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    assign(socket, :pending, %{})
  end

  defp mailbox_request(params, from, socket) do
    case transport().push(socket, socket.assigns.topic, "agent_mailbox", params, 15_000) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, 15_000)
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  defp normalize_reply({:ok, payload}) when is_map(payload), do: {:ok, payload}
  defp normalize_reply({:error, _} = error), do: error

  # A bare `:ok` is an *empty* reply: Slipstream collapses Phoenix's empty
  # response to the atom. For a hook it is the commonest answer (nothing blocks
  # this stop), so it must read as `%{}`, not as unreadable.
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
      {id, %{module_name: MapAccess.get(component, :module_name)}}
    end)
  end

  # Conclusions, not raw material: no file content crosses this wire, only the
  # validation verdict.
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

  # Nothing was made on a failed create, so there is nothing to track or roll
  # back regardless of whether the server ever acks it.
  defp remember_create_ack(socket, _native_ref, _root, {:error, _}), do: socket

  defp remember_create_ack(socket, native_ref, root, {:ok, %{root: target, base_head: base_head}}) do
    pending = socket.assigns[:pending_create_ack] || %{}
    assign(socket, :pending_create_ack, Map.put(pending, native_ref, {root, target, base_head}))
  end
end
