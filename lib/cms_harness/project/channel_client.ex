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

  ## A refused join keeps trying

  Two harnesses on one *project* is ordinary now — files and problems are keyed
  on the working copy, so each writes its own rows. What the server still
  refuses is a second harness on the same *working copy*, because `mix test` and
  `mix spex` share one `_build` and two at once corrupt it.

  That refusal is temporary by nature: it clears the moment the holder exits. So
  this retries at the capped backoff rather than giving up. It used to give up
  permanently, from when the refusal meant file corruption — and because nothing
  cleared the flag, a harness that was refused once stayed dead for the life of
  the process. On 2026-08-08 that survived a server restart: the harness could
  see the server answering 200 and would not reconnect, which reads exactly like
  a broken server.
  """

  use Slipstream

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Credentials
  alias CmsHarness.HarnessConfig
  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Project.Transport
  alias CmsHarness.Project.Watcher
  alias CmsHarness.Sync
  alias CodeMySpec.Promotion.Steps
  alias CmsHarness.Web.Endpoint
  alias CmsHarness.WorkingCopies.Create
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Utils.MapAccess

  # Long enough for a transatlantic round trip against a busy server, short
  # enough that a hung hook is a hook that eventually answers. It is paid on
  # every agent turn, so it is not generous.
  @default_decision_timeout 10_000

  @backoff [1_000, 2_000, 5_000, 10_000, 30_000]

  # The channel contract this harness speaks. Kept in step with
  # `CodeMySpecWeb.HarnessProjectChannel`'s copy of the same number — the two
  # are the contract, so they are the two places that have to agree.
  #
  # Bump on a change to the join payload, the `handle_in` set, or the shapes
  # those carry. Not for ordinary changes on either side: a version that moves
  # for everything means a refusal on every deploy, which trains people to
  # ignore it.
  @contract_version 2

  @doc """
  The channel contract version this harness speaks.

  Public so a test can compare it against
  `CodeMySpecWeb.HarnessProjectChannel`'s copy — see that function for why the
  comparison, rather than either value, is the thing worth asserting.
  """
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  # How many refusals are reported quietly before one loud explanation. Not a
  # give-up count — nothing gives up any more.
  #
  # The executor slot is held by the *server-side channel process*, so it frees
  # the instant that socket closes, including on a restart. But a restart is a
  # handover rather than an instant: for the seconds the old process takes to
  # go, the new one cannot take a slot the old one still holds. Spanning the
  # backoff, this is roughly 48 seconds — long enough that an ordinary handover
  # never produces the loud message.
  @refusal_retries 4

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
    case Endpoint.server_info(:http) do
      {:ok, {_ip, port}} when is_integer(port) and port > 0 -> port
      _ -> Endpoint.config(:http)[:port]
    end
  end

  defp decision_timeout,
    do: Application.get_env(:code_my_spec, :harness_decision_timeout, @default_decision_timeout)

  # A whole suite, not a decision. Longer than the server's own wait, so a run
  # the server gives up on comes back as its answer rather than as this timing
  # out first — one of those is a failed analyzer and the other is a broken
  # channel, and the agent cannot act on them the same way.
  defp analysis_timeout,
    do: Application.get_env(:code_my_spec, :harness_analysis_await_timeout, :timer.minutes(32))

  # --- Client API ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    Slipstream.start_link(__MODULE__, project, name: via(project.root))
  end

  # Keyed on the working copy. The project id still names the *topic* — that is
  # the server's identity for this project and is shared by every checkout of
  # it — but two checkouts are two channels, and keying the registry on the id
  # gave the second one the first's. Issue 8b83ba20.
  def via(root), do: {:via, Registry, {CmsHarness.Registry, {:channel, root}}}

  @doc """
  Whether this project's channel is joined right now.

  `false` covers "never connected", "dropped", and "refused" alike — from the
  caller's point of view they are the same fact: the harness cannot ask the
  server anything about this project.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :connected?, 5_000)
      [] -> false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  Seconds since this project's channel joined, or `nil` if it is not joined.

  `connected?/1` answers "can I ask the server", which is the right question
  before sending. This answers a different one, asked *after* a request came
  back empty: how long has this channel been up?

  A channel that joined moments ago has usually just been rebuilt after dying,
  and a request in flight when it died is simply gone. Reporting that as "the
  channel is joined, so this is the server or the network" sent three agents
  after a connection that was fine — the server had crashed, dropped the
  channel, and the harness had reconnected before anyone looked. `1dc29224`.
  """
  @spec joined_ago(String.t()) :: non_neg_integer() | nil
  def joined_ago(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :joined_ago, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Seconds since the server last answered this project's channel, or `nil`.

  The question `connected?/1` cannot answer. That one reports this process's
  belief about its own socket, set at join — it cannot be wrong from where it
  stands, and it read `true` throughout an incident where the server's registry
  held no entry for this harness and every request came back
  `:harness_unreachable`. Both ends reported healthy because neither had done a
  round trip.

  A reply is evidence, because the server is what sent it. Recorded on replies
  that already happen, so this costs nothing to ask and cannot hang.
  """
  @spec server_replied_ago(String.t()) :: non_neg_integer() | nil
  def server_replied_ago(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :server_replied_ago, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Send a completed model turn to the server to be recorded.

  Fire and forget, and deliberately so. Recording is evidence for whoever is
  watching, never a step the agent's turn depends on — a cast cannot make the
  turn slower, cannot fail it, and cannot block it behind a server that is
  briefly unreachable. A turn lost from the record is a gap the operator is
  shown; a turn lost to the recorder would be work destroyed.
  """
  @spec record_turn(String.t(), map()) :: :ok
  def record_turn(root, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:record_turn, payload})
      [] -> :ok
    end

    :ok
  end

  @doc """
  Ask the server to decide a hook.

  Returns `{:error, :not_connected}`, `{:error, :no_credential}` or
  `{:error, :no_reply}` rather than anything resembling an answer. The caller
  turns that into a refusal; this must never invent one.
  """
  @spec decide_hook(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_connected | :no_credential | :no_reply}
  def decide_hook(root, hook, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, {:decide_hook, hook, payload}, decision_timeout() + 2_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc """
  Ask the server to resolve a skill invocation to a prompt.

  Same shape as `decide_hook/3` — resolving a skill is a DB-bound lookup
  (`StartAgentTask.run/2` creates a session row and returns a prompt string;
  it does not run the agent turn itself), not a `mix` invocation, so it shares
  `decide_hook/3`'s timeout class rather than `await_analysis/3`'s.
  """
  @spec start_skill(String.t(), map()) ::
          {:ok, map()} | {:error, :not_connected | :no_credential | :no_reply}
  def start_skill(root, params) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, {:start_skill, params}, decision_timeout() + 2_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc """
  Run one analyzer for the agent and wait for the server's answer.

  The agent's own `mix test`, rewritten by the PreToolUse hook. It goes to the
  server rather than straight to `mix` so the run gets a ledger row, joins an
  identical run already in flight instead of a second one contending for
  `_build`, and reconciles its Problems centrally — none of which a bare shell
  command can do, which is why the same suite used to be run twice.

  Blocks for as long as the suite takes. The server replies out of band, so no
  channel process is held while it does.
  """
  @spec await_analysis(String.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def await_analysis(root, source, args) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] ->
        GenServer.call(pid, {:await_analysis, source, args}, analysis_timeout() + 5_000)

      [] ->
        {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc """
  Block until the project's analyzers are idle, then return their state.

  Backs `POST /api/analysis/wait`. Blocks for as long as the queue takes; the
  server replies out of band, so no channel process is held meanwhile.
  """
  @spec await_idle(String.t()) :: {:ok, map()} | {:error, term()}
  def await_idle(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :await_idle, analysis_timeout() + 5_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc "The read model this project last received. `nil` before the first join."
  @spec read_model(String.t()) :: ReadModel.t() | nil
  def read_model(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
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
  def request_sync(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, :sync)
      [] -> :ok
    end
  end

  @doc "Called from the scanning task with the finished manifest."
  @spec deliver_observations(String.t(), [map()]) :: :ok
  def deliver_observations(root, observations) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:observations, observations})
      [] -> :ok
    end
  end

  @doc """
  Called from the scanning task with the app name read straight out of
  this checkout's own `mix.exs`.
  """
  @spec deliver_module_name(String.t(), String.t()) :: :ok
  def deliver_module_name(root, name) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:module_name, name})
      [] -> :ok
    end
  end

  @doc """
  Called from the scanning task with the health-route verdict, checked
  against this checkout's own real router.ex/endpoint.ex.
  """
  @spec deliver_health_route_status(String.t(), String.t()) :: :ok
  def deliver_health_route_status(root, status) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:health_route_status, status})
      [] -> :ok
    end
  end

  @doc """
  Called from the scanning task with `git rev-parse HEAD`, read straight out
  of this checkout.
  """
  @spec deliver_head_commit(String.t(), String.t()) :: :ok
  def deliver_head_commit(root, sha) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:head_commit, sha})
      [] -> :ok
    end
  end

  @doc "Whether this checkout's application is answering, measured on every scan."
  @spec deliver_preview_status(String.t(), String.t()) :: :ok
  def deliver_preview_status(root, status) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:preview_status, status})
      [] -> :ok
    end
  end

  @doc "This checkout's sync state with main, measured on every scan."
  @spec deliver_git_state(String.t(), map()) :: :ok
  def deliver_git_state(root, state) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:git_state, state})
      [] -> :ok
    end
  end

  @doc "Called from the analysis queue with a finished (or failed) run."
  @spec deliver_analysis_result(String.t(), map()) :: :ok
  def deliver_analysis_result(root, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:analysis_result, payload})

      [] ->
        # The channel died between the run starting and finishing. The server
        # closed that run's ledger row when the socket went, so this result has
        # nowhere to land — said out loud rather than dropped silently, because
        # the visible symptom otherwise is an analyzer that appears never to
        # have run.
        Logger.error(
          "[CmsHarness] #{payload["source"]} finished for project #{root} but the " <>
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
      |> assign(:refusals, 0)
      |> assign(:silences, 0)

    {:ok, socket, {:continue, :connect}}
  end

  @impl Slipstream
  def handle_continue(:connect, socket) do
    case Config.socket_url(socket.assigns.project.root) do
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
    project = socket.assigns.project

    {:ok,
     transport().join(socket, socket.assigns.topic, %{
       "label" => Config.label(project.root),
       # Which working copy this is. `nil` on the first join of a checkout —
       # the server mints one and hands it back, and `handle_join/3` writes it
       # down so every later join presents the same one. A server that does not
       # yet know the field ignores it, which is why this can land ahead of the
       # half that reads it.
       "harness_id" => project.working_copy_id,
       # Where this copy is, as reported data rather than identity. The server
       # records it so an operator looking at two harnesses of one project can
       # tell which checkout each is; nothing resolves a harness by it.
       "root" => project.root,
       # Where this project's preview answers, for the copy that is its main
       # checkout. Reported for the same reason `root` is: the address is
       # written in the checkout's own config at onboarding, and the server
       # holds a copy so the web app — which has no disk — can render a frame
       # at it. `nil` from every other copy, and from a main checkout that has
       # no preview yet, which is the ordinary state.
       "preview_url" => project[:preview_url],
       # Which machine this copy is on, by the id this install was issued when
       # it came up. Reported, never created: the server looks it up and
       # attaches, and an id it does not recognise attaches nothing rather than
       # minting a machine. A checkout must not be able to assert a device into
       # existence — one install serves many copies, so that would make a
       # machine per checkout.
       #
       # `nil` on a machine that has not onboarded, and absent entirely from an
       # older harness. Both mean "no device announced", which is a real state
       # and not a failure.
       "device" => %{"id" => CmsHarness.Device.recorded_id()},
       # What else this machine can do, by name. A browser is an MCP server on
       # this box — `vibium mcp` over stdio — and its tools go into the catalog
       # a script can call rather than onto the agent, which is what keeps
       # twenty-nine schemas out of every turn.
       #
       # Reported on join because it is a property of the machine and not of an
       # agent: an agent's list is computed at start from what its machine
       # said, so the server has to know before there is an agent to ask about.
       # `[]` from a machine with no browser, which is a state rather than a
       # failure — see `CmsHarness.Browser`.
       "machine_tools" => CmsHarness.Browser.tool_names(),
       # And what each of them takes. Thirty kilobytes for all eighty-five,
       # measured against this machine's vibium — sent once per join, so that
       # `tool_docs` can answer for a browser tool without a round trip on the
       # path an agent uses to decide what to call. That path is the one that
       # queues behind sibling agents (35e5eb59), and documentation missing when
       # the machine is busy is worse than documentation one join old.
       "machine_tool_docs" => CmsHarness.Browser.tool_docs(),
       # Why that list is what it is. `[]` meant both "no browser here" and
       # "the browser is here and would not answer", and the second is the one
       # somebody can act on — see issue 02b03d04.
       "browser_status" => browser_status(),
       # Which OS process holds this socket. The server needs it to tell a
       # rejoin apart from a rival: both present the same working_copy_id, because
       # that id is the working copy and is read from a file in it. Same
       # instance means this process reconnecting, and the registration it is
       # colliding with is its own — so it may take it. A different instance is
       # a second harness on one `_build`, which still gets refused.
       "instance" => instance(),
       # Runs this harness is still working on. The server closes a working
       # copy's open runs on join, because a harness that restarted took its
       # queue with it — but a harness whose *socket* dropped did not. The
       # analyzers are OS processes here and a closed socket does not touch
       # them; they finish, report, and are refused for a run that is no longer
       # `:running`.
       #
       # Declaring them lets the sweep close only what goes unclaimed. An older
       # server ignores the field and sweeps everything, which is what it does
       # today.
       "active_runs" => AnalysisServer.in_flight(project.root),
       # What this harness believes the channel contract is.
       #
       # Skew between the two ends surfaces today as `{:error, %{"reason" =>
       # "unmatched topic"}}` on every stop — a message about topics, for a
       # problem about versions. It was diagnosable only because the refusal
       # wrapper appends the harness's boot commit and its checkout's current
       # one, so a reader can `git diff --stat <range> -- lib/cms_harness
       # lib/code_my_spec_web/channels` and see the contract move. That works and
       # it should not be the mechanism (c8a7f11d).
       #
       # Stated outright, the server can name the mismatch instead of leaving it
       # to be inferred from a commit range. Bump this when the join payload, the
       # `handle_in` set, or the shapes they carry change — not for ordinary
       # changes to either side.
       #
       # An older server ignores the field, and the server treats its absence as
       # "a harness that predates this", so the rollout order does not matter —
       # the same reasoning `active_runs` above is built on.
       "contract_version" => @contract_version
     })}
  end

  # Flattened for the wire, with the reason attached where there is one. A map
  # rather than a bare string so the server can record why without a second key
  # that could disagree with the first.
  defp browser_status do
    case CmsHarness.Browser.status() do
      {:unreachable, reason} -> %{"status" => "unreachable", "error" => reason}
      status -> %{"status" => to_string(status)}
    end
  end

  # Host as well as pid: pids are only unique per machine, and a sprite and a
  # laptop can hold checkouts that were cloned with the same id file.
  defp instance do
    {:ok, host} = :inet.gethostname()
    "#{host}:#{System.pid()}"
  end

  @impl Slipstream
  def handle_join(topic, reply, socket) do
    Logger.info("[CmsHarness] holding #{socket.assigns.project.root} — joined #{topic}")

    socket =
      socket
      |> persist_issued_identity(reply)
      |> assign(:joined, true)
      |> assign(:joined_at, System.monotonic_time(:second))
      |> assign(:attempts, 0)
      |> assign(:refusals, 0)
      |> assign(:refused, nil)
      |> assign(:silences, 0)

    schedule_read_model_refresh()
    schedule_preview_check()

    # The read model first: a scan without one resolves no owners and validates
    # no specs, so it would produce a manifest that is wrong rather than late.
    case transport().push(socket, topic, "read_model", %{}, decision_timeout()) do
      {:ok, ref} ->
        socket = socket |> assign(:read_model_ref, ref) |> assign(:read_model_reason, :join)
        {:ok, ask_what_to_restore(socket, topic)}

      {:error, _} ->
        {:ok, ask_what_to_restore(socket, topic)}
    end
  end

  # The id the server issued for this working copy, written down so a restart
  # presents the same one rather than being issued a second.
  #
  # Only ever *adds* an identity. A server that answers with a different id than
  # the one presented is not obeyed: the rows this copy has already written are
  # filed under the id on disk, and quietly adopting a new one would orphan them
  # while everything kept looking healthy. Named instead, because the two ids
  # disagreeing is a fact somebody has to reconcile.
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

  @doc "Public so a test can assert against the real interval rather than a copy."
  def read_model_refresh_ms, do: @read_model_refresh_ms

  defp schedule_read_model_refresh,
    do: Process.send_after(self(), :refresh_read_model, @read_model_refresh_ms)

  # Preview health gets its own clock, because a scan is the wrong one.
  #
  # Everything else the sync reports changes only when the disk changes. An
  # application does not: it crashes while nobody is editing and recovers while
  # nobody is editing, and `code_on_running_copy` refuses on the result. Tied to
  # the scan, a recovered app stayed `down` until someone touched a file, and a
  # crashed one read `serving` for exactly as long.
  @preview_check_ms 60_000

  @doc "Public so a test can assert against the real interval rather than a copy."
  def preview_check_ms, do: @preview_check_ms

  defp schedule_preview_check,
    do: Process.send_after(self(), :measure_preview, @preview_check_ms)

  # A join the server refused. The only one we know how to explain is a project
  # another harness holds; anything else is reported as it arrived.
  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    socket = socket |> assign(:joined, false) |> pause_watcher()

    # Slipstream reports a refused join as `:failed_to_join` and a channel that
    # closed after joining as `:error`; the refusal we know how to explain can
    # arrive either way.
    case reason do
      # `project_in_use` is what a server older than the grain change sends. Both
      # are accepted so a harness can serve either.
      {kind, %{"reason" => reason, "held_by" => holder}}
      when kind in [:error, :failed_to_join] and
             reason in ["working_copy_in_use", "project_in_use"] ->
        {:ok, refused(socket, holder)}

      # A credential that reaches a different project. The socket connects — the
      # key is valid — and the join is refused, so every hook in the working
      # copy answers "channel down, server answering 200" while the harness's
      # own /health says connected, because that is about the socket.
      #
      # Measured 2026-08-21: a `broken_oaths` checkout served by the CodeMySpec
      # daemon, refused every thirty seconds for hours, with nothing on either
      # side naming the credential. This is the whole of what that cost.
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
        "This harness presented CMS_DEPLOY_KEY, which is issued per project and " <>
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
        "This harness presented CMS_TOKEN. A user token reaches every project its " <>
          "user can access, so a refusal means this user has no access to " <>
          "#{project.id} — or the token has expired, which it does silently " <>
          "because a CMS_TOKEN is never refreshed."

      {:error, :no_credential} ->
        "This harness has no credential at all for #{project.root}."
    end
  end

  # A scan on the join reply is the point: the read model is what resolves
  # owners and validates specs, so the first manifest has to wait for it.
  #
  # The 60s refresh reuses this same reply path, and scanning there re-hashed
  # and re-uploaded every file in the working copy once a minute whether or not
  # anything had changed — on top of the watcher's own 90s floor. Interleaved,
  # the two produced a full sync every 30 seconds per copy, ~120 an hour each,
  # and with three copies attached the server upserted well over a million file
  # rows an hour to learn nothing.
  #
  # A refresh that *does* change the read model still earns its scan: new
  # criteria or spec paths mean the last manifest resolved owners against a
  # model that no longer holds. An identical one says nothing about the disk,
  # and the watcher already covers the disk.
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

        socket = socket |> assign(:read_model, read_model) |> resume_watcher()

        maybe_sync(socket, previous, read_model)
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

  def handle_reply(ref, reply, %{assigns: %{restore_ref: ref}} = socket) do
    socket = socket |> stamp_server_reply() |> assign(:restore_ref, nil)

    case reply do
      {:ok, %{"agents" => agents}} when is_list(agents) ->
        restore(agents)
        {:ok, socket}

      other ->
        # Not fatal: nothing is running yet, so the worst case is a harness that
        # holds no agents until somebody asks for one. Said out loud because the
        # alternative is agents that silently never come back.
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
      # The server takes the manifest and reconciles it after replying, so the
      # counts are no longer in the reply — a big manifest used to hold the
      # channel long enough that a stop decision behind it timed out. They are
      # logged server-side instead.
      {:ok, %{"status" => "accepted", "observations" => count}} ->
        Logger.info(
          "[CmsHarness] server accepted the manifest for #{socket.assigns.project.root}: " <>
            "#{count} observations queued to reconcile"
        )

        {:ok, socket}

      # A server that predates that change. Anything that still replies with
      # counts accepted the manifest, and calling it a rejection would be a lie
      # in the direction that costs the most.
      {:ok, %{"upserted" => upserted, "removed" => removed}} ->
        Logger.info(
          "[CmsHarness] server accepted the manifest for #{socket.assigns.project.root}: " <>
            "#{upserted} upserted, #{removed} removed"
        )

        {:ok, socket}

      # A reply this harness cannot read, that says it succeeded anyway.
      #
      # Not a refusal, and it must not be reported as one. Measured on drill 16:
      # a sprite built 2026-08-02 met a server carrying `6e389c29` from
      # 2026-08-09, which changed the reply from counts to `%{"status" =>
      # "accepted", "observations" => n}`. The old harness had no clause for the
      # new shape, fell to the catch-all, and logged
      #
      #     the server REJECTED the manifest: {:ok, %{"observations" => 51,
      #     "status" => "accepted"}}
      #
      # — the word REJECTED directly above the server saying "accepted". The
      # closing line of that message guessed version skew correctly while its
      # headline asserted the opposite, and `drill.sh` waits for the string
      # "accepted the manifest", so a drill whose manifest landed fine timed out
      # at the preflight.
      #
      # Matched before the catch-all rather than by parsing: any reply that says
      # it was accepted was accepted, whatever else it carries. This is the same
      # kindness the clause above extends to an *older* server, in the other
      # direction — a newer one.
      {:ok, %{"status" => "accepted"} = reply} ->
        Logger.warning(
          "[CmsHarness] server accepted the manifest for #{socket.assigns.project.root}, " <>
            "in a shape this harness does not recognise: #{inspect(reply)}. The sync is " <>
            "fine; this harness is older than the server. Rebuild it to stop guessing at " <>
            "replies."
        )

        {:ok, socket}

      # A push that lands after the channel has left its topic. Ordinary
      # shutdown, not a refusal: `stop`, `just refresh` and `refresh-harness`
      # all leave a scan in flight, and its manifest arrives at a topic the
      # process is no longer joined to.
      #
      # Given its own clause because the catch-all's diagnosis is actively
      # wrong here, and expensively so. A QA agent spent a session on it: the
      # "usually version skew" line sent it comparing shas across two
      # checkouts, it checked whether a bare restart cleared the symptom, and
      # reasoned its way to "genuine code drift" — careful work from a false
      # premise the log handed it. See `2d26df7c`.
      {:error, %{"reason" => "unmatched topic"}} ->
        Logger.info(
          "[CmsHarness] manifest for #{socket.assigns.project.root} arrived after the " <>
            "channel left its topic — the harness is shutting down or reconnecting. " <>
            "Nothing is wrong and nothing was lost; the next join re-syncs."
        )

        {:ok, socket}

      other ->
        # Loud, and says what it means: the working copy and the server's
        # picture of it are now different, and nothing downstream can tell.
        #
        # "Could not read the reply" now has its own clause above, so this is
        # reserved for a reply that does not claim success — which is the only
        # kind that deserves the word REJECTED.
        #
        # It no longer guesses at *why*. The server supplies a reason and the
        # old text overwrote it with "usually version skew" on every rejection
        # — a deploy-shaped diagnosis, asserted unconditionally, and false in
        # the one case that actually occurs regularly. Naming the reply and
        # leaving the cause unstated is worth more than a confident wrong
        # answer.
        Logger.error("""
        [CmsHarness] the server REJECTED the manifest for #{socket.assigns.project.root}: #{inspect(other)}

        The server's picture of this project is now out of step with the disk,
        and the requirement graph is computed from the server's picture. This is
        not "nothing changed" — the sync was refused, for the reason above.
        """)

        {:ok, socket}
    end
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

  # The server says there is no channel on that topic. We thought there was —
  # `joined` is still true, `connected?/1` still answers yes, and the health
  # endpoint still reports the project served. Every hook then refuses forever
  # and nothing ever corrects it, because the correction is supposed to arrive
  # as `handle_topic_close/3` and in this case never did.
  #
  # So this trusts the server over our own flag. A reply naming the topic as
  # unmatched *is* the notification the close should have been, and the only
  # ground truth available: the harness cannot tell the difference between a
  # channel that died and one that was never there, and does not need to.
  #
  # Cost of being wrong is one dropped connection. Cost of not doing it is a
  # harness that looks healthy and answers nothing until somebody restarts it.
  #
  # It drops the *socket*, which is heavier than rejoining the topic and is the
  # point. `Slipstream.join/3` only acts when its local `join_status` is `nil`
  # or `:closed`, and in exactly this situation it is neither: the server lost
  # the channel without ever sending a close, so Slipstream still believes the
  # topic is joined. Asking it to join again is a silent no-op — which is how
  # this failed the first time it was needed. One `maybe_rejoin`, then nothing,
  # for three minutes, until the harness was restarted by hand.
  #
  # A dropped socket cannot be disbelieved. `handle_disconnect/2` follows, and
  # from there the ordinary reconnect path runs — the one that demonstrably
  # works, since it is what survives every server restart.
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

  # A result the server refused is not a result it recorded. Read rather than
  # dropped, for the same reason the observations reply is read: an unread
  # rejection makes a run that never landed look exactly like one that did, and
  # the whole value of running the analyzer is that those two stay apart.
  defp log_analysis_reply(_source, {:ok, _}, socket), do: socket
  defp log_analysis_reply(_source, :ok, socket), do: socket

  defp log_analysis_reply(source, {:error, %{"reason" => reason}} = reply, socket)
       when is_binary(reason) do
    log_by_kind(superseded?(reason), source, reply, socket)
  end

  defp log_analysis_reply(source, other, socket), do: log_rejection(source, other, socket)

  # A supersede is a scheduling fact, not a rejection. The server enqueued a run
  # for this source, a second arrived while the first was still open, and the
  # first answers for both.
  #
  # `Reconciler.supersede/2` already made exactly this call on the server side —
  # "at `:info`, not `:warning` — nothing is wrong … logging it as a failure
  # taught readers to ignore a level that should mean something" — and the
  # reasoning never crossed to the harness. 80 of the 385 rejections in this
  # machine's `harness.log` are supersedes, every one at `level=error` under a
  # message saying the analyzer's work was lost and the next stop will report
  # pending. Both halves are wrong for this case, and a log where `error` is
  # routinely a non-event is a log nobody reads.
  #
  # Still worth a line: the analyzer *did* run, and a full spex sweep is minutes.
  # Repeated supersedes mean that work is being done twice and discarded, which
  # is a thing to notice — just not a failure.
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

    AnalysisServer.enqueue(socket.assigns.project.root, runs)
    {:ok, socket}
  end

  # The server asking for a fresh manifest. It cannot walk this checkout — the
  # disk is here — so the sync happens on this side and arrives the way every
  # other manifest does, through `observations`.
  #
  # Through `request_sync/1` rather than casting `:sync` directly: the file
  # watcher already goes that way, and one entry point means a scan triggered by
  # the server and a scan triggered by a write are the same scan. It resolves to
  # this process, so the cast is to self, which is fine and keeps the scan out of
  # the socket process either way.
  @impl Slipstream
  # This copy was offboarded on the server, so stop serving it.
  #
  # No `ref` and no reply: an offboard must not be able to fail because the
  # machine is unreachable or slow, so the server pushes and does not wait.
  # Missing this message costs a stale subtree until the next restart, which is
  # exactly the state this fixes and no worse than it.
  #
  # Terminated from another process on purpose. The subtree being stopped
  # contains *this* one — asking a supervisor to kill the caller's own ancestor
  # from inside a callback would take the callback with it, before it returns.
  # `Task.start/1` lets this return `{:ok, socket}` and die a moment later,
  # which is the ordering Slipstream expects.
  def handle_message(_topic, "offboard", _payload, socket) do
    root = socket.assigns.project.root

    Logger.info("[CmsHarness] server offboarded #{root} — releasing its channel and watchers")

    Task.start(fn -> CmsHarness.Projects.stop_serving(root) end)

    {:ok, socket}
  end

  def handle_message(_topic, "rescan", _payload, socket) do
    Logger.info("[CmsHarness] server asked for a rescan of #{socket.assigns.project.root}")

    request_sync(socket.assigns.project.root)
    {:ok, socket}
  end

  # An event this harness does not implement is version skew, and it is named.
  # The server's own catch-all was made to reply for exactly this reason: a
  # message silently ignored on one side reads as latency on the other.
  # A filesystem operation the server cannot perform, because the working copy
  # is here and not there.
  #
  # The whole of the remote environment on this side: decode the op, apply it
  # with the same `Environments` API everything else uses, send the outcome
  # back. Nothing about it is harness-specific — the server is simply borrowing
  # this machine's disk.
  # Promotion's disk work. The same borrowed disk as `fs_request`, and it cannot
  # share that handler for two reasons.
  #
  # It is slow. `just restart` compiles, migrates and waits for the app to
  # answer — minutes on a cold tree — and `fs_request` applies its op inline, in
  # this process. This process also carries hook decisions and analyzer replies,
  # so a promotion answered inline would stall every hook on the machine for the
  # length of a build. Answered from a task instead; `ref` pairs the reply up.
  #
  # And it names a root that is deliberately not this channel's own.
  # `fs_request` is scoped to `socket.assigns.project.root` because a server
  # asking to read an arbitrary path would be a hole. A promotion is the one
  # operation whose whole point is a *second* checkout — the one the application
  # runs from — so the root arrives in the payload and is checked against the
  # roots this harness actually serves rather than assumed.
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

  def handle_message(_topic, "fs_request", %{"ref" => ref, "op" => op} = msg, socket) do
    payload = msg["payload"] || %{}
    env = Environment.new(:local, socket.assigns.project.root)

    result = apply_fs(env, op, payload)

    push(socket, socket.assigns.topic, "fs_result", Map.put(encode_fs_result(result), "ref", ref))

    {:ok, socket}
  end

  # End an agent's process group, because this is the machine it is on.
  #
  # The server owns the record and cannot signal anything; it knows a group id
  # and a boot id and has to ask. The answer is what lets it record the stop, so
  # this always replies — silence would leave the caller waiting out its timeout
  # and then reporting a stop that never happened.
  # Launch an agent here, because this is the machine that holds its working
  # copy — and an agent session is hundreds of tool calls against that copy.
  # Make a checkout on this machine, because this is the machine with the disk.
  #
  # The server cannot run `git worktree add` — it is not on this filesystem and
  # `fs_request` is scoped to `socket.assigns.project.root`, so it could not
  # make a *sibling* even if it were. So the file half happens here and the
  # record half happens there, and the caller made one call (story 891, rule
  # "The harness does the work on disk and the server does the work on the
  # record").
  #
  # Answered from a task: `git worktree add` fetches nothing but does walk the
  # index, and onboarding after it writes several files. Holding the channel for
  # that would stall this copy's reports and manifests behind somebody else's
  # new checkout.
  def handle_message(_topic, "create_working_copy", %{"ref" => ref} = msg, socket) do
    topic = socket.assigns.topic
    parent = self()
    root = socket.assigns.project.root

    Task.start(fn ->
      result = Create.run(root, msg)

      send(parent, {:create_working_copy_result, topic, ref, result})
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "start_agent", %{"ref" => ref} = msg, socket) do
    result = CmsHarness.Agents.launch(msg)

    push(
      socket,
      socket.assigns.topic,
      "agent_start_result",
      Map.put(encode_start_result(result), "ref", ref)
    )

    {:ok, socket}
  end

  # The agent id is the handle. It used to be a process group id paired with the
  # boot it belonged to, because a group number outlives the group and gets
  # reused — a supervised process has no such problem, and the server already
  # knows the id it asked us to start.
  # Give a running agent something to do.
  #
  # Answered from a task, not from here: a turn is a model call and can take
  # minutes, and holding the channel for it would stall every other thing this
  # copy needs to say — its reports, its manifests, its next stop — behind one
  # agent thinking.
  def handle_message(_topic, "message_agent", %{"ref" => ref} = msg, socket) do
    topic = socket.assigns.topic
    parent = self()

    Task.start(fn ->
      result =
        CmsHarness.Agents.message(
          msg["agent_id"],
          msg["message"],
          msg["timeout"] || 180_000
        )

      send(parent, {:agent_message_result, topic, ref, result})
    end)

    {:ok, socket}
  end

  # Hand an agent a message and say what became of it, without waiting for the
  # turn.
  #
  # Answered from here rather than from a task, unlike `message_agent` above:
  # the engine decides started-or-queued without running anything, so there is
  # no turn to hold the channel behind.
  def handle_message(_topic, "send_message", %{"ref" => ref} = msg, socket) do
    result =
      CmsHarness.Agents.send_message(
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

  def handle_message(_topic, "withdraw_message", %{"ref" => ref} = msg, socket) do
    result = CmsHarness.Agents.withdraw(msg["agent_id"], msg["message_ref"])

    push(
      socket,
      socket.assigns.topic,
      "agent_withdraw_result",
      Map.put(encode_withdraw_result(result), "ref", ref)
    )

    {:ok, socket}
  end

  def handle_message(_topic, "stop_agent", %{"ref" => ref} = msg, socket) do
    result = CmsHarness.Agents.halt(msg["agent_id"])

    push(
      socket,
      socket.assigns.topic,
      "agent_stop_result",
      Map.put(encode_stop_result(result), "ref", ref)
    )

    {:ok, socket}
  end

  # A script on the server asked for something that lives here. The browser is
  # the only such thing today, and it is on this machine because Chrome is.
  # Answered from a task, on the same reasoning as `message_agent` above and
  # for a reason the browser split made unavoidable. This used to run inline,
  # which held the channel for the length of the call — survivable while every
  # such call was capped at thirty seconds, and not survivable now the caller
  # sets the deadline: a `browser_wait_for_text` waiting a minute would stall
  # this copy's reports, manifests and stops behind one page load, and a
  # heartbeat missed that long reads to the server as a harness that died.
  def handle_message(_topic, "tool_call", %{"ref" => ref} = msg, socket) do
    topic = socket.assigns.topic
    parent = self()

    Task.start(fn ->
      result = CmsHarness.Browser.call(msg["tool"], msg["arguments"] || %{}, msg["timeout"])

      send(parent, {:tool_call_result, topic, ref, result})
    end)

    {:ok, socket}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.warning(
      "[CmsHarness] the server sent #{inspect(event)}, which this harness does not " <>
        "implement. Nothing was done about it."
    )

    {:ok, socket}
  end

  # An error stays an error across the wire. A browser that refused and one that
  # answered "no such element" are different things to an agent deciding what to
  # do next, and flattening both into text makes them the same thing.
  defp encode_tool_result({:ok, text}), do: %{"text" => text}
  defp encode_tool_result({:error, reason}), do: %{"error" => to_string_reason(reason)}

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)

  # One clause per named operation, and no general `cmd`. That route was refused
  # deliberately — `analysis/run` already owns command execution here along with
  # the run ledger, single-flight and `_build` — so promotion gets three named
  # things it may do rather than the ability to run anything.
  defp apply_promotion("promotion_precheck", %{"root" => root}),
    do: with_served_root(root, &Steps.precheck(Environment.new(:local, &1), &1))

  defp apply_promotion("promotion_merge", %{"root" => root, "branch" => branch}),
    do: with_served_root(root, &Steps.merge(Environment.new(:local, &1), &1, branch))

  defp apply_promotion("promotion_restart", %{"root" => root}),
    do: with_served_root(root, &Steps.restart(Environment.new(:local, &1), &1))

  defp apply_promotion(op, _payload),
    do: {:error, %{reason: "this harness does not implement #{op}"}}

  # A root this harness does not serve is refused rather than operated on. The
  # server names the running copy's path and is trusted to know it, but "trusted
  # to know it" and "may name any path on this machine" are different powers and
  # only the first one is wanted.
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

  # An op this harness does not know is an error, not a silent nothing — the
  # server is waiting on a reply and would otherwise sit out its full timeout.
  # Same reason the unknown-event clause above logs rather than dropping.
  defp apply_fs(_env, op, _payload), do: {:error, :"unsupported_fs_op_#{op}"}

  # `Runner.start/3` hands back its own handle — `pgid` and `boot_id` — and the
  # wire carries `os_pid` and `os_boot_id`. Translating here is the whole job,
  # and this clause used to match the wire names against the handle, so it
  # matched nothing: every start raised `FunctionClauseError`, took the channel
  # client down with it, and the server saw the socket close mid-call and
  # reported `{:shutdown, :peer_closed}` — a transport failure, for a name
  # mismatch two lines from the successful spawn.
  #
  # `handle_message("stop_agent", ...)` does the same translation in the other
  # direction and got it right, which is why stopping worked and starting never
  # did.
  @doc """
  Public only so a test can feed it a handle `Runner.start/3` actually
  produced. Everything else here is private; this one is wire-format
  translation between two modules that were written against different names
  for the same two values, and the round-trip test hand-wrote the correct
  payload — so nothing ever fed the real encoder a real handle.
  """
  def encode_start_result({:ok, %{agent_id: agent_id}}),
    do: %{"status" => "ok", "agent_id" => agent_id}

  def encode_start_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  @doc """
  Tell the server about one step an agent took.

  Cast rather than called: the agent is mid-turn and waiting on nothing here,
  and a server that is slow to take a step must not slow the work down.
  """
  @spec report_turn_event(String.t(), String.t(), map()) :: :ok
  def report_turn_event(root, agent_id, envelope) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:turn_event, agent_id, envelope})
      [] -> :ok
    end
  end

  defp ask_what_to_restore(socket, topic) do
    case transport().push(socket, topic, "agents_to_restore", %{}, decision_timeout()) do
      {:ok, ref} -> assign(socket, :restore_ref, ref)
      {:error, _} -> socket
    end
  end

  # One at a time. Ten agents resuming together is ten model conversations
  # starting at once against one plan and one box — how to pace it properly is
  # an open question, and sequential is the answer that cannot stampede while it
  # is being decided.
  defp restore(agents) do
    Enum.each(agents, fn agent ->
      case CmsHarness.Agents.launch(agent) do
        {:ok, _} ->
          Logger.info("[CmsHarness] restored agent #{agent["agent_id"]}")

        {:error, reason} ->
          Logger.warning(
            "[CmsHarness] could not restore agent #{agent["agent_id"]} in " <>
              "#{agent["working_copy"]}: #{inspect(reason)}"
          )
      end
    end)
  end

  # Whatever the far side called the failure, rendered without assuming it is a
  # word. Atoms and strings keep their shape; a provider's struct is inspected
  # rather than crashing the channel that was trying to report it.
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: to_string(reason)
  defp reason_text(%{error: error}) when is_binary(error), do: error
  defp reason_text(reason), do: inspect(reason)

  @doc """
  One Alloy turn event, as it goes on the wire.

  Only what a watcher needs, and only things that survive JSON. An envelope
  carries atoms, pids and the whole turn state; sending it whole would put an
  agent's entire context on the wire once per step.

  Public because it is the wire shape, and anything else that has to produce
  one — a criterion driving the whole path with no socket in between — must
  produce this one rather than a second version of it that drifts.
  """
  @spec encode_turn_event(map()) :: map()
  def encode_turn_event(%{event: :compacted} = envelope) do
    # Not a step, and not text. What survived a compaction is the thing the
    # server has to keep, and flattening it into a `"text"` field the way every
    # other event is flattened would leave a checkpoint that reads back as
    # `inspect/1` output.
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
      # Only a delivery event has one, and for that event it is the whole
      # message: this named thing is no longer withdrawable.
      "ref" => Map.get(envelope, :ref),
      "text" => turn_event_text(envelope),
      # The call as data, beside the sentence describing it.
      #
      # `text` is prose for a person watching, and it is all that used to
      # travel: a tool call reached the transcript as its own name, arguments
      # gone. Two things needed the structure. An agent's edits cannot be
      # attributed from a rendered line, and `block_changed` therefore could
      # never narrow for an agent with no session. And the page had nothing to
      # render as a tool call, so it drew one as a chat message.
      "tool" => tool_meta(envelope)
    }
  end

  # Deliberately not the whole `input`.
  #
  # A `write` call's input carries the entire file body. Putting that on the
  # wire and into a message row would grow the transcript by the size of
  # everything the agent has ever written — the same unbounded-growth shape that
  # filled this machine's disk on 2026-09-03, and the reason `agent_test_events`
  # now has a byte cap. What is needed is the identity of the call and the path
  # it touched; the body is already on disk, which is the point of a write.
  defp tool_meta(%{payload: %{name: name} = payload}) when is_binary(name) do
    %{
      "id" => Map.get(payload, :id),
      "name" => name,
      "path" => touched_path(Map.get(payload, :input)),
      "input" => bounded_input(Map.get(payload, :input)),
      "error" => error_text(Map.get(payload, :error))
    }
  end

  defp tool_meta(_envelope), do: nil

  # The path a call names, when it names one.
  #
  # Narrower than `primary_argument/1`, which also answers for `command`,
  # `pattern`, `query` and `url` — right for a human-readable line and wrong
  # here, where a non-path would be recorded as a file this agent edited.
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

  # The arguments, as `Conversations.add_tool_call/5` already stores them — the
  # same `{id, name, arguments}` shape `Chat.Runner` and the sprite recorder
  # write, so the conversation view renders an internal agent's calls the way it
  # already renders everybody else's rather than as chat lines.
  #
  # Bounded per value, which the external path does not need to be: its
  # arguments come back from the provider and are bounded by the model's own
  # context. These come from a local tool, and a `write` call's `content` is the
  # whole file — the difference between recording what an agent did and
  # recording a second copy of the repository in the message table.
  @max_argument_bytes 2_000

  defp bounded_input(input) when is_map(input) do
    Map.new(input, fn {key, value} -> {key, bound(value)} end)
  end

  defp bounded_input(_input), do: %{}

  defp bound(value) when is_binary(value) and byte_size(value) > @max_argument_bytes do
    kept = binary_part(value, 0, @max_argument_bytes)
    dropped = byte_size(value) - @max_argument_bytes
    kept <> "… (#{dropped} more bytes)"
  end

  defp bound(value), do: value

  # Why a call failed, when it did. `tool_end` carries the error and no result
  # text — the result itself goes back to the model in the message blocks, not
  # through this channel — so a failure is the one outcome worth recording, and
  # inventing a body for a success would be writing down something nobody said.
  defp error_text(nil), do: nil
  defp error_text(error) when is_binary(error), do: bound(error)
  defp error_text(error), do: error |> inspect() |> bound()

  defp turn_event_text(envelope) do
    case envelope do
      %{name: name} when is_binary(name) -> name
      %{text: text} when is_binary(text) -> text
      %{content: content} when is_binary(content) -> content
      %{payload: %{name: name} = payload} when is_binary(name) -> tool_text(name, payload)
      other -> other |> Map.drop([:v, :seq, :turn, :correlation_id, :event]) |> inspect()
    end
  end

  # A tool call, as a person would say it: `read mix.exs`.
  #
  # The envelope keeps the tool's name and arguments one level down under
  # `:payload`, so the clauses above miss it and the fallback inspects the whole
  # map — which is what a watching operator saw: `%{payload: %{error: nil, id:
  # "call_1", input: %{"file_path" => "mix.exs"}, …}, ts_ms: 1787598792387}`.
  # Watching an agent work is the feature; debug output is not it.
  defp tool_text(name, payload) do
    case primary_argument(Map.get(payload, :input)) do
      nil -> name
      argument -> "#{name} #{argument}"
    end
  end

  # The one argument worth putting beside the tool's name. A tool call has
  # several and only one of them says what the call is about — the path being
  # read, the command being run. Anything else is left off rather than
  # flattened into the line, because a whole argument map is the thing this
  # exists to stop printing.
  # String and atom keys both, because a tool's arguments arrive decoded from
  # JSON on one path and built in memory on another. The pairs are written out
  # rather than derived with `String.to_existing_atom/1`: that raises on a name
  # nothing has interned yet, and raising inside a reporter would turn a
  # cosmetic problem into a lost step.
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

  # Started or queued, which is the whole answer: the difference is whether the
  # sender can still take it back.
  defp encode_send_result({:ok, disposition}) when disposition in [:started, :queued],
    do: %{"status" => "ok", "disposition" => to_string(disposition)}

  defp encode_send_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  # `already_delivered` travels as its own status rather than as an error
  # string. It is not a failure — the agent has the message — and whoever asked
  # has to be able to tell it from "the machine could not be reached", because
  # one means the agent is acting on it and the other means nobody knows.
  defp encode_withdraw_result(:ok), do: %{"status" => "ok"}

  defp encode_withdraw_result({:error, :already_delivered}),
    do: %{"status" => "already_delivered"}

  defp encode_withdraw_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  defp encode_message_result({:ok, reply}) when is_binary(reply),
    do: %{"status" => "ok", "reply" => reply}

  defp encode_message_result({:ok, other}),
    do: %{"status" => "ok", "reply" => inspect(other)}

  defp encode_message_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  defp encode_create_result({:ok, %{root: root, working_copy_id: id}}),
    do: %{"status" => "ok", "root" => root, "working_copy_id" => id}

  defp encode_create_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  defp encode_stop_result(:ok), do: %{"status" => "ok"}

  defp encode_stop_result({:error, reason}),
    do: %{"status" => "error", "reason" => reason_text(reason)}

  defp encode_fs_result(:ok), do: %{"ok" => true}
  defp encode_fs_result({:ok, result}), do: %{"ok" => true, "result" => result}
  defp encode_fs_result({:error, reason}), do: %{"error" => to_string(reason)}

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

    # Always reschedule, `refused` or not. This used to return here when the
    # flag was set, which made a refusal followed by a disconnect permanent: the
    # refusal path reschedules, but a socket that then drops landed here and
    # scheduled nothing, so the subtree sat refusing every hook with "the server
    # is answering but this harness cannot hold a socket to it" until somebody
    # restarted the process. Two subtrees in one harness went through the same
    # server restart and only the one that had never been refused came back.
    #
    # Nothing about a refusal makes reconnecting wrong — it means another
    # process holds `_build`, which it releases when it exits, so waiting and
    # retrying is the whole correct response. `:refused` is for the health
    # endpoint to say *why* nothing is being served.
    Process.send_after(self(), :reconnect, delay)
    {:ok, update(socket, :attempts, &(&1 + 1))}
  end

  @impl Slipstream
  # The answer to a `message_agent`, handed back by the task that ran the turn.
  # Pushed from here rather than from that task, because this process owns the
  # socket.
  def handle_info({:agent_message_result, topic, ref, result}, socket) do
    push(
      socket,
      topic,
      "agent_message_result",
      Map.put(encode_message_result(result), "ref", ref)
    )

    {:noreply, socket}
  end

  def handle_info({:create_working_copy_result, topic, ref, result}, socket) do
    push(
      socket,
      topic,
      "create_working_copy_result",
      Map.put(encode_create_result(result), "ref", ref)
    )

    {:noreply, socket}
  end

  def handle_info({:tool_call_result, topic, ref, result}, socket) do
    push(socket, topic, "tool_call_result", Map.put(encode_tool_result(result), "ref", ref))

    {:noreply, socket}
  end

  def handle_info(:refresh_read_model, %{assigns: %{joined: true, topic: topic}} = socket) do
    schedule_read_model_refresh()

    case transport().push(socket, topic, "read_model", %{}, decision_timeout()) do
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
  # timeout against an address that may be a dead tunnel, and the channel
  # process is what carries hook decisions and analyzer replies. Blocking it for
  # five seconds a minute would make a dead preview look like a slow harness.
  def handle_info(:measure_preview, %{assigns: %{joined: true}} = socket) do
    schedule_preview_check()
    root = socket.assigns.project.root

    Task.Supervisor.start_child(Sync.task_supervisor(root), fn ->
      Sync.measure_preview(root)
    end)

    {:noreply, socket}
  end

  def handle_info(:measure_preview, socket) do
    schedule_preview_check()
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info(:reconnect, socket) do
    case Config.socket_url(socket.assigns.project.root) do
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

        socket
        |> assign(:pending, pending)
        |> update(:silences, &(&1 + 1))
        |> drop_socket_if_silent()
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Consecutive hook decisions the server never answered.
  #
  # One is a slow server. Two, with nothing answered in between, is a channel
  # that is not carrying traffic — and nothing else will ever say so. No close
  # arrives, no error reply arrives, so `joined` stays true, `connected?/1` keeps
  # answering yes, and every hook refuses `:no_reply` until somebody restarts the
  # harness by hand. On 2026-08-07 that ran six minutes: four manifests pushed
  # with no reply and roughly fifteen hooks refused, while a second harness on
  # the same working copy was being served normally by the same live server.
  #
  # This is the silence twin of `maybe_rejoin/2`, which handles the case where
  # the server *says* the topic is unmatched. Silence needs its own detector
  # precisely because nothing is said.
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
  def handle_call(:connected?, _from, socket) do
    {:reply, socket.assigns.joined, socket}
  end

  # Seconds since the server last answered anything, or nil if it never has.
  #
  # `connected?/1` reports `socket.assigns.joined`, which is this process's own
  # belief about its socket and is set at join. It cannot be wrong from where it
  # stands, and it is exactly what was reported as `connected: true` while the
  # server's registry held no entry for this harness and every request it sent
  # answered `:harness_unreachable`. Both ends said healthy; nothing did a round
  # trip.
  #
  # This is evidence rather than belief: a reply is proof the server addressed
  # us, because it is the server that sent it. Recorded passively on replies
  # that already happen, so asking costs nothing and cannot hang — a health
  # check that blocks on the network is its own outage.
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
           decision_timeout()
         ) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, decision_timeout())
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
    case push(socket, socket.assigns.topic, "analysis_wait", %{}, analysis_timeout()) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, analysis_timeout())
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
           analysis_timeout()
         ) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:reply_timeout, ref}, analysis_timeout())
        {:noreply, put_in(socket.assigns.pending[ref], {from, timer})}

      {:error, _reason} ->
        {:reply, {:error, :not_connected}, socket}
    end
  end

  # One step of a turn, on its way to whoever is watching.
  #
  # Not `record_turn` above, though they share a wire. That carries a finished
  # request/response pair for a Claude Code lane, keyed by session id, recorded
  # after the fact. This carries a single step, keyed by the agent, while the
  # turn is still running — which is what makes watching possible and what a
  # completed-turn recording cannot do for a turn that never completes.
  @impl Slipstream
  def handle_cast({:turn_event, agent_id, envelope}, %{assigns: %{joined: true}} = socket) do
    push(socket, socket.assigns.topic, "agent_turn_event", %{
      "agent_id" => agent_id,
      "event" => encode_turn_event(envelope)
    })

    {:noreply, socket}
  end

  # Not joined, so there is nowhere to send it. Dropped rather than queued, for
  # the same reason as `record_turn`: a backlog of steps replayed after a
  # reconnect reads as the agent doing them now.
  def handle_cast({:turn_event, _agent_id, _envelope}, socket), do: {:noreply, socket}

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

  def handle_cast({:module_name, name}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "module_name",
           %{"module_name" => name},
           decision_timeout()
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
           decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send health_route_status: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:health_route_status, _status}, socket), do: {:noreply, socket}

  def handle_cast({:head_commit, sha}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "head_commit",
           %{"sha" => sha},
           decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send head_commit: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:head_commit, _sha}, socket), do: {:noreply, socket}

  def handle_cast({:git_state, state}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "git_state",
           state,
           decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send git_state: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:git_state, _state}, socket), do: {:noreply, socket}

  def handle_cast({:preview_status, status}, %{assigns: %{joined: true}} = socket) do
    case transport().push(
           socket,
           socket.assigns.topic,
           "preview_status",
           %{"status" => status},
           decision_timeout()
         ) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[CmsHarness] could not send preview_status: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_cast({:preview_status, _status}, socket), do: {:noreply, socket}

  def handle_cast({:promotion_result, topic, ref, result}, %{assigns: %{joined: true}} = socket) do
    push(socket, topic, "fs_result", Map.put(encode_fs_result(result), "ref", ref))
    {:noreply, socket}
  end

  # Disconnected before the work finished. Nothing to push to, and the server's
  # own call times out and says so — better than a reply into a closed socket.
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
  defp transport, do: Transport.impl()

  # This working copy is already being served. Usually by the process this one is
  # replacing, still on its way out — so the first few attempts say so quietly
  # and the backoff handles it.
  #
  # It never stops trying. The refusal is about `_build`, which one process holds
  # and releases when it exits, so waiting is exactly the right response and the
  # capped backoff makes it cheap. `:refused` is kept for the health endpoint to
  # report *why* nothing is being served; it no longer gates the reconnect.
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
      {id, %{module_name: MapAccess.get(component, :module_name)}}
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
