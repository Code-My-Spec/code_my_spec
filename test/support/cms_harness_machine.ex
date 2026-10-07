defmodule CmsHarnessTest.Machine do
  @moduledoc """
  Drive a real harness from a spex: announce the machine, look at its
  checkouts, start and stop a real process group.

  This is one function in its own module because of where the boundary runs.
  Story 892's criteria are about "the machine looked and told us", so they have
  to drive `CmsHarness.WorkingCopyReporter` itself rather than write
  `path_missing_since` and assert the column can be set. But `CodeMySpecSpex`
  may not reference `CmsHarness` — the dependency runs the other way — and
  calling it from a spex helper compiled a forbidden-reference warning, which
  the analyzer treats as reason to skip exunit, credo and spex entirely. One
  misclassified line holds back every other check.

  `CodeMySpecSpex.Fixtures` is the wrong home for it: that bridge is for
  app-level DB setup that originates server-side, and its deps deliberately
  exclude the harness. `CmsHarnessTest` already exists as the harness-side
  crossing, so the two are symmetric — app state through `Fixtures`, harness
  surfaces through here.
  """
  alias CmsHarness.Agents
  alias CmsHarness.Device
  alias CmsHarness.WorkingCopyReporter

  @doc """
  Report on `reporter`'s checkouts, with `file` as this machine's identity.

  The two arguments travel together on purpose. `CmsHarness.Device` reads the
  identity path out of application env, which is global, so with two harnesses
  in one criterion whichever started last would own the identity and both would
  announce as the same machine — in the criterion about telling two machines
  apart. Setting it here means no caller has to remember the ordering.
  """
  @spec report(pid() | atom(), String.t()) :: %{optional(String.t()) => boolean()}
  def report(reporter, file) do
    Application.put_env(:code_my_spec, :device_config_path, file)
    WorkingCopyReporter.report(reporter)
  end

  @doc """
  A supervisable reporter for `copies`, under a name unique to this criterion.

  The child spec is built here rather than in the spex because naming
  `CmsHarness.WorkingCopyReporter` is itself the crossing — Boundary flags
  cross-boundary *calls*, so a bare module name in a child spec passes the
  check and still puts the harness in a spex's hands.
  """
  @spec reporter(map()) :: {Supervisor.child_spec(), module()}
  def reporter(copies) do
    name = Module.concat(WorkingCopyReporter, "Spex#{System.unique_integer([:positive])}")
    # Reports only when the spex asks, so its first report is its first exchange.
    {Supervisor.child_spec({WorkingCopyReporter, name: name, known: copies, first_report: :never},
       id: name
     ), name}
  end

  @doc """
  Announce this machine, exactly as starting the harness does.

  Story 1020's criterion 2846 is "starting the harness is what onboards the
  machine", so its `when_` has to be this call and not a stand-in for it.
  """
  @spec announce() :: term()
  def announce, do: Device.announce()

  @doc """
  Start a real agent on this machine, under the id the server knows it by.

  Story 1023's criteria are about whether an agent stops *spending*, which a
  thing that does not exist cannot demonstrate — three shipped instances of that
  defect all passed tests with nothing running in them.

  It used to start an OS process group. An agent is a supervised process now, so
  this starts one of those: real, registered, and reachable by the same id the
  server would use.

  A provider is contacted only when something chats to it. Pass `:base_url` and
  it is `CmsHarnessTest.HeldProvider` on localhost; leave it off and nothing
  should ever run a turn on this agent, because the default is z.ai for real.
  """
  @spec start_agent(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_agent(agent_id, working_copy, opts \\ []) do
    ensure_supervisor()

    Agents.launch(%{
      "agent_id" => agent_id,
      "api_key" => Keyword.get(opts, :api_key, "unused-in-spex"),
      "working_copy" => working_copy,
      "on_stop" => Keyword.get(opts, :on_stop),
      # Where the model is. Without one the agent talks to z.ai for real, which
      # is right in production and would be a live call from a criterion — so
      # anything that actually runs a turn passes a local endpoint here.
      "base_url" => Keyword.get(opts, :base_url),
      "on_event" => Keyword.get(opts, :on_event),
      "on_draft" => Keyword.get(opts, :on_draft),
      # In front of the provider's HTTP client, for the one test that records a
      # real turn. Everything else leaves it off and never reaches a provider.
      "req_options" => Keyword.get(opts, :req_options),
      "provider" => Keyword.get(opts, :provider, "zai")
    })
  end

  @doc """
  One turn event, encoded the way the harness puts it on the wire.

  Through the harness's own encoder rather than a second one written here: two
  versions of a wire shape is one that drifts, and the one that drifts is the
  one nothing is checking.
  """
  @spec encode_turn_event(map()) :: map()
  defdelegate encode_turn_event(envelope), to: CmsHarness.Project.ChannelClient

  @doc """
  The harness's draft buffer, for a relay that has to produce the `agent_draft`
  payloads a machine sends. Same reason as `encode_turn_event/1`: one wire
  shape, not a second copy of it.
  """
  defdelegate new_draft_buffer(), to: CmsHarness.Project.DraftBuffer, as: :new

  defdelegate add_draft(buffer, agent_id, turn, text),
    to: CmsHarness.Project.DraftBuffer,
    as: :add

  defdelegate settle_draft(buffer, agent_id, event),
    to: CmsHarness.Project.DraftBuffer,
    as: :settle

  defdelegate take_drafts(buffer), to: CmsHarness.Project.DraftBuffer, as: :take

  @doc """
  Give an agent something to do, without waiting for the turn.

  The same call the server makes over the channel. `ref` is the handle a
  withdrawal names it by.
  """
  @spec send_message(String.t(), String.t(), String.t()) ::
          {:ok, :started | :queued} | {:error, term()}
  def send_message(agent_id, ref, text) do
    ensure_supervisor()
    Agents.send_message(agent_id, ref, text)
  end

  @doc "Take back a message the agent has not picked up."
  @spec withdraw(String.t(), String.t()) :: :ok | {:error, term()}
  def withdraw(agent_id, ref) do
    ensure_supervisor()
    Agents.withdraw(agent_id, ref)
  end

  @doc "Whether this agent is mid-turn, and what is stacked behind it."
  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  def status(agent_id) do
    ensure_supervisor()
    Agents.status(agent_id)
  end

  @doc """
  Wait until the agent has nothing in flight and nothing queued.

  What makes a claim about delivery settleable. "The message was not delivered"
  is only true of an agent that has finished deciding — asked a moment too
  early it is true of every message, including one about to go out.

  Polled rather than pushed because the engine has no seam to announce this on,
  and inventing one for a test would be a worse trade than a bounded wait
  against its own status call.
  """
  @spec await_idle(String.t(), timeout()) :: :ok
  def await_idle(agent_id, timeout \\ 5_000) do
    ensure_supervisor()
    await_idle(agent_id, timeout, System.monotonic_time(:millisecond))
  end

  defp await_idle(agent_id, timeout, started) do
    case Agents.status(agent_id) do
      {:ok, %{busy?: false, queued: 0}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) - started > timeout do
          raise "agent #{agent_id} was still working after #{timeout}ms"
        end

        receive do
        after
          10 -> await_idle(agent_id, timeout, started)
        end
    end
  end

  @doc """
  Bring an agent up from a request the server built.

  `start_agent/3` assembles one here, which is right for a criterion that only
  needs *an* agent running. This takes the map the server actually sent — with
  its credential and the conversation so far — for criteria whose claim is about
  what a launch carries rather than that one happened.
  """
  @spec launch(map()) :: {:ok, map()} | {:error, term()}
  def launch(request) do
    ensure_supervisor()
    Agents.launch(request)
  end

  @doc """
  Every agent this machine is running right now, by id.

  Read from the registry rather than from anything we were told, so it cannot
  disagree with what is actually alive.
  """
  @spec running() :: [String.t()]
  def running do
    ensure_supervisor()
    Agents.running()
  end

  @doc """
  What one agent knows — the turns its loop is holding.

  Distinct from its transcript, which is what was written down. The two come
  apart exactly when an agent has been restarted, which is the case worth being
  able to ask about.
  """
  @spec history(String.t()) :: {:ok, [Alloy.Message.t()]} | {:error, :not_running | :busy}
  def history(agent_id) do
    ensure_supervisor()
    Agents.history(agent_id)
  end

  @spec stop_agent(String.t()) :: :ok | {:error, :not_running}
  def stop_agent(agent_id) do
    ensure_supervisor()
    Agents.halt(agent_id)
  end

  @doc "Stop only the harness tree owned by a scenario's temporary checkout."
  @spec stop_copy(String.t()) :: :ok
  def stop_copy(root) do
    if Process.whereis(CmsHarness.Registry) do
      case CmsHarness.Copy.Supervisor.stop(root) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end

    :ok
  end

  @doc "Whether this machine is running that agent right now."
  @spec running?(String.t()) :: boolean()
  def running?(agent_id) do
    ensure_supervisor()
    agent_id in Agents.running()
  end

  @doc """
  Make sure the tree an agent lives in exists — the whole of it.

  An agent is supervised under its copy (`CmsHarness.CopiesSupervisor` →
  `CmsHarness.Copy.Supervisor`) and registered in `CmsHarness.Registry`, and it
  needs both: without the registry, starting one raises `unknown registry` from
  inside the `:via` tuple.

  ## Why this boots `CmsHarness.Supervisor` rather than its two children

  It used to start `CmsHarness.Registry` and `CmsHarness.CopiesSupervisor`
  directly, on the reasoning that a spex run starts neither and those were the
  two an agent needs. That left the tree *half* built, and both halves of the
  damage are reproducible:

    * `CmsHarness.Supervisor` was left unnamed while its two globally named
      children were alive. A later file calling
      `Projects.ensure_harness_supervisor_started/0` — which guards on the
      supervisor's own name — found it unregistered and booted a fresh tree
      whose first child, `{Registry, name: CmsHarness.Registry}`, could not
      start. `Supervisor.start_link/2` *exits* the caller rather than returning
      an error tuple, so it arrived as `EXIT from #PID<…> shutdown: failed to
      start child: CmsHarness.Registry` with no stacktrace naming the caller.
      Story 704's criterion_1484 (a `Machine` file) then criterion_431 (an
      `ensure_live_harness` file): 1 failure in that order, 0 the other way.

    * The children it skipped are not optional. `CmsHarness.Web.Endpoint` is a
      child of `CmsHarness.Supervisor`, and the live-harness path posts hooks
      through it — so with only the two hand-started children up, a later file
      failed with `could not find persistent term for endpoint
      CmsHarness.Web.Endpoint`.

  One idempotent call to the supervisor gives every caller the same tree, and
  keeps what the hand-starting was for: unlinked, so the tree outlives the
  scenario that happened to start it.
  """
  @spec ensure_supervisor() :: :ok
  def ensure_supervisor do
    case CmsHarness.Supervisor.start_link([]) do
      {:ok, pid} ->
        # Unlinked on purpose, and the same reason the two hand-starts it
        # replaced were: linked, the tree dies with whichever scenario started
        # it, and the next one either raises `unknown registry` or starts a
        # second tree while agents live in the first.
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
