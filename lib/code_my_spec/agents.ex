defmodule CodeMySpec.Agents do
  @moduledoc """
  The agents CodeMySpec has started, and the credential each one runs on.

  Server-side half of starting a coding agent. Owns which agents exist, on which
  working copy and on which provider; mints the per-copy Pi configuration from
  the account's integration; and holds the record a conversation attaches to.
  `CmsHarness.Agents` is the other half — the OS process on the device — reached
  over the harness channel. Same split as Provisioning: state and ordering live
  here, execution happens on the box, because the server holds no disk and
  cannot start a process on somebody's machine.

  ## Starting is refused before it is attempted

  `start_agent/2` resolves the credential first and refuses if there is not a
  usable one. That ordering is the point rather than an optimisation. An agent
  started without a working credential fails on its first model call — minutes
  later, in a log nobody is reading — which is why `agent.sh` ended up grepping
  its own output for expired-session text and bailing: retrying an
  unauthenticated agent burns twelve minutes to reach the same answer with the
  cause buried under supervisor noise.

  The two refusals are kept apart for the same reason. `:not_connected` sends
  someone to connect a provider; `:reconnect_required` sends them to reconnect
  one they know they connected. Reporting the second as the first sends them to
  set up something that already exists.

  ## Started means watchable

  A pid proves a fork. It does not prove the credential resolved, that a model
  answered, or that the harness was ever joined, and every one of those failures
  is quiet from the caller's side. So an agent is recorded `:starting` and only
  becomes `:running` when the device says it is — and its turns arrive in
  `Conversations` the same way a Claude Code agent's do, through
  `AgentHarness.relay_up/2`. An agent the server cannot observe is
  indistinguishable from one that never started.
  """

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Transport

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Credential
  alias CodeMySpec.Agents.Providers
  alias CodeMySpec.Conversations
  alias CodeMySpec.Users.Scope

  # How long the machine is given to wind the agent down before it insists.
  # Bounded on purpose: an unbounded stop is one the meter outlives.
  # A turn is a model call. Long enough for real work, short enough that a
  # wedged agent does not hold a caller forever.
  @message_timeout_ms 180_000

  @stop_timeout_ms 10_000

  # Long enough for a cold start on a loaded box, short enough that a machine
  # that is never going to answer does not hold the caller.
  @start_timeout_ms 15_000

  # Shorter than an operator's stop. This runs inside a reconcile that fires on
  # every lane diff, so a machine that is slow to answer must not hold it —
  # the next report tries again, and the row stays reachable meanwhile.

  @type start_error ::
          :missing_active_project
          | :not_connected
          | :reconnect_required
          | :unknown_provider
          | Ecto.Changeset.t()
          | term()

  @doc """
  Subscribes to scoped notifications about agents.

    * {:agent_started, %Agent{}}
    * {:agent_stopped, %Agent{}}
  """
  def subscribe(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(scope))
  end

  defdelegate list_agents(scope), to: AgentsRepository
  defdelegate list_running(scope), to: AgentsRepository
  defdelegate fetch_agent(scope, id), to: AgentsRepository
  defdelegate providers(), to: Providers, as: :names

  @doc """
  Starts an agent on a working copy, on the provider the caller named.

  The provider is an argument rather than ambient state. A machine-wide default
  answers correctly right up until two callers want different things, and then
  spends the wrong subscription for one of them — which nobody notices until a
  quota or a bill does.
  """
  @spec start_agent(Scope.t(), map()) :: {:ok, Agent.t()} | {:error, start_error()}
  def start_agent(%Scope{} = scope, %{provider: provider} = attrs) do
    with {:ok, credential} <- Credential.fetch(scope, provider),
         {:ok, agent} <- AgentsRepository.create_agent(scope, base_attrs(scope, attrs)),
         {:ok, _conversation} <- open_conversation(scope, agent) do
      # Carried on the struct rather than stored: the machine needs it, the row
      # must not become a second place a subscription lives.
      agent = launch(scope, %{agent | credential: credential})
      broadcast(scope, {:agent_started, agent})
      {:ok, agent}
    end
  end

  # Ask the machine to bring it up, and record what it reports.
  #
  # Best-effort on purpose, and the row already has a word for the outcome.
  # `:starting` means "we asked and no machine has confirmed", which is exactly
  # true when the copy's harness is not connected — and the working copies page
  # already renders it as "Starting · we asked for this one; no harness has
  # confirmed it". Failing the whole call instead would make an agent
  # unstartable whenever its machine happened to be offline, and would discard
  # the config directory that was just minted for it.
  defp launch(scope, %Agent{} = agent) do
    case Transport.impl().start_agent(agent.working_copy_id, agent, @start_timeout_ms) do
      {:ok, report} -> record_or_keep(scope, agent, report)
      {:error, reason} -> keep_starting(agent, reason)
    end
  end

  defp record_or_keep(scope, agent, report) do
    case record_started(scope, agent, report) do
      {:ok, running} -> running
      {:error, _reason} -> agent
    end
  end

  defp keep_starting(agent, reason) do
    Logger.info(
      "[Agents] agent #{agent.id} was not started on its machine (#{inspect(reason)}); " <>
        "it stays :starting, which is what the page shows as asked-for and unconfirmed"
    )

    agent
  end

  # An agent that cannot be watched is indistinguishable from one that never
  # started, so the conversation is opened as part of starting rather than when
  # the agent first says something. A Pi lane relays its turns up through
  # `AgentHarness.relay_up/2` into this same conversation, which is why a Pi
  # agent and a Claude Code agent land on one surface instead of two.
  #
  # Keyed by the working copy, not the agent id, because that is how a Pi lane
  # keys itself: `CodeMySpecLocalWeb.HarnessSocket` uses `pi:<cwd>` and the
  # conversation index renders it as `data-session`.
  #
  # Keying on the agent id instead produced a row reading `agent:<uuid>`, which
  # is unreadable the moment a project has more than one copy — QA had three at
  # once and could not tell them apart (18f50c87). It also split one copy's
  # transcript in two: the lane reporting over the channel wrote to
  # `pi:<cwd>` while the tool that started it wrote somewhere else, so the
  # agent's own turns did not land on the session that represented it.
  #
  # One conversation per working copy matches the harness's own model, where
  # every lane on a copy joins `harness:session:pi:<cwd>` and the whole team's
  # transcript lands together.
  defp open_conversation(%Scope{} = scope, %Agent{} = agent) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      "pi:#{agent.working_copy}"
    )
  end

  @doc """
  Give a running agent something to do.

  The capability the engine change was chosen for, and the one that was missing
  after it: an agent could be started, listed and stopped, and never asked to do
  anything, so it idled until somebody stopped it.

  Answers with whatever the agent said. An agent that is not running, or whose
  machine cannot be reached, is an error rather than a silent nothing — an
  instruction that went nowhere and reported success is worse than one that
  failed.
  """
  @spec message_agent(Scope.t(), Ecto.UUID.t(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def message_agent(%Scope{} = scope, id, text, timeout \\ @message_timeout_ms)
      when is_binary(text) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id) do
      Transport.impl().message_agent(agent.working_copy_id, agent, text, timeout)
    end
  end

  @doc """
  Record what a harness reports it is actually running.

  `list_running/1` answers from the database — the agents we asked for. This is
  the other half: the set the device says it has, which is the only half that
  can spend a subscription. Anything the report omits is marked stopped.

  ## Why the device is the authority and we are not

  The harness already knows this without being asked. A lane is joined to
  `harness:session:<external_id>` for exactly as long as it is alive, and
  Presence is that fact — story 704 replaced a polled subagent-TTL registry with
  it precisely because a liveness record maintained by hand drifts from the
  processes it claims to describe. So the report is a projection of Presence,
  and an agent whose process died is absent from it without anybody having to
  notice or send anything.

  That is also what makes the orphan case real rather than arranged: nothing
  simulates the death, the lane simply stops being joined.
  """
  @spec record_reported(Scope.t(), [map()]) :: {:ok, [Agent.t()]}
  def record_reported(%Scope{} = scope, reported) when is_list(reported) do
    adopted = reported |> Enum.map(&adopt(scope, &1)) |> Enum.reject(&is_nil/1)
    Enum.each(adopted, &ensure_conversation(scope, &1))
    alive = MapSet.new(adopted, & &1.id)

    # The server half of `[LaneReporter]`. Both sides log because the two
    # failures look identical from either one alone: a report that was never
    # sent and a report that arrived and reconciled to nothing both leave the
    # page showing every checkout idle. Interleaving the pair is what tells them
    # apart, which is what the log table in CLAUDE.md exists for.
    Logger.info("[Agents] harness reported #{length(reported)} agent(s)")

    running =
      scope
      |> AgentsRepository.list_running()
      |> Enum.map(&reap_if_absent(scope, &1, MapSet.member?(alive, &1.id)))
      |> Enum.filter(&(&1.status in [:starting, :running]))

    # A report is the only moment the server learns an agent went away, so it is
    # the only moment a page watching one can find out. Without this the row
    # keeps claiming an agent is working until somebody reloads, which is the
    # stale-row failure the reconcile exists to prevent, moved to the browser.
    broadcast(scope, {:agents_reported, running})

    {:ok, running}
  end

  # A reported agent the server has no row for is adopted rather than refused.
  #
  # The harness is the authority on what is running, and it can be running
  # something we did not start — a lane an engineer launched by hand, or one
  # that survived a server restart. Refusing those would make the server's list
  # a record of its own requests rather than of what exists, which is the
  # distinction this whole reconcile is about.
  #
  # Keyed on the working copy's **id** and the lane's role.
  #
  # The role half: a checkout runs one or more agents, the harness tells them
  # apart by role, and finding "the copy's agent" made a second lane overwrite
  # the first — one row flickering between two engines instead of two rows.
  #
  # The id half: the copy used to be matched by comparing the reported path to
  # `harnesses.root`, which is also a reported path. Two strings that are meant
  # to be equal and are produced independently do not stay equal, and two
  # harness rows can share a root outright. The device knows which harness id it
  # holds — it wrote the file — so it says so, and nothing here guesses.
  defp adopt(%Scope{} = scope, report) when is_map(report) do
    adopt(scope, reported_copy_id(report), report)
  end

  # Both names, new one first — the compatibility window every other reader on
  # this wire already honours, and this one had been left out of it.
  defp reported_copy_id(%{"working_copy_id" => id}) when is_binary(id) and id != "", do: id
  defp reported_copy_id(%{"harness_id" => id}) when is_binary(id) and id != "", do: id
  defp reported_copy_id(_report), do: nil

  defp adopt(%Scope{} = scope, working_copy_id, report)
       when is_binary(working_copy_id) do
    role = role(report)

    scope
    |> AgentsRepository.list_agents()
    |> Enum.find(&(&1.working_copy_id == working_copy_id and &1.role == role))
    |> upsert(scope, report)
  end

  # A report that names no working copy is refused rather than guessed at. It
  # would otherwise create an agent attached to nothing, which renders nowhere
  # and reaps nothing — a row that exists only to be wrong.
  defp adopt(_scope, nil, report) do
    Logger.warning(
      "[Agents] ignoring a reported agent with no working copy id: #{inspect(report)}"
    )

    nil
  end

  defp upsert(nil, scope, report) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: engine(report),
        provider: report["provider"] || "unknown",
        working_copy: report["working_copy"],
        role: role(report),
        working_copy_id: reported_copy_id(report),
        os_pid: report["os_pid"],
        status: :running
      })

    agent
  end

  defp upsert(%Agent{} = agent, scope, report) do
    {:ok, updated} =
      AgentsRepository.update_agent(scope, agent, %{
        engine: engine(report),
        status: :running,
        os_pid: recorded_group_or_reported(agent, report)
      })

    updated
  end

  # What we recorded at launch wins over what a lane reports about itself.
  #
  # They are different things. The launcher records a process *group* id, so one
  # signal takes the agent and every tool it spawned; a lane reports its own pid,
  # which is one member of that group. Letting the report overwrite it would
  # quietly downgrade every stop to killing a single process and leaving the
  # tree — the exact failure the group exists to prevent — and it would strand
  # `os_boot_id`, which was written to go with the group id and nothing else.
  defp recorded_group_or_reported(%Agent{os_pid: pid, os_boot_id: boot}, _report)
       when is_integer(pid) and is_binary(boot),
       do: pid

  defp recorded_group_or_reported(%Agent{} = agent, report),
    do: report["os_pid"] || agent.os_pid

  # The harness says which engine it is running, and it matters downstream: the
  # engine decides whether an agent has presence or only a timestamp, and whether
  # it can be talked to at all. Defaulting every report to `:pi` made a Claude
  # Code agent claim presence it does not have — caught by story 1019's criterion
  # 2830, which exists to keep those two facts apart.
  defp engine(%{"engine" => "claude_code"}), do: :claude_code
  defp engine(_report), do: :pi

  # A harness that names no lane is running one, and "main" is what that one is
  # called. Falling back keeps every report written before roles existed landing
  # on the row it always did, rather than forking a duplicate the first time
  # this ships.
  defp role(%{"role" => role}) when is_binary(role) and role != "", do: role
  defp role(_report), do: "main"

  # An adopted Pi lane gets the same transcript one we started gets.
  #
  # `start_agent/2` opens the conversation as part of starting, on the reasoning
  # that an agent that cannot be watched is indistinguishable from one that
  # never started. Adoption is the *ordinary* way an agent arrives — the harness
  # starts its own lanes and reports them — so leaving those without one made
  # the common case the unwatchable one: the working copy had a live agent and
  # nothing to link at until the lane happened to say something.
  #
  # Keyed `pi:<working_copy>`, the same key the lane pushes under, so the
  # transcript opened here and the one written to are one thread.
  defp ensure_conversation(%Scope{} = scope, %Agent{engine: :pi} = agent) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      "pi:#{agent.working_copy}"
    )
  end

  # A Claude Code agent gets none. There is no lane to route a reply to, and a
  # conversation that exists is a conversation the page offers to open.
  defp ensure_conversation(_scope, _agent), do: :ok

  defp reap_if_absent(_scope, %Agent{} = agent, true), do: agent

  # Absent from a report the machine actually sent.
  #
  # This used to fork: an agent with no group id was recorded stopped, and one
  # with a group id had its machine asked to end it first, because an OS process
  # could outlive the lane that reported it. A supervised agent cannot — the
  # harness reports what its own registry holds, so the lane and the process are
  # the same fact and a report that arrives is the check.
  #
  # The distinction that still matters is upstream of here: no report is not a
  # report of absence. A harness that went quiet says nothing about its agents,
  # and nothing calls this without a report to reconcile against.
  defp reap_if_absent(scope, %Agent{} = agent, false) do
    {:ok, stopped} = record_stopped(scope, agent)
    stopped
  end

  @doc """
  Stops one agent, and only that one.

  Stopping is only useful if it stops the right one: a stop that reaps the tree,
  or kills by name and catches a sibling, looks identical from the caller's side
  and is worse than having no stop at all.
  """
  @spec stop_agent(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Agent.t()} | {:error, :not_found | :cross_project | Ecto.Changeset.t()}
  def stop_agent(%Scope{} = scope, id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <- end_process(scope, agent),
         {:ok, stopped} <- record_stopped(scope, agent) do
      broadcast(scope, {:agent_stopped, stopped})
      {:ok, stopped}
    end
  end

  # Ask the machine holding the process to end it, and let its answer decide
  # whether this is a stop at all.
  #
  # This used to write `status: :stopped, os_pid: nil` and broadcast, which
  # ended nothing. Worse, clearing `os_pid` threw away the only handle anything
  # could have acted on — so an agent that survived the "stop" became
  # permanently unreachable, by the stop. That is criterion 2828 caused by its
  # own remedy.
  #
  # An agent still `:starting` never came up, so there is no process to end and
  # nothing to ask. That is a real state, not an error: it is the row for an
  # agent we asked for and no machine confirmed, and cancelling it has to work.
  #
  # This used to key on `os_pid` being nil. An agent is a supervised process now
  # and never has a group id, so that clause matched every stop: the row went to
  # `:stopped` and nothing was ever asked to end anything. The defect this story
  # exists for, reintroduced by deleting the field its guard happened to read.
  defp end_process(_scope, %Agent{status: :starting}), do: :ok

  defp end_process(_scope, %Agent{} = agent) do
    agent.working_copy_id
    |> Transport.impl().stop_agent(agent, @stop_timeout_ms)
    |> stopped?()
  end

  # An agent the machine is not running is stopped — asking again is how a
  # stop becomes idempotent. A machine that could not be *reached* is not, and
  # collapsing the two is what makes a row say stopped over something still
  # running.
  defp stopped?(:ok), do: :ok
  defp stopped?({:error, :not_running}), do: :ok
  defp stopped?({:error, _reason} = error), do: error

  # Only after something confirmed the process is gone. `os_pid` and
  # `os_boot_id` are cleared here rather than before, because until the process
  # is actually gone they are the only way to reach it again.
  defp record_stopped(scope, agent) do
    AgentsRepository.update_agent(scope, agent, %{
      status: :stopped,
      os_pid: nil,
      os_boot_id: nil
    })
  end

  @doc """
  Records what the device reported back about an agent it was asked to start.

  The machine confirms the id it was asked to run, and that is the whole report.

  It used to be a process **group** id and the boot it belonged to, written
  together because a group id without its boot cannot be told from a recycled
  number naming a stranger's process. A supervised agent needs neither: the id
  was already on the row, and it resolves through the harness's registry for
  exactly as long as the agent is alive.

  So `:running` here means a machine said so, which is the only thing that ever
  made this status trustworthy.
  """
  @spec record_started(Scope.t(), Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, :cross_project | Ecto.Changeset.t()}
  def record_started(%Scope{} = scope, %Agent{} = agent, %{agent_id: _id}) do
    AgentsRepository.update_agent(scope, agent, %{status: :running})
  end

  defp base_attrs(%Scope{} = scope, attrs) do
    %{
      engine: Map.get(attrs, :engine, :pi),
      provider: Map.fetch!(attrs, :provider),
      working_copy: Map.get(attrs, :working_copy) || scope.cwd,
      role: Map.get(attrs, :role, "main"),
      working_copy_id: Map.get(attrs, :working_copy_id) || scope.active_working_copy_id,
      status: :starting
    }
  end

  defp broadcast(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(scope), message)
  end

  defp topic(%Scope{active_project_id: project_id}), do: "agents:#{project_id}"
end
