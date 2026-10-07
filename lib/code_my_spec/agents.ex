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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Agents.Agent,
      CodeMySpec.Agents.RoleProfile,
      CodeMySpec.Analysis,
      CodeMySpec.Analysis.HarnessRegistry,
      CodeMySpec.CodeMode,
      CodeMySpec.Conversations,
      CodeMySpec.FileEdits,
      CodeMySpec.Integrations,
      CodeMySpec.Issues,
      CodeMySpec.Projects,
      CodeMySpec.Provisioning,
      CodeMySpec.PromotionQueue,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.TaskOwner,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.Validation,
      CodeMySpec.Validation.Blocking,
      CodeMySpec.WorkingCopies,
      CodeMySpec.Configurations,
      CodeMySpec.Devices,
      CodeMySpec.Epics,
      CodeMySpec.Faults,
      CodeMySpec.Notifications,
      CodeMySpec.Problems
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Accounts.MembersRepository
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.AppRestart
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.Credential
  alias CodeMySpec.Agents.Defaults
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.LaunchRequest
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Agents.ModelSetting
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.Agents.ProviderRefusal
  alias CodeMySpec.Agents.Providers
  alias CodeMySpec.Agents.RefusalWake
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Agents.TurnTimeout
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Conversations
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies

  # How long we wait for a turn before reporting "still working" instead of
  # blocking further. The agent is not interrupted — this is how long we wait
  # for it, not how long it has.
  #
  # Bounded well below 30s, not just below it. The MCP transport's 30s bare
  # default long ago stopped being the tight constraint here for direct HTTP
  # calls -- `/mcp/harness` carries a 5-minute `request_timeout` (see
  # router.ex) precisely because a real provisioning step runs longer than
  # 30s. What still caps this one is `CodeMySpec.CodeMode.Sandbox`'s own 30s
  # wall clock: `message_agent` is reachable only through `run_script`
  # (`ScriptableTools`, not `LocalServer`'s spine), so every call to it runs
  # inside that sandbox's `Task.shutdown(:brutal_kill)`. A 25s wait left only
  # 5s of margin for Lua overhead, the tool call itself and the response
  # trip back out, and it was too tight in practice -- several real calls in
  # one QA session came back as a raw sandbox kill ("the script ran longer
  # than it is allowed to") instead of this module's own graceful
  # `:still_working`, indistinguishable from a broken tool. Issue ddcff0c8.
  @message_timeout_ms 15_000

  @stop_timeout_ms 10_000

  # Ten, because that is roughly a conversation rather than a session: enough
  # for a visitor to be shown their project works and be answered about it,
  # short of an afternoon on our bill. Configurable, since the right number is
  # a commercial question rather than a technical one.
  @default_turn_cap 10

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
          | {:unknown_working_copy, String.t()}
          | {:role_taken, atom(), Ecto.UUID.t(), String.t() | nil}
          | {:not_at_home, atom(), String.t() | nil}
          | {:main_copy_occupied, atom(), String.t() | nil}
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

  @doc """
  The project's agents whose processes are alive now (`Agents.Presence`),
  whatever anyone intends for them: an agent turned off whose machine has not
  ended it yet is still here, findable and stoppable. `list_on_duty/1` is the
  intent view.
  """
  @spec list_running(Scope.t()) :: [Agent.t()]
  def list_running(%Scope{} = scope),
    do: AgentsRepository.list_by_ids(scope, scope |> present_ids() |> MapSet.to_list())

  defdelegate list_on_duty(scope), to: AgentsRepository
  defdelegate list_for_team_status(scope), to: AgentsRepository
  defdelegate fetch_agent(scope, id), to: AgentsRepository
  defdelegate assign_team(scope, copy_id, story_id), to: Assignment
  defdelegate assign_epic(scope, epic_id, copy_id), to: Assignment
  defdelegate notify_story_team_free(scope, copy_id, story), to: Assignment, as: :notify_team_free
  defdelegate claim_story(scope, agent, story_id), to: Assignment, as: :claim

  defdelegate assign_issue_to_working_copy(scope, issue_id, working_copy_id, opts \\ []),
    to: IssueAssignment,
    as: :assign

  defdelegate free_issue_team(scope, issue), to: IssueAssignment, as: :free
  defdelegate providers(), to: Providers, as: :names

  @doc """
  Mark the agent's open promotion task as awaiting the queue.

  Called by the MCP `promote` tool once `PromotionQueue` has answered `:queued`
  (issue e515bff3, story 1091). Resolves the agent here so the tool needs no
  getter of its own.
  """
  @spec await_promotion(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Agent.t()} | {:error, term()}
  def await_promotion(agent_id, subject_type, subject_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent -> CodeMySpec.TaskOwner.await_promotion(agent, subject_type, subject_id)
      nil -> {:error, :agent_not_found}
    end
  end

  @doc """
  Every task embedded directly on an agent -- rather than on a session --
  that was opened against a story, including tasks opened against the
  story's own linked component (see `Sessions.list_tasks_for_story/3` for
  why `component_id` is matched too).

  An agent run under Alloy has no session and fires no hooks, so its tasks
  live on its own `tasks` embed (`TaskOwner`); `Sessions.list_tasks_for_story/3`
  only ever sees the other kind. `AgentPerformance.CycleTime` reads both.
  """
  @spec list_tasks_for_story(Scope.t(), integer(), Ecto.UUID.t() | nil) :: [map()]
  def list_tasks_for_story(%Scope{} = scope, story_id, component_id \\ nil)
      when is_integer(story_id) do
    scope
    |> list_agents()
    |> Enum.flat_map(fn agent ->
      agent.tasks
      |> List.wrap()
      |> Enum.filter(
        &(&1.story_id == story_id or
            (not is_nil(component_id) and &1.component_id == component_id))
      )
      |> Enum.map(&Map.from_struct/1)
    end)
  end

  @doc """
  Record that a working copy's whole app -- not one agent -- was restarted.

  `RestartApp` has no agent to name, so this cannot go through
  `Conversations.record_restart/2`.
  """
  @spec record_app_restart(Scope.t(), String.t()) ::
          {:ok, AppRestart.t()} | {:error, Ecto.Changeset.t()}
  def record_app_restart(
        %Scope{active_working_copy_id: working_copy_id, active_project_id: project_id},
        reason
      )
      when is_binary(working_copy_id) and is_binary(project_id) and is_binary(reason) do
    %AppRestart{}
    |> AppRestart.changeset(%{
      working_copy_id: working_copy_id,
      project_id: project_id,
      reason: reason
    })
    |> Repo.insert()
  end

  @doc """
  Every app restart on a working copy no agent currently holds a story on --
  the project-level case criterion 1998 describes.
  """
  @spec list_app_restarts_without_story(Scope.t()) :: [AppRestart.t()]
  def list_app_restarts_without_story(%Scope{} = scope) do
    import Ecto.Query, only: [from: 2]

    held =
      scope
      |> list_agents()
      |> Enum.reject(&is_nil(&1.story_id))
      |> MapSet.new(& &1.working_copy_id)

    from(r in AppRestart, where: r.project_id == ^scope.active_project_id)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(held, &1.working_copy_id))
  end

  @doc """
  The agent of this role currently on this working copy, if any.

  A turn arrives on the wire naming a working copy and a role, never an
  agent id (`HarnessProjectChannel`'s `record_turn`) -- one running agent
  per `{working_copy, role}` is the standing assumption the rest of this
  module already makes (`adopt/2`'s own lookup matches the same pair).
  """
  @spec find_by_working_copy_and_role(Scope.t(), Ecto.UUID.t() | nil, String.t() | atom()) ::
          Agent.t() | nil
  def find_by_working_copy_and_role(scope, working_copy_id, role)
  def find_by_working_copy_and_role(_scope, nil, _role), do: nil

  def find_by_working_copy_and_role(%Scope{} = scope, working_copy_id, role) do
    role = to_string(role)

    scope
    |> AgentsRepository.list_agents()
    |> Enum.find(
      &(&1.working_copy_id == working_copy_id and to_string(&1.role) == role and
          is_nil(&1.retired_at))
    )
  end

  @doc """
  What an agent may call: its role's grants as the code states them now, plus
  what its machine reported.

  Derived on each call rather than read off the row. The row's list was written
  at start, so a grant added to a role never reached an agent already running —
  `install_credo_checks` for coding and `read_project_file` for qa sat in
  `ToolSets` while existing agents were refused them (`c5df88e7`).
  """
  @spec tools_of(Scope.t(), Agent.t()) :: [String.t()] | nil
  def tools_of(%Scope{} = scope, %Agent{} = agent),
    do: tools_for(scope, %{role: agent.role, working_copy_id: agent.working_copy_id})

  @doc """
  Starts an agent on a working copy, on the provider the caller named.

  The provider is an argument rather than ambient state. A machine-wide default
  answers correctly right up until two callers want different things, and then
  spends the wrong subscription for one of them — which nobody notices until a
  quota or a bill does.
  """
  @spec start_agent(Scope.t(), map()) :: {:ok, Agent.t()} | {:error, start_error()}
  def start_agent(%Scope{} = scope, attrs) do
    with {:ok, role} <- role_of(attrs),
         {:ok, provider, model} <- provider_for(scope, role, attrs),
         attrs =
           attrs |> Map.put(:role, role) |> Map.put(:provider, provider) |> Map.put(:model, model),
         {:ok, attrs} <- put_destination(scope, attrs),
         :ok <- seat_is_on(scope, attrs),
         :ok <- machine_serves_tools(attrs),
         {:ok, credential} <- Credential.fetch(scope, provider),
         :ok <- copy_is_free(scope, attrs),
         :start <- resume_holder(scope, attrs),
         {:ok, agent} <- AgentsRepository.create_agent(scope, base_attrs(scope, attrs)),
         {:ok, _conversation} <- open_conversation(scope, agent) do
      # Carried on the struct rather than stored: the machine needs both, and
      # the row must not become a second place a subscription lives or a second
      # copy of a transcript that already has a table.
      #
      # Hydrated after the conversation is opened, because that is what the
      # history is read from — an agent that has spoken before is being resumed
      # here even on a call named `start`, which is the whole of "it picks up
      # the same conversation every time".
      with {:ok, agent} <-
             launch(scope, LaunchRequest.hydrate(scope, %{agent | credential: credential})) do
        watch_over(scope, agent)
        broadcast(scope, {:agent_started, agent})
        {:ok, agent}
      end
    end
  end

  # A stopped agent still holding work is resumed, not replaced.
  #
  # `start_agent/2` always created a new row, and a task's ownership *is* which
  # agent's list it sits in (`Agent`'s own note). So an agent killed mid-task —
  # which every promote does, because promoting restarts the shared dev server
  # every working copy on the box is using — left its claims behind on a row
  # nothing would run again. Starting a replacement produced a second agent for
  # the same role and copy that could not claim what the first still held.
  #
  # Measured 2026-09-23 on Broken Oaths: a promote stopped coding `b01a95bb` at
  # 01:50:04 while it held `story_promoted` active on story 950 and a
  # blocked `bdd_specs_passing`. The replacement reported "get_next_requirement's
  # only offering — story 950's story_promoted — is already claimed by
  # another agent" and had nothing else to do. Four other stopped agents on that
  # copy held active tasks the same way. The role was stalled with a live agent
  # sitting next to its own orphaned work.
  #
  # Resuming rather than moving the tasks across is deliberate. Task ids are
  # referenced from outside the row — `question_requests.task_id` is what a
  # blocker is keyed on — and `embeds_many ... on_replace: :delete` means
  # lifting a task out of one list and putting it in another mints a new id and
  # orphans every blocker pointing at the old one. The row already knows how to
  # come back: `restart_agent/2` keeps the tasks, the conversation and the
  # blockers exactly where they are.
  #
  # Only for a holder. A stopped agent with nothing unfinished is genuinely
  # finished, and reviving it instead of starting a clean one would make
  # `start_agent` unable to ever give a role a fresh start.
  defp resume_holder(%Scope{} = scope, attrs) do
    with copy_id when is_binary(copy_id) <- Map.get(attrs, :working_copy_id),
         role when not is_nil(role) <- Map.get(attrs, :role),
         %Agent{} = holder <- stopped_holder(scope, copy_id, role) do
      Logger.info(
        "[Agents] #{role} on #{copy_id} is resuming stopped agent #{holder.id}, which still " <>
          "holds #{length(unfinished(holder))} unfinished task(s), rather than starting beside it"
      )

      restart_agent(scope, holder.id)
    else
      _ -> :start
    end
  end

  defp stopped_holder(%Scope{} = scope, copy_id, role) do
    present = present_ids(scope)

    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(fn agent ->
      not MapSet.member?(present, agent.id) and not Agent.retired?(agent) and
        agent.working_copy_id == copy_id and
        to_string(agent.role) == to_string(role) and unfinished(agent) != []
    end)
    |> Enum.max_by(& &1.updated_at, DateTime, fn -> nil end)
  end

  defp unfinished(%Agent{} = agent),
    do: Enum.filter(agent.tasks || [], &(&1.status in [:active, :blocked]))

  @doc "Every agent on the project somebody turned off, most recent first."
  @spec off_agents(Scope.t()) :: [Agent.t()]
  def off_agents(%Scope{} = scope) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(&Agent.off?/1)
    |> Enum.sort_by(& &1.off_at, {:desc, DateTime})
  end

  @doc """
  The scope a call from `agent` acts in: which working copy is part of who is
  calling (John, ed28189c).

    * No working copy named, and the agent has one in the scope's project — the
      agent's copy, with its environment (`WorkingCopies.put_scope/2`), exactly
      as an `X-Harness-Id` would have set it. An agent-only call over the
      hosted `/mcp/harness` used to carry no environment and every
      file-touching tool refused it with `:no_environment`.
    * A copy named that is not the agent's — the named copy stands: it is the
      connection's own disk. Logged, because the two come from one launch
      request and disagreeing means something upstream is wrong.
    * Otherwise unchanged.
  """
  @spec scope_for(Scope.t(), Agent.t()) :: Scope.t()
  def scope_for(%Scope{active_working_copy_id: nil} = scope, %Agent{working_copy_id: id})
      when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{project_id: project_id} = copy} when project_id == scope.active_project_id ->
        WorkingCopies.put_scope(scope, copy)

      _elsewhere ->
        scope
    end
  end

  def scope_for(
        %Scope{active_working_copy_id: named} = scope,
        %Agent{working_copy_id: own} = agent
      )
      when is_binary(named) and is_binary(own) and named != own do
    Logger.warning(
      "[Agents] agent #{agent.id} called naming working copy #{named} but runs on #{own}; " <>
        "acting on the named copy"
    )

    scope
  end

  def scope_for(%Scope{} = scope, _agent), do: scope

  @doc """
  The Presence topic for a project's agents: one key per agent whose process
  is alive on a harness, tracked by the channel of the copy it runs in
  (`.code_my_spec/plans/agent-liveness-from-presence.md`).
  """
  @spec presence_topic(Ecto.UUID.t()) :: String.t()
  defdelegate presence_topic(project_id), to: Presence, as: :topic

  @doc "The ids of the project's agents whose processes are alive now."
  @spec present_ids(Scope.t()) :: MapSet.t(Ecto.UUID.t())
  def present_ids(%Scope{active_project_id: project_id}), do: Presence.ids(project_id)

  @doc "Whether `agent`'s process is alive now."
  @spec present?(Scope.t() | Ecto.UUID.t() | nil, Agent.t()) :: boolean()
  def present?(%Scope{active_project_id: project_id}, %Agent{id: id}),
    do: Presence.present?(project_id, id)

  def present?(project_id, %Agent{id: id}), do: Presence.present?(project_id, id)

  @doc """
  An agent's lifecycle, derived rather than stored: retired, turned off,
  running (its process is present), gave up (its harness stopped restarting a
  crash loop — `Presence.gave_up/2` — and it waits on main), or starting — on
  duty and not present: requested, being restored, or restarting.
  """
  @spec lifecycle(Agent.t(), MapSet.t(Ecto.UUID.t())) ::
          :retired | :off | :running | :gave_up | :starting
  def lifecycle(%Agent{retired_at: %DateTime{}}, _present), do: :retired
  def lifecycle(%Agent{off_at: %DateTime{}}, _present), do: :off

  def lifecycle(%Agent{id: id} = agent, present) do
    cond do
      MapSet.member?(present, id) -> :running
      Presence.gave_up(agent.project_id, id) -> :gave_up
      true -> :starting
    end
  end

  @doc """
  `agents`, each with its derived `lifecycle` set, for display — and, for one
  its harness gave up on, what it said and when (`gave_up`).
  """
  @spec with_lifecycle([Agent.t()], MapSet.t(Ecto.UUID.t())) :: [Agent.t()]
  def with_lifecycle(agents, present),
    do: Enum.map(agents, &with_lifecycle_of(&1, present))

  defp with_lifecycle_of(agent, present) do
    case lifecycle(agent, present) do
      :gave_up ->
        %{agent | lifecycle: :gave_up, gave_up: Presence.gave_up(agent.project_id, agent.id)}

      lifecycle ->
        %{agent | lifecycle: lifecycle}
    end
  end

  @doc "Whether `agent` is on duty: neither turned off nor retired."
  @spec on_duty?(Agent.t()) :: boolean()
  def on_duty?(%Agent{off_at: nil, retired_at: nil}), do: true
  def on_duty?(%Agent{}), do: false

  @doc "Follow changes to which of the project's agents are present (`presence_diff`)."
  @spec subscribe_presence(Scope.t()) :: :ok | {:error, term()}
  def subscribe_presence(%Scope{active_project_id: project_id}),
    do: Phoenix.PubSub.subscribe(CodeMySpec.PubSub, presence_topic(project_id))

  @doc """
  Who is acting, as an off record names them: the calling agent when there is
  one, otherwise the scope's person.
  """
  @spec actor(Scope.t(), Ecto.UUID.t() | nil) :: String.t()
  def actor(%Scope{} = scope, calling_agent_id \\ nil) do
    with id when is_binary(id) <- calling_agent_id,
         {:ok, caller} <- AgentsRepository.fetch_agent(scope, id) do
      "the #{caller.role} agent #{caller.id}"
    else
      _ -> person(scope.user)
    end
  end

  defp person(%{email: email}) when is_binary(email), do: email
  defp person(_user), do: "a person"

  @doc "`:ok` for an agent that is on; `{:error, {:off | :retired, agent}}` otherwise."
  @spec refuse_unless_on(Agent.t()) :: :ok | {:error, {:off | :retired, Agent.t()}}
  def refuse_unless_on(%Agent{} = agent) do
    cond do
      Agent.retired?(agent) -> {:error, {:retired, agent}}
      Agent.off?(agent) -> {:error, {:off, agent}}
      true -> :ok
    end
  end

  # A seat (copy and role) whose agent is off is not empty: starting beside it
  # would staff a role somebody turned off (39af5611).
  defp seat_is_on(scope, %{working_copy_id: copy_id, role: role}) do
    case off_in_seat(scope, copy_id, role) do
      nil -> :ok
      agent -> {:error, {:off, agent}}
    end
  end

  defp seat_is_on(_scope, _attrs), do: :ok

  defp off_in_seat(scope, copy_id, role) do
    scope
    |> off_agents()
    |> Enum.find(&(&1.working_copy_id == copy_id and to_string(&1.role) == to_string(role)))
  end

  @doc """
  Turn an agent on: clear its off record and start it again.

  The only way back from off (39af5611). Start, restart and message never do
  it implicitly; they refuse. A retired agent cannot be turned on.
  """
  @spec turn_on_agent(Scope.t(), Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, term()}
  def turn_on_agent(%Scope{} = scope, id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <- refuse_retired(agent),
         {:ok, on} <-
           AgentsRepository.update_agent(scope, agent, %{
             off_at: nil,
             off_by: nil,
             off_reason: nil
           }) do
      start_unless_running(scope, on)
    end
  end

  defp start_unless_running(scope, %Agent{} = agent) do
    if present?(scope, agent), do: {:ok, agent}, else: restart_agent(scope, agent.id)
  end

  defp refuse_retired(%Agent{} = agent),
    do: if(Agent.retired?(agent), do: {:error, {:retired, agent}}, else: :ok)

  @doc """
  Retire an agent: record who, when and why, end its process, and free its seat.

  Not off (39af5611). Off keeps the seat and can be turned back on; retired is
  gone for good. Nothing is ever delivered to it again, it is never turned on,
  and a new agent may be started in its seat. The row and its transcript stay.

  A machine that cannot be reached does not stop the retire: it is recorded and
  the seat freed, the gate keeps the stranded process inert, and the answer is
  `{:ok, agent, {:unreachable, machine}}` so the caller can say so.
  """
  @spec retire_agent(Scope.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Agent.t()} | {:ok, Agent.t(), {:unreachable, String.t()}} | {:error, term()}
  def retire_agent(%Scope{} = scope, id, opts \\ []) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         {:ok, recorded} <- record_retired(scope, agent, opts),
         {:ok, retired} <- release_tasks(recorded) do
      :ok = hand_off_questions(scope, retired)

      case end_process(scope, retired) do
        :ok ->
          {:ok, stopped} = record_stopped(scope, retired, :stopped)
          broadcast(scope, {:agent_stopped, stopped})
          {:ok, stopped}

        {:error, _reason} ->
          broadcast(scope, {:agent_stopped, retired})
          {:ok, retired, {:unreachable, machine_of(retired)}}
      end
    end
  end

  # A retired agent's open tasks kept their requirement claimed, so the seat's
  # next agent was refused with `:task_owned_by_another_agent` (59c93382).
  # Closed as cancelled on the retired row, which keeps their history.
  defp release_tasks(%Agent{id: id}) do
    import Ecto.Query, only: [from: 2]

    Repo.transaction(fn ->
      agent = Repo.one!(from(a in Agent, where: a.id == ^id, lock: "FOR UPDATE"))
      tasks = Enum.map(agent.tasks || [], &release_task(&1, DateTime.utc_now()))

      agent
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:tasks, tasks)
      |> Repo.update!()
    end)
  end

  defp release_task(%{status: status} = task, now) when status in [:active, :blocked],
    do: %{task | status: :cancelled, completed_at: now}

  defp release_task(task, _now), do: task

  # A retired agent's open questions would orphan: the answer is delivered to
  # an agent that will never read it. They go to its successor in the role —
  # the main copy's, then any other live one — or to main, unchanged otherwise.
  # Schemaless because `Notifications`, which owns the row, depends on us.
  defp hand_off_questions(scope, %Agent{id: id} = retired) do
    case successor(scope, retired) do
      nil ->
        :ok

      %Agent{id: to} ->
        import Ecto.Query, only: [from: 2]

        from(q in "question_requests",
          where: q.agent_id == type(^id, :binary_id) and q.status == "pending"
        )
        |> Repo.update_all(set: [agent_id: Ecto.UUID.dump!(to)])

        :ok
    end
  end

  defp successor(scope, %Agent{id: id, role: role}) do
    live =
      scope
      |> AgentsRepository.list_agents()
      |> Enum.filter(&(&1.id != id and on_duty?(&1)))

    main_copy = WorkingCopies.main(scope)
    same_role = Enum.filter(live, &(&1.role == role))

    Enum.find(same_role, &(main_copy && &1.working_copy_id == main_copy.id)) ||
      List.first(same_role) ||
      main_agent(scope)
  end

  defp machine_of(%Agent{} = agent),
    do:
      WorkingCopies.machine_name(agent.working_copy_id) || "the machine at #{agent.working_copy}"

  # Retiring twice keeps the first record.
  defp record_retired(_scope, %Agent{retired_at: %DateTime{}} = agent, _opts), do: {:ok, agent}

  defp record_retired(scope, agent, opts) do
    AgentsRepository.update_agent(scope, agent, %{
      retired_at: DateTime.utc_now(),
      retired_by: trimmed(Keyword.get(opts, :by)) || "someone",
      retired_reason: trimmed(Keyword.get(opts, :reason))
    })
  end

  # A machine that answered, and answered with nothing.
  #
  # Distinct from a machine that has not answered yet, which is `nil` and is
  # legitimate: `create_working_copy` staffs a copy before it has joined the
  # harness (`34e03128`), and refusing there would break provisioning for a
  # copy that is merely early. An empty *list* is a report, and what it reports
  # is a machine serving nothing.
  #
  # Worth refusing rather than folding in, because `machine_tools/3` adds
  # whatever the copy offers to the role's granted set — so nothing offered
  # produces a shorter list rather than an error, and the agent starts. It then
  # comes up, reports a tool list, and fails every call it makes. That is this
  # story's note measured at four hours, and nothing anywhere treated "no tools
  # offered" as a fault.
  defp machine_serves_tools(attrs) do
    case Map.get(attrs, :working_copy_id) do
      nil -> :ok
      id -> refuse_if_serving_nothing(id)
    end
  end

  defp refuse_if_serving_nothing(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{machine_tools: []}} -> {:error, {:machine_serves_no_tools, id}}
      _ -> :ok
    end
  end

  @doc """
  The agents among `agents` a restart caught mid-turn, each with the id of the
  message that turn was answering (nil when none was recorded).

  Read before `account_for_interrupted_turns/2`, which clears the turn and
  writes the notice this would otherwise find.
  """
  @spec interrupted_turns([Agent.t()]) :: %{Ecto.UUID.t() => Ecto.UUID.t() | nil}
  def interrupted_turns(agents) when is_list(agents) do
    for %Agent{turn_started_at: %DateTime{} = at} = agent <- agents, into: %{} do
      {agent.id, starter_id(Conversations.turn_starter(agent.id, at))}
    end
  end

  defp starter_id(%{id: id}), do: id
  defp starter_id(nil), do: nil

  @doc """
  Tell every agent a restart touched what happened to it.

  Called when a harness asks what it should be running, which is the only
  moment this side sees a restart at all — the application going down is not an
  event the server observes.

  Every agent is told now, but the two halves of what it is told differ —
  rule `841a5f79`. An agent that *was* mid-turn cannot infer any of this on its
  own. Its thread ends part-way through a tool call and then jumps, and the
  two readings available to it — "the tool never answered, so wait" and "I
  already did this" — are both wrong and neither is recoverable from the
  transcript. Rule `0a06befe` decided the turn is discarded rather than
  resumed; this is where the agent finds that out.

  An idle agent lost nothing, so `interrupted_notice/0`'s wording would be
  actively wrong for it — there is no in-flight work to carry on from or
  double-check. It gets a shorter notice instead, plus its own menu: startup
  hands an agent its system prompt and its stop-hook menu together, and a
  restart is a message to an agent that already exists, so it gets the same
  menu rather than silence until its next natural turn.

  Written before the launch request is hydrated, so the notice is part of the
  history the agent comes back holding rather than something it would have to
  re-read the page to see. `turn_started_at` is cleared in the same pass for
  the interrupted case, for the reason `restart_agent/2` already clears it:
  left set, `list_agent_work` and every check-in go on reporting a turn that
  opened before a process that no longer exists (`4078e7bf`). Any open
  reservation is dropped for every agent, for the same reason.
  """
  @spec account_for_interrupted_turns(Scope.t(), [Agent.t()]) :: :ok
  def account_for_interrupted_turns(%Scope{} = scope, agents) when is_list(agents) do
    Enum.each(agents, &account_for_interrupted_turn(scope, &1))
  end

  defp account_for_interrupted_turn(scope, %Agent{turn_started_at: nil} = agent) do
    with {:ok, conversation} <- open_conversation(scope, agent) do
      conversation
      |> Conversations.add_message(:operator, idle_restart_notice(scope, agent), "operator")
      |> Offers.record(agent, :resume, {"restart", nil})
    end

    drop_dead_reservation(scope, agent)
  end

  defp account_for_interrupted_turn(scope, %Agent{} = agent) do
    with {:ok, conversation} <- open_conversation(scope, agent) do
      conversation
      |> Conversations.add_message(:operator, interrupted_notice(), "operator")
      |> Offers.record(agent, :resume, {"restart", nil})
    end

    AgentsRepository.update_agent(scope, agent, %{
      turn_started_at: nil,
      work_request_id: nil,
      work_requested_at: nil
    })

    :ok
  end

  # A reservation is a wake handed to the harness that just died, so it can
  # never become a turn. Left open it fences the agent out of the join's one
  # sweep for up to five minutes, and nothing sweeps again (0d3b800d).
  defp drop_dead_reservation(_scope, %Agent{work_request_id: nil}), do: :ok

  defp drop_dead_reservation(scope, agent) do
    AgentsRepository.update_agent(scope, agent, %{work_request_id: nil, work_requested_at: nil})
    :ok
  end

  defp interrupted_notice do
    """
    The harness restarted while you were part-way through a turn.

    That turn was discarded rather than resumed, so whatever it had in flight
    did not finish and was not recorded. The last step written to this thread
    is the last thing that is known to have happened.

    This is a statement about the turn, not about the working copy: uncommitted
    edits on disk are not part of a turn and are not restored with one. If you
    had uncommitted changes, check `git status` before assuming they survived.

    Carry on from the turns already here. Do not assume work you cannot see
    recorded above was completed — if you are unsure whether something landed,
    check rather than redo it.
    """
  end

  # Nothing of the agent's own turn was interrupted, so the notice says only
  # that machinery it does not own cycled — but that is a narrower claim than
  # "nothing was lost" once said outright: a restart has been observed to
  # discard uncommitted edits left on disk from an earlier, already-finished
  # turn, and this notice fires whether or not any exist (`d2908c58`).
  # `Menu.render/4` answers "" when nothing is live for this agent, which is
  # the right shape here too — a restart with no work behind it should read as
  # a couple of short lines, not that plus an empty section.
  defp idle_restart_notice(scope, agent) do
    "The harness restarted. No turn of yours was interrupted — but if you had " <>
      "uncommitted changes on disk, check `git status`: a restart is not known " <>
      "to preserve them.\n" <>
      Menu.render(scope, agent.continuous == true, agent.role, agent)
  end

  # Starting a `main` agent is what the cadence exists to look after, so it is
  # also what should start one. Without this the only triggers were the boot
  # sweep and a continuous-mode flip, so a main agent started on a running node
  # — the ordinary case — had nothing scheduled to wake it until the next
  # restart (`11aea8f5`).
  #
  # Starting one is also the clearest statement that this project is back at
  # work, which is what `resume/1` is for. It had no caller anywhere: a project
  # whose main agent tapped out stayed stood down permanently, and a later
  # cadence would tick and no-op forever because `running?/1` still found the
  # project in the stood-down list — indistinguishable from a project nobody
  # works on (`5f9fad45`). Ordered before `ensure_cadence/1` so the timer that
  # comes up is one that will actually deliver.
  defp watch_over(scope, %Agent{role: role}) do
    if RoleProfile.wakes_on?(role, :cadence) do
      MainAgent.resume(scope)
      MainAgent.ensure_cadence(scope)
    end

    :ok
  end

  @doc """
  Restart one agent's process in place — same id, same conversation.

  For a row a shared harness restart (or a crashed machine) pulled the rug
  out from under: `status` still says `:running`, nothing is actually there,
  and `wake/2`'s dispatch has nowhere to land. John: "we're persisting the
  state of a process — just display the state of the process, and when you
  click play it should start the process again."

  The tool list is recomputed rather than carried over, and that is the half
  that makes a restart worth anything after a deploy. `tools` is written once at
  creation, so an agent started before a tool existed could never reach it — no
  matter how many times it was restarted — and the only symptom available from
  inside the agent is "it is not in my list", which reads as a client caching
  problem and is not one. A coding agent sat through exactly that with `promote`.

  Deliberately not `start_agent/2` again. That inserts a new row, and
  `find_or_create_agent_conversation/3` keys on `agent_id` — a fresh id is a
  fresh, empty thread, which is exactly the outcome a restart exists to
  avoid. This re-runs only the launch half: fetch a credential, hydrate the
  existing history (same lookup, same id, same transcript), ask the
  machine to run it. The row that comes back is the same row, running again.

  ## It stops the process first, and that is the whole of it working

  Without the stop this was a restart only of an agent that was already dead.
  `Engine.start/1` answers `{:error, {:already_started, pid}}` with `{:ok,
  %{pid: pid}}` — correct idempotence for a re-delivered *start*, and wrong for
  a restart: the live process was handed straight back, so whatever turn it was
  in carried on and the only thing that reached it was the `Restarted: <reason>`
  message sent afterwards.

  Which made the remedy a no-op against the one agent worth applying it to. An
  agent hung mid-turn has a live process, and story 1059's whole premise is the
  main agent acting on an agent that cannot report its own trouble. Every
  restart reported success while changing nothing (`e9f9a5ab`).

  So a restart now discards the turn in flight, which is a real cost and is the
  point: criterion 3321 asks for exactly that, and an agent that has to be
  restarted is one whose current turn is the problem.

  The stop goes through `halt_for_restart/1`, not `end_process/2` — see the
  comment on it. `end_process/2` skips the ask for an agent whose row reads
  `:starting`, which is right for a stop and wrong here, and trusting that guard
  is how a survivable collision became a permanently stuck agent.

  Either way a machine that could not be asked refuses the restart rather than
  reporting one it did not perform, and "already not running" stays a satisfied
  stop.
  """
  @spec restart_agent(Scope.t(), Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, term()}
  def restart_agent(%Scope{} = scope, agent_id) when is_binary(agent_id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         :ok <- refuse_unless_on(agent),
         {:ok, credential} <- Credential.fetch(scope, agent.provider),
         :ok <- halt_for_restart(agent),
         :ok <- Offers.supersede_queued(agent.id),
         {:ok, starting} <-
           AgentsRepository.update_agent(scope, agent, %{
             status: :starting,
             os_pid: nil,
             os_boot_id: nil,
             # The turn the restart is discarding. Left set, `list_agent_work`
             # and every check-in go on reporting "a turn opened at <then> and
             # has not finished" for an agent that has been restarted and whose
             # process is gone — measured at two minutes past the restart and
             # still climbing, against a row nothing would ever clear
             # (`4078e7bf`).
             turn_started_at: nil,
             # Stale otherwise: an agent about to run again does not need to
             # keep saying why it last stopped, and a `:reaped` row that starts
             # cleanly and is stopped deliberately later must not be read as
             # still reaped from before.
             stopped_reason: nil,
             tools: tools_of(scope, agent)
           }) do
      with {:ok, agent} <-
             launch(scope, LaunchRequest.hydrate(scope, %{starting | credential: credential})) do
        broadcast(scope, {:agent_started, agent})

        # Whether it takes a turn is `came_up/2`'s, once its process is up and
        # present: asked now, it is not present yet and would be held.

        {:ok, agent}
      end
    end
  end

  # Ask the machine to end it, whatever the row says.
  #
  # Deliberately not `end_process/2`, which skips the ask for an agent whose row
  # reads `:starting`, on the reasoning that such an agent "never came up, so
  # there is no process to end". True for a *stop* and false here, and
  # `working_copy_connected?/1`'s own moduledoc says why: "status is written on
  # a clean stop or a clean start; nothing writes it when a shared harness
  # restart or a crashed machine takes the process with it."
  #
  # Measured rather than supposed. An agent that had started, worked a turn end
  # to end and replied still read `:starting`, because the machine's
  # confirmation never landed. The stop was skipped on that guard, `launch/2`
  # then collided — `{:shutdown, {:failed_to_start_child, Anubis.Client,
  # {:already_started, …}}}` — the new process lost, and the row stuck at
  # `:starting` with `os_pid: nil` indefinitely while `restart_agent/2` answered
  # `{:ok, agent}`. Nine minutes later nothing had retried (`4078e7bf`).
  #
  # Worth being plain that this is a defect `e9f9a5ab` introduced: before it,
  # the collision was survivable because the machine handed the live process
  # back. Adding the stop without noticing that its guard trusts `status` as
  # evidence of a process turned a no-op into a way to lose the agent.
  #
  # So a restart asks unconditionally. The transport answers `{:error,
  # :not_running}` for an agent the machine is not running, and `stopped?/1`
  # already reads that as a satisfied stop — which is what makes asking safe for
  # the case the guard was there to protect.
  defp halt_for_restart(%Agent{} = agent) do
    agent.working_copy_id
    |> Transport.impl().stop_agent(agent, @stop_timeout_ms)
    |> stopped?(agent)
  end

  @doc """
  Whether anything is actually connected for this agent's working copy right
  now — read from the live channel registry, never from `agent.status`.

  `status` is written on a clean stop or a clean start; nothing writes it
  when a shared harness restart or a crashed machine takes the process with
  it, so a row can say `:running` indefinitely with nothing behind it. This
  is the same check `Rows.build/4`'s `served` field already trusts for "is
  this working copy connected" — reused here rather than a second, agent-
  shaped copy of the same registry lookup.

  Not a per-role liveness check — a connected working copy could still have
  lost one specific agent's own process while others on it survive. That
  needs the harness to report which agents it is actually running, which it
  does not yet do. This is the strictly weaker, always-available half: if
  *nothing* is connected, no agent on that copy can possibly be alive.
  """
  @spec working_copy_connected?(Agent.t()) :: boolean()
  def working_copy_connected?(%Agent{working_copy_id: id}) do
    match?({:ok, _pid, _instance}, HarnessRegistry.executor_holder(id))
  end

  # The main working copy holds the roles whose `RoleProfile.home_copy` is
  # `:main` — main and product, one each (John, step 4c) — and nothing else.
  # Coding and QA never start there: metric_flow carried a coding agent there
  # from 09-24 until John retired it.
  #
  # One of each, because a second main is a second conversation on the copy the
  # user is told has one thing to talk to, and a second product is a second
  # chain of thought through the same design.
  #
  # Every other checkout holds one agent per role too. Two coding agents on one copy
  # claim and edit the same work: on metric_flow 2026-09-27 the main agent could
  # not reach `restart_agent`, started a fresh coder beside the running one, and
  # the copy had two once the original came back. `restart_agent/2` does not
  # pass through here, so an agent is never refused for counting as itself.
  defp copy_is_free(scope, attrs) do
    main = WorkingCopies.main(scope)

    if main && names?(attrs, main),
      do:
        with(
          :ok <- refuse_unless_at_home(attrs, main),
          do: refuse_if_occupied(scope, attrs, main)
        ),
      else: refuse_if_role_taken(scope, attrs)
  end

  defp refuse_unless_at_home(%{role: role}, copy) do
    if RoleProfile.lives_on_main_copy?(role),
      do: :ok,
      else: {:error, {:not_at_home, role, copy.root}}
  end

  # Where the agent will actually run, decided before anything is checked
  # against it.
  #
  # `base_attrs/2` used to fill this in *after* the guard, so a caller who named
  # no checkout was checked against a copy they had not mentioned and then
  # started on the one they had not named. That is not a corner: the MCP tool
  # drops nil keys, so every ordinary `start_agent` arrives naming nothing, and
  # a second agent got into the main checkout by leaving a field out. QA found
  # it by making the same call twice, once with the copy named and once
  # without — refused, then allowed.
  defp put_destination(%Scope{} = scope, attrs) do
    case resolve_destination(scope, attrs) do
      {:ok, root, working_copy_id} ->
        {:ok,
         attrs
         |> Map.put(:working_copy, root)
         |> Map.put(:working_copy_id, working_copy_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An id names a specific checkout unambiguously, so root has to be derived
  # from it, not defaulted independently from the caller's own scope. The
  # previous version always computed `root` as `attrs[:working_copy] ||
  # scope.cwd` before ever looking at an id — so a caller who passed only an
  # id (the identifier `list_working_copies` puts first) got that id kept
  # correctly, but `root` silently became the CALLER'S OWN checkout. When the
  # caller's own checkout is the main copy, `names?/2`'s root branch then
  # matched main by accident, and `start_agent` refused a start on some other
  # copy entirely while blaming the main checkout for it.
  #
  # An id this scope does not own is refused rather than defaulted, unlike an
  # unresolved root. The two look similar but are not: a root that resolves to
  # nothing is a checkout that has never joined and legitimately has no row
  # yet, which is what that fallback exists for. An id that resolves to
  # nothing — a typo, or another project's copy — has no such reading, and
  # defaulting it ran an agent in the caller's own tree while recording it
  # against a checkout from a different project entirely. Issue c0facd8e.
  defp resolve_destination(scope, %{working_copy_id: id})
       when is_binary(id) and id != "" do
    case owned_copy(scope, id) do
      %{root: root} -> {:ok, root, id}
      nil -> {:error, {:unknown_working_copy, id}}
    end
  end

  defp resolve_destination(scope, attrs) do
    root = Map.get(attrs, :working_copy) || scope.cwd
    {:ok, root, id_for(scope, root)}
  end

  defp owned_copy(%Scope{active_project_id: project_id}, id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{project_id: ^project_id} = copy} -> copy
      _ -> nil
    end
  end

  # The id has to come from the root when a root was named, not from the caller.
  #
  # Defaulting both fields from scope was one field too many. Every ordinary
  # `start_agent` names a root and no id, so the id became the *caller's*
  # checkout — and `names?/2` tests the id first, so the main-copy guard fired on
  # starts that named somewhere else entirely. With an agent on the main copy,
  # nothing could be started anywhere, and the refusal named a checkout the
  # caller had not mentioned.
  #
  # It also placed the agent wrongly when the guard let it through: the row's
  # `working_copy_id` is what the working copies page groups by, so an agent
  # asked for on one copy was recorded on another.
  #
  # Falls back to the caller's own copy only when the root is the caller's own
  # or names nothing we recognise — an unknown root is not a reason to refuse,
  # because a checkout that has never joined has no row to find.
  defp id_for(%Scope{} = scope, root) do
    case WorkingCopies.by_root(scope, root) do
      %{id: id} ->
        id

      nil ->
        warn_substitution(scope, root)
        scope.active_working_copy_id
    end
  end

  # The fallback is deliberate — see above — but it used to be silent, and that
  # is what made it dangerous rather than merely lossy.
  #
  # QA of story 988 named `.../qa_sandbox`, was answered "Working copy:
  # .../qa_sandbox", and got a row pointing at the main checkout. The agent
  # really did run in qa_sandbox; only its record disagreed. `by_root/2` matches
  # project *and device* and root, and that root's row for this project sits on
  # a stale device, so the lookup missed and the caller's own copy stood in.
  # Issue `af85efc7`.
  #
  # It matters beyond a wrong column: the stop decision and the analyzer alert
  # are both computed from this id, so an agent editing one tree is told about
  # another. Nothing is moved here — rewriting the root would relocate the agent
  # itself, and relocating it *into the framework's own checkout* is worse than
  # the bug — so the substitution stands and is announced instead.
  defp warn_substitution(%Scope{} = scope, root) do
    if is_binary(root) and root != scope.cwd do
      Logger.warning(
        "[Agents] no working copy for #{root} on this device and project — recording the agent " <>
          "against #{inspect(scope.active_working_copy_id)} instead. It will run where you said " <>
          "and be judged where this points; if that is not what you meant, the copy at that root " <>
          "has not joined this project from this machine."
      )
    end

    :ok
  end

  # By id or by root, because callers name a checkout both ways and a guard
  # that only understands one of them does not fire on the other. `StartAgent`
  # passes a root and no id at all — the id is filled in from scope afterwards
  # — so reading only the id would leave the one surface that starts agents
  # unguarded.
  defp names?(attrs, copy) do
    id = MapAccess.get(attrs, :working_copy_id)
    root = MapAccess.get(attrs, :working_copy)

    id == copy.id or (is_binary(root) and root != "" and Path.expand(root) == copy.root)
  end

  # One agent per role on the main copy, by id alone: root does not matter
  # there, the copy is the project's. A retired agent's seat is free even while
  # its stranded process runs (39af5611).
  defp refuse_if_occupied(scope, %{role: role}, copy) do
    if scope
       |> seat_holders()
       |> Enum.any?(&(&1.working_copy_id == copy.id and to_string(&1.role) == to_string(role))),
       do: {:error, {:main_copy_occupied, RoleProfile.get(role).role, copy.root}},
       else: :ok
  end

  defp refuse_if_role_taken(scope, %{working_copy_id: copy_id, working_copy: root, role: role})
       when is_binary(copy_id) do
    scope
    |> seat_holders()
    |> Enum.find(&same_seat?(&1, copy_id, root, role))
    |> case do
      nil -> :ok
      agent -> {:error, {:role_taken, agent.role, agent.id, agent.working_copy}}
    end
  end

  defp refuse_if_role_taken(_scope, _attrs), do: :ok

  # On duty holds a seat, whether or not its process is up this moment — one
  # being restored has not given it up.
  defp seat_holders(scope), do: AgentsRepository.list_on_duty(scope)

  # Root as well as id: a root with no row of its own is recorded under the
  # caller's copy id (`id_for/2`), and is still a different tree.
  defp same_seat?(agent, copy_id, root, role) do
    agent.working_copy_id == copy_id and agent.working_copy == root and
      to_string(agent.role) == to_string(role)
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
    case Transport.start_agent(agent.working_copy_id, agent, @start_timeout_ms) do
      {:ok, report} -> {:ok, record_or_keep(scope, agent, report)}
      {:error, reason} -> keep_starting(agent, reason)
    end
  end

  defp record_or_keep(scope, agent, report) do
    case record_started(scope, agent, report) do
      {:ok, running} -> running
      {:error, _reason} -> agent
    end
  end

  # Answers `{:ok, agent}` at `:starting`, and that is deliberate rather than
  # lax — see criterion 3211, which asks for the opposite and cannot have it.
  #
  # A row here is *intent*, not observation. `create_working_copy` staffs a
  # copy with its three roles before that copy has joined the harness, and the
  # machine reconciles to the rows afterwards through `agents_to_restore`. So
  # "the machine did not start it" is the ordinary, recoverable case on the
  # path that matters most, and refusing it breaks staffing outright:
  # `ensure_copy_agents` and `offboard_ends_the_agents` both fail at their
  # premise, measured, with `{:machine_did_not_start_it, :working_copy_missing}`.
  #
  # What 3211 is actually right about is the *reply*, not the return: a caller
  # told "Agent started." for a row nothing has confirmed cannot tell that from
  # a working agent. That is a wording problem in `AgentsMapper.started/1`, and
  # fixing it there costs nothing here. Left alone pending a decision, because
  # changing the return is what `34e03128` ("a :starting row is never retried")
  # would have to be solved alongside.
  defp keep_starting(agent, reason) do
    Logger.info(
      "[Agents] agent #{agent.id} was not started on its machine (#{inspect(reason)}); " <>
        "it stays :starting, which is what the page shows as asked-for and unconfirmed"
    )

    {:ok, agent}
  end

  # An agent that cannot be watched is indistinguishable from one that never
  # started, so the conversation is opened as part of starting rather than when
  # the agent first says something. A Pi lane relays its turns up through
  # `AgentHarness.relay_up/2` into this same conversation, which is why a Pi
  # agent and a Claude Code agent land on one surface instead of two.
  #
  # Keyed on the agent, which is the thing the thread is about.
  #
  # It was keyed on the working copy — `pi:<cwd>`, matching how a Pi lane keys
  # itself on the socket — so every agent started on one checkout found the same
  # row. A copy runs several lanes (story 1023's rule exists because of it), and
  # their turns interleaved into a single transcript with nothing saying who
  # spoke. Observed live: an agent started on a worktree silently adopted a
  # conversation from ten days earlier that already had two turns on it.
  #
  # The two objections that put the key on the path in the first place are both
  # answered elsewhere now. A row reading `agent:<uuid>` was unreadable across
  # three copies — the rows carry generated names and the agent's own identity
  # instead of a raw key. And the split transcript, where the lane reporting over
  # the channel wrote to `pi:<cwd>` while the tool that started it wrote
  # somewhere else, was a two-callers-one-function problem:
  # `find_or_create_session_conversation/3` now answers for a Claude Code lane
  # that has an external id and no agent row, and this answers for an agent.
  @doc """
  The conversation an agent's transcript goes to, for someone who has its id
  and a scope it must belong to.
  """
  @spec conversation_id(Scope.t(), String.t()) :: {:ok, Ecto.UUID.t()} | :error
  def conversation_id(%Scope{} = scope, agent_id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         {:ok, conversation} <- open_conversation(scope, agent) do
      {:ok, conversation.id}
    else
      _ -> :error
    end
  end

  defp open_conversation(%Scope{} = scope, %Agent{} = agent) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
    )
  end

  @doc """
  Give a running agent something to do.

  The capability the engine change was chosen for, and the one that was missing
  after it: an agent could be started, listed and stopped, and never asked to do
  anything, so it idled until somebody stopped it.

  Answers `:started` or `:queued` once the engine admits the message. The
  agent's response arrives in its conversation. A queued instruction is
  recorded as an Offer, but is not judged until delivery at a turn boundary.
  An unreachable agent returns an error.
  """
  @spec message_agent(Scope.t(), Ecto.UUID.t(), String.t(), timeout()) ::
          {:ok, :started | :queued} | {:error, term()}
  def message_agent(%Scope{} = scope, id, text, timeout \\ @message_timeout_ms)
      when is_binary(text) do
    with {:ok, disposition, _message} <-
           dispatch_message(scope, id, text, :operator_message, timeout) do
      {:ok, disposition}
    end
  end

  @doc """
  Every agent on this machine, for the development route that lists them.

  Scopeless, and it is the only listing that is. `list_agents/1` answers what
  one project's operator may see; this answers what is running here, which is
  the question a person debugging a stuck agent has — they do not yet know which
  project it belongs to, and needing to know first is what made the agent
  unreachable.

  Reached only from `/dev/agents`, which is compiled out of a release.
  """
  @spec list_every_agent(keyword()) :: [Agent.t()]
  defdelegate list_every_agent(opts \\ []), to: AgentsRepository

  @doc """
  Message an agent wherever it is, building its scope from the agent itself.

  `message_agent/4` resolves inside the caller's project and refuses the rest —
  a tenant boundary, and it stays. This is the development door beside it: the
  caller is deliberately somewhere else, so there is nothing to scope *from* and
  the agent names its own project.

  Separate from `message_agent/4` rather than an option on it, so that widening
  this cannot widen that. Reached only from `/dev/agents/:id/message`, which is
  compiled out of a release.
  """
  @spec message_any_agent(Ecto.UUID.t(), String.t(), timeout() | :no_wait) ::
          {:ok, String.t() | :still_working | :queued | :started} | {:error, term()}
  def message_any_agent(agent_id, text, timeout) when is_binary(agent_id) and is_binary(text) do
    case Repo.get(Agent, agent_id) do
      nil -> {:error, :no_such_agent}
      agent -> send_to_any(agent, text, timeout)
    end
  end

  @doc """
  Turn one agent off by id, resolving its project from its own row.

  The counterpart to `message_any_agent/3`, and it exists for the same reason:
  somebody looking at the fleet is not inside any one project's scope, and the
  two useful things to do to an agent you can see are talk to it and stop it.
  Only one of those was reachable, so a working copy that had accumulated three
  coding agents could be observed and not thinned.

  Off, like every deliberate stop (39af5611). Behind the dev-only router scope
  that is compiled out of production.

  The project comes off the agent's row rather than from the caller, so this
  cannot stop an agent while a wrong project id claims the write — the
  repository's `:cross_project` guard is doing its job, not being worked around.
  """

  @spec turn_off_any_agent(Ecto.UUID.t()) ::
          {:ok, Agent.t()} | {:error, :no_such_agent | term()}
  def turn_off_any_agent(agent_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :no_such_agent}

      agent ->
        turn_off_agent(%Scope{active_project_id: agent.project_id}, agent.id, by: "the dev tools")
    end
  end

  @doc "Turn any agent on by id, for the dev tools. The counterpart to `turn_off_any_agent/1`."
  @spec turn_on_any_agent(Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, term()}
  def turn_on_any_agent(agent_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :no_such_agent}

      agent ->
        turn_on_agent(
          %Scope{active_project_id: agent.project_id, active_account_id: agent.account_id},
          agent.id
        )
    end
  end

  @doc """
  Restart any agent by id, for the dev tools.

  The counterpart to `turn_off_any_agent/1`, and the gap that made these tools
  one-way: `/dev/agents` could observe an agent and stop it, and nothing there
  could start one again. A stopped agent had exactly one route back — the play
  control on its own conversation page — and when that control was itself broken
  there was no way in at all.

  Not `start_any_agent`. `start_agent/2` inserts a new row and
  `find_or_create_agent_conversation/3` keys on `agent_id`, so starting is a
  fresh empty thread; this is `restart_agent/2`, which re-runs the launch half
  against the same row and the same transcript.

  Account and project both come off the agent's row. The account is what the
  credential lookup needs, and taking it from the caller would be the same hole
  the `:cross_project` guard exists to close.
  """
  @spec restart_any_agent(Ecto.UUID.t()) ::
          {:ok, Agent.t()} | {:error, :no_such_agent | term()}
  def restart_any_agent(agent_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :no_such_agent}

      agent ->
        restart_agent(
          %Scope{active_project_id: agent.project_id, active_account_id: agent.account_id},
          agent.id
        )
    end
  end

  # Operator delivery waits only for admission to the engine queue.
  defp send_to_any(%Agent{} = agent, text, :no_wait),
    do: send_to_any(agent, text, @message_timeout_ms)

  defp send_to_any(%Agent{} = agent, text, timeout) do
    message_agent(agent_scope(agent), agent.id, text, timeout)
  end

  @doc """
  Take an agent out of the loop, because a human approved its tap-out.

  Scopeless for the same reason `send_to_agent/3` is: the id comes off
  `permission_requests.agent_id`, which this application wrote from the asking
  connection, so there is no tenant decision left to make.

  The message alone was not enough and said so falsely. An approved tap-out
  told the agent "the loop is done" and left `continuous` set, so the next stop
  woke it again — the agent had been given permission to leave and was then
  asked to carry on, which is worse than never having offered.
  """
  @spec leave_loop(Ecto.UUID.t()) :: :ok
  def leave_loop(agent_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil ->
        :ok

      agent ->
        agent
        |> Agent.changeset(%{continuous: false})
        |> Repo.update()

        :ok
    end
  end

  @doc """
  Hand an agent the answer to something it asked, and let it carry on.

  The other half of `ask_user` for an agent we run. `check_answer` polls, which
  is right for a Claude Code session that keeps running regardless, and wrong
  here: an agent waiting on a person should be stopped, and a stopped agent has
  nothing to poll with.

  No scope, unlike `message_agent/4`, and the reason is what the id is. It comes
  off `question_requests.agent_id`, which this application wrote from the asking
  connection — not from a parameter, and not from anything a caller chose. There
  is no tenant decision left to make by the time we are here, and threading a
  scope in would mean *reconstructing* one from the row to re-derive an answer
  the row already holds.

  Dispatched, not called. `message_agent/4` is a `GenServer.call` to the process
  holding the working copy, and that process runs the *whole turn* inside the
  call — so delivering this way waited out the agent's entire reply, inside the
  person's form submission, and timed out:
  `{GenServer, :call, [#PID<…>, {:stream_chat, "The user answered your
  question…"}]}`. The answer was recorded and the agent was not told, so John
  pasted it in by hand — which is the cost of this failing quietly: the loop
  still runs, with a person carrying the message.

  `Agents.StopDecision` had already learned this and says so: a dispatch goes
  off this process so a busy agent is queued rather than interrupted. Same act,
  same route.

  Recorded before it is dispatched, and for the same reason the stop decision is:
  delivery can fail — a halted agent has nobody to tell — and what the person
  answered is true whether or not anything was there to hear it. It is also the
  only trace of the answer in the transcript, now that an answered question
  stops rendering its card.

  Failure is returned, never raised. This runs inside the person's answer
  submission, and an agent whose machine has since gone away must not take the
  form with it — the answer is recorded either way, and an agent that missed it
  can still find it with `check_answer`.

  `event` is what `Wake` is asked about — `:own_reply` for the answer to
  something it asked of us, `:question_answered` for its question's answer. A
  held message is still recorded, as a delivery that failed always was: what
  was said is true whether or not anything was there to hear it.

  Options: `:timeout`, and `:offer` — `{kind, subject}` to record the message
  as an offer (`Offers`).
  """
  @spec send_to_agent(Ecto.UUID.t(), String.t(), Wake.event(), keyword()) ::
          {:ok, :started | :queued} | {:error, term()}
  def send_to_agent(agent_id, text, event, opts \\ [])
      when is_binary(agent_id) and is_binary(text) do
    timeout = Keyword.get(opts, :timeout, @message_timeout_ms)

    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :no_such_agent}

      agent ->
        ref = "answer-" <> Ecto.UUID.generate()

        with {:ok, conversation} <- open_conversation(agent_scope(agent), agent),
             {:ok, message} <- record_sent(conversation, text, ref, :queued) do
          offered = record_offer({:ok, message}, agent, opts[:offer])

          result =
            case Wake.allow?(agent_scope(agent), agent, event) do
              :ok ->
                Transport.dispatch_message(agent.working_copy_id, agent, ref, text, timeout)

              hold ->
                Wake.to_error(hold)
            end

          case record_dispatch_result(result, message, offered) do
            {:ok, disposition, _message} -> {:ok, disposition}
            error -> error
          end
        end
    end
  end

  defp agent_scope(%Agent{} = agent) do
    %Scope{
      active_account_id: agent.account_id,
      active_project_id: agent.project_id,
      active_working_copy_id: agent.working_copy_id
    }
  end

  defp record_offer(_recorded, _agent, nil), do: nil

  defp record_offer(recorded, agent, {kind, subject}),
    do: Offers.record(recorded, agent, kind, subject)

  @doc """
  The project's own agent — the one in its main working copy.

  A position, not a label. `agents.role` defaults to "main", so every agent
  ever started carries that word and a project running three of them has three
  claiming to be the one you talk to. What makes this one unique is where it
  is: the checkout the project designated, which no other agent may run in.

  `nil` when the project has no main working copy, or has one and nothing is
  running there yet. Both are ordinary states with different remedies, which is
  why `ensure_main_agent/1` reports them apart.

  ## What is running, not what has ever run

  `list_running/1` and not `list_agents/1`, and the difference was a bug with
  no way out of it. Reading every agent ever started meant a *stopped* one
  still counted as the agent on the copy: `ensure_main_agent/1` short-circuited
  and never started a replacement, and `refuse_if_occupied/2` refused every
  future start there. Stopping the main agent — which is the entire point of
  story 961 — permanently removed the project's ability to have one, and the
  page went on saying it was getting ready. Any stopped agent did it, not only
  a main one, because `on_copy?/2` does not read the role.
  """
  @spec main_agent(Scope.t()) :: Agent.t() | nil
  def main_agent(%Scope{} = scope) do
    case WorkingCopies.main(scope) do
      nil -> nil
      copy -> scope |> running_main_agents() |> Enum.find(&(&1.working_copy_id == copy.id))
    end
  end

  # Work an agent ignored to the end of its ladder is held back from it, and
  # main is told once (criteria 1741, 2056), so a person or main can reassign,
  # cancel or answer it. The count is the kind's own ladder length, not
  # requirement work's three (2057): a released task is held back after two, a
  # declined tap-out notice after one.
  #
  # Announced as `:offer_held_back`, not `:teammate_stalled`: `Wake` holds the
  # latter for a non-continuous main, so the notice was recorded undelivered and
  # main never heard it (criterion 2063). This one wakes main whatever its role.
  #
  # Read as "reached the terminal rung and not yet reported" rather than by a
  # time window, so a *refused* offer -- settled earlier in this same turn, by
  # `Agents.reject_offer/4` -- is escalated too, and each is stamped so a later
  # turn does not repeat it.
  defp tell_main_held_back(scope, agent) do
    agent.id
    |> Offers.unreported_held_back()
    |> Enum.sort_by(& &1.id)
    |> Enum.each(fn offer ->
      notify_main(
        scope,
        :offer_held_back,
        "Held back from the #{agent.role} agent #{agent.id}: " <>
          "#{held_back_subject(agent, offer)}, #{held_back_reason(offer)}. " <>
          "It is still offered to its teammates.",
        offer: {:stalled, {"agent", agent.id}}
      )

      :ok = Offers.mark_reported(offer)
    end)
  end

  # A released task is named as this agent's task, so main can cancel or
  # reassign it rather than only reading its id.
  defp held_back_subject(_agent, %CodeMySpec.Agents.Offer{kind: :unblocked, subject_key: id}),
    do: "task `#{id}` on this agent"

  defp held_back_subject(_agent, %CodeMySpec.Agents.Offer{subject_key: key}), do: "`#{key}`"

  # A refusal says why; an ignore says how many times, read from the ladder
  # this kind escalates on.
  defp held_back_reason(%CodeMySpec.Agents.Offer{status: :declined, reason: reason})
       when is_binary(reason),
       do: "refused: #{reason}"

  defp held_back_reason(%CodeMySpec.Agents.Offer{kind: kind, subject_type: type} = offer),
    do: "offered #{held_back_count(kind, type, offer)} times and not taken"

  defp held_back_count(kind, type, offer) do
    case Offers.ladder({kind, type}) do
      nil -> offer.attempt
      steps -> length(steps)
    end
  end

  @doc """
  An agent declining an offer, with its reason (criterion 1738): `offer_id`,
  or its newest open offer when nil. The offer settles as declined and the work
  is held back from this agent (criterion 2055); main hears about it once,
  naming the reason (criterion 2056).

  Told here as well as from `tell_main_held_back/2` at the turn end that follows
  it, and the two are not the same notice. This one is immediate: rejection is
  a thing the agent decided, and main should not have to wait for a turn to end
  to hear it -- the same turn may be a long one. The escalation is the one that
  stamps the offer reported, so the pair still reaches main exactly once
  (1738 asks for the refusal to be told; 2056 asks for it once).

  Announced as `:offer_held_back`, not the `:teammate_stalled` this used to
  send: `Wake` holds that event for a non-continuous main, so the refusal of a
  main that is not continuous was recorded undelivered and never read
  (criterion 2063). It is main's own administrative notice, told whatever the
  role and told now.
  """
  @spec reject_offer(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil, String.t()) ::
          {:ok, CodeMySpec.Agents.Offer.t()} | {:error, :not_found}
  def reject_offer(%Scope{} = scope, agent_id, offer_id, reason) do
    with {:ok, offer} <- Offers.reject(agent_id, offer_id, reason) do
      notify_main(
        scope,
        :offer_held_back,
        "Offer declined by agent #{agent_id}: #{offer.kind} `#{offer.subject_type}:" <>
          "#{offer.subject_key}`. Reason: #{reason}",
        offer: {:stalled, {"agent", agent_id}}
      )

      # Stamped here, so the turn-end escalation does not say the refusal again:
      # `tell_main_held_back/2` reads the terminal rung and reports what has not
      # been reported, and this is that report (criterion 2056 -- once).
      :ok = Offers.mark_reported(offer)

      {:ok, offer}
    end
  end

  @doc """
  Tell the project's main agent about `event`, if one is running and `Wake`
  allows it. Delivered from a task, because delivery waits on a turn the caller
  should not.

  Options: `:offer` — `{kind, subject}` to record the notice on main's
  conversation and as an offer (`Offers`), marked undelivered when held or
  when the send fails.
  """
  @spec notify_main(Scope.t(), Wake.event(), String.t(), keyword()) :: :ok
  def notify_main(%Scope{} = scope, event, text, opts \\ []) when is_binary(text) do
    case main_agent(scope) do
      %Agent{} = main -> notify(scope, main, event, text, opts[:offer])
      nil -> :ok
    end
  end

  defp notify(scope, main, event, text, offer) do
    ref = Ecto.UUID.generate()

    with {:ok, conversation} <- open_conversation(scope, main),
         {:ok, message} <- record_sent(conversation, text, ref, :queued) do
      offered = record_offer({:ok, message}, main, offer)

      case Wake.allow?(scope, main, event) do
        :ok ->
          {:ok, _pid} =
            Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
              main.working_copy_id
              |> Transport.dispatch_message(main, ref, text, @message_timeout_ms)
              |> record_dispatch_result(message, offered)
            end)

        hold ->
          record_dispatch_result(Wake.to_error(hold), message, offered)
      end
    end

    :ok
  end

  # Role as well as copy. This matched on the working copy alone, so "the main
  # agent" was whichever agent happened to be running on the main checkout —
  # and the main copy holds one agent only by convention, not by constraint.
  # Story 1059's criterion 3331 puts a continuous main and a continuous coding
  # agent on one checkout, and anything addressed to "the main agent" there
  # reached whichever the query returned first.
  @doc """
  The project's running `main` agents, newest first, wherever they run. The one
  source every "find the main agent" reads.
  """
  @spec running_main_agents(Scope.t()) :: [Agent.t()]
  defdelegate running_main_agents(scope), to: AgentsRepository, as: :list_running_main

  @doc """
  The project's own agent, started if it does not exist yet.

  What "there without anybody starting it" means from the server's side:
  opening a project asks for its agent, and asking is enough. A non-technical
  user has no way to supply a provider, a checkout and a role, and should not
  have to know those are the things standing between them and a conversation.

  The two failures are kept apart because their remedies are nothing alike.
  `:no_main_working_copy` means run `mix cms.new`, or designate one of the
  checkouts you have. `:not_connected` means connect a provider — the agent has
  somewhere to run and nothing to run on.

  Starting is still best-effort underneath: `start_agent/2` records `:starting`
  and the machine confirms. A project whose laptop is closed has a main agent
  that is asked-for and unconfirmed, which is the honest state rather than an
  error.
  """
  @spec ensure_main_agent(Scope.t()) ::
          {:ok, Agent.t()} | {:error, :no_main_working_copy | start_error()}
  def ensure_main_agent(%Scope{} = scope) do
    case {WorkingCopies.main(scope), main_agent(scope)} do
      {nil, _} -> {:error, :no_main_working_copy}
      {_copy, %Agent{} = agent} -> {:ok, agent}
      {copy, nil} -> main_or_start(scope, copy, off_in_seat(scope, copy.id, :main))
    end
  end

  # A main agent somebody turned off is still the project's agent; opening the
  # project shows it off rather than starting another (39af5611).
  defp main_or_start(_scope, _copy, %Agent{} = off), do: {:ok, off}

  # Main comes up with the rest of the main copy's roster beside it: product,
  # one per project (John, step 4c). Only when main itself is started, so
  # opening a project whose main is running starts nothing. Best-effort, as
  # staffing a copy is; an off product is left alone (39af5611).
  defp main_or_start(scope, copy, nil) do
    with {:ok, main} <- start_main_agent(scope, copy) do
      ensure_copy_agents(scope, copy, RoleProfile.roles_where_home(:main) -- [:main])
      {:ok, main}
    end
  end

  @doc """
  The agents a working copy does its work with, started if they are not there
  yet.

  The roster belongs to the **copy**, not to the epic it was given. John,
  2026-09-04: *"when we come up with a working copy the three agents are there,
  and if that working copy is assigned more work it's gonna be the same three
  agents ... those are gonna be the guys who are gonna be taking work off of the
  graph."*

  So this is idempotent by role: a copy that already has a coding agent gets no
  second one, which is what makes a second epic cheaper than the first rather
  than more processes on the machine. It is also what keeps
  `WorkingCopies.offboard/2` meaningful — if agents accumulated per epic,
  discarding the copy would stop meaning that the work on it is over.

  The default roster is the copy's home roles (`home_roles/1`): coding and QA
  on a feature copy, main and product on the main copy (John, step 4c).

  Best-effort per role, and deliberately not all-or-nothing. Each `start_agent/2`
  records `:starting` and the machine confirms; a copy whose provider is
  connected for one role and not another gets the agents it can have and reports
  the ones it cannot, rather than refusing the whole roster over one. The caller
  gets both lists so it can say which.
  """
  @spec ensure_copy_agents(Scope.t(), map()) ::
          %{started: [Agent.t()], failed: [{atom(), term()}], off: [Agent.t()]}
  def ensure_copy_agents(scope, copy, roles \\ nil)

  def ensure_copy_agents(%Scope{} = scope, %{id: copy_id, root: root} = copy, nil)
      when is_binary(copy_id) and is_binary(root) and root != "",
      do: ensure_copy_agents(scope, copy, home_roles(copy))

  def ensure_copy_agents(%Scope{} = scope, %{id: copy_id, root: root}, roles)
      when is_binary(copy_id) and is_binary(root) and root != "" do
    agents =
      scope
      |> AgentsRepository.list_agents()
      |> Enum.filter(&(&1.working_copy_id == copy_id and not Agent.retired?(&1)))

    # A role somebody turned off is left alone and reported, not a failure; a
    # retired seat is empty and gets filled (39af5611).
    off = Enum.filter(agents, &(Agent.off?(&1) and &1.role in roles))
    off_roles = MapSet.new(off, & &1.role)

    # A role with an agent on duty is filled, whether or not its process is up
    # this moment: one being restored is not a vacancy to start a second into.
    filled = agents |> Enum.filter(&on_duty?/1) |> MapSet.new(& &1.role)

    roles
    |> Enum.reject(&(MapSet.member?(filled, &1) or MapSet.member?(off_roles, &1)))
    |> Enum.reduce(%{started: [], failed: []}, fn role, acc ->
      case start_copy_agent(scope, copy_id, root, role) do
        {:ok, agent} -> %{acc | started: [agent | acc.started]}
        {:error, reason} -> %{acc | failed: [{role, reason} | acc.failed]}
      end
    end)
    |> then(&%{started: Enum.reverse(&1.started), failed: Enum.reverse(&1.failed), off: off})
  end

  # A row with no root is not a checkout — the same rule `EpicDispatch`'s
  # `destination/1` applies. Starting agents against a directory that does not
  # exist produces three lanes that cannot run and a copy that looks staffed.
  def ensure_copy_agents(%Scope{}, _copy, _roles),
    do: %{started: [], failed: [{:copy, :no_checkout}], off: []}

  @doc """
  The roles a feature copy is staffed with when nobody says otherwise.

  Coding and QA — the two that build something (John, step 4c). Main and
  product are not among them: they are the project's, live on the main copy,
  and staffing them per copy would give a project as many orchestrators and
  designers as it has worktrees.
  """
  @spec copy_roles() :: [atom()]
  def copy_roles, do: RoleProfile.feature_roles()

  @doc """
  The roles that belong on `copy`: main and product on the project's main
  copy, `copy_roles/0` on any other.
  """
  @spec home_roles(map()) :: [atom()]
  def home_roles(%{main: true}), do: RoleProfile.roles_where_home(:main)
  def home_roles(_copy), do: RoleProfile.feature_roles()

  @doc """
  The roles no agent in `agents` holds a seat for: what staffing would fill.

  An off agent holds its seat; a retired one does not (39af5611). Pass every
  agent on the copy that matters, off ones included.
  """
  @spec empty_seats([Agent.t()], [atom()]) :: [atom()]
  def empty_seats(agents, roles \\ RoleProfile.feature_roles()) do
    held = agents |> Enum.reject(&Agent.retired?/1) |> MapSet.new(& &1.role)
    Enum.reject(roles, &MapSet.member?(held, &1))
  end

  @doc """
  Staff one working copy and put it into continuous mode, resolving the project
  and the owner from the copy itself.

  The counterpart to `turn_off_any_agent/1`, and it exists because the alternative
  does not work. Staffing from a `mix run` script creates the rows and reaches
  no harness: the channel registry lives in the server's own VM, so a second
  BEAM writes three agents that will never start and an orchestrator message
  nobody receives. Watched 2026-09-08 — three `claude-code` agents in
  `starting`, a menu in each transcript, and not one line in `harness.log`.

  Whoever's model settings decide the provider has to be the owner rather than
  the caller, since the caller here is an operator route with no session. Read
  from the account, so a copy is staffed the way its owner configured it.

  Takes an explicit role list for the case the default set cannot express: one
  role on each of several copies. A QA fixture for the wake criteria needs two
  *coding* agents to show that only the assigned one is woken, and a checkout
  holds one agent, so the shape is one role per copy rather than three on one.
  Staffing every copy with `copy_roles/0` would put twelve agents on four
  checkouts to get the four that were wanted.
  """
  @spec staff_any_copy(Ecto.UUID.t(), [atom()] | nil) ::
          {:ok, map()} | {:error, :no_such_copy | :no_owner}
  def staff_any_copy(copy_id, roles \\ nil) when is_binary(copy_id) do
    with {:ok, copy} <- WorkingCopies.fetch(copy_id),
         {:ok, scope} <- owner_scope(copy) do
      result = ensure_copy_agents(scope, copy, roles)
      {:ok, continuous} = set_copy_continuous(scope, copy_id, true)
      {:ok, Map.put(result, :continuous, continuous)}
    end
  end

  @doc """
  Put a working copy's agents into continuous mode, or take them out, resolving
  the owner from the copy.

  The same call `staff_any_copy/1` makes at the end, on its own, so a copy can
  be switched off without being re-staffed and back on without being restarted.

  Switching on takes the first turn — `set_copy_continuous/3` rings the bell
  itself, for the reason R13 records: an agent is a supervised process that is
  alive and idle and acts when it is messaged, so setting the flag alone marks
  it willing to work and leaves it exactly as it was.
  """
  @spec set_any_copy_continuous(Ecto.UUID.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, :no_such_copy | :no_owner | term()}
  def set_any_copy_continuous(copy_id, continuous?)
      when is_binary(copy_id) and is_boolean(continuous?) do
    with {:ok, copy} <- WorkingCopies.fetch(copy_id),
         {:ok, scope} <- owner_scope(copy) do
      set_copy_continuous(scope, copy_id, continuous?)
    end
  end

  defp owner_scope(%{project_id: project_id, id: copy_id}) do
    case Repo.get(CodeMySpec.Projects.Project, project_id) do
      nil ->
        {:error, :no_such_copy}

      project ->
        case account_owner(project.account_id) do
          nil ->
            {:error, :no_owner}

          user ->
            {:ok,
             %Scope{
               user: user,
               user_id: user.id,
               active_project: project,
               active_project_id: project.id,
               active_account_id: project.account_id,
               active_working_copy_id: copy_id
             }}
        end
    end
  end

  # The earliest member, which is the account's creator. An account with
  # several people has several sets of model settings and no rule here can pick
  # between them — the owner is the least surprising answer and the only one
  # that is stable.
  defp account_owner(account_id) do
    account_id
    |> MembersRepository.list_account_members()
    |> Enum.sort_by(& &1.id)
    |> List.first()
    |> case do
      nil -> nil
      member -> member.user
    end
  end

  @doc """
  Put a working copy's agents into continuous mode, or take them out of it.

  Story 538's R13: continuous mode is turned on and off deliberately. Until this
  the only way in was working the `start_implementation` task and the only way
  out was `tap_out` — so a mode governing whether agents keep running had no
  front door and no switch, and every agent in the database sat at `false`
  because nothing had ever put one anywhere else.

  Per copy rather than per agent, because that is the unit somebody actually
  decides about: a checkout is working, or it is not. The three roles on it keep
  their own mode column so a later change can stop one of them without stopping
  the others — R6 lets a coding agent go home when coding work runs out while
  product carries on.

  Stopped agents are left alone. Putting a mode on a process that is gone
  records an intention nothing will act on, and it would come back to life
  looking like a running loop the next time the row was read.

  ## Switching it on takes the first turn

  An agent is a supervised process that is alive and idle, and it acts when it
  is messaged — nothing polls. So setting the flag and stopping there marked
  three agents *willing* to work and left them exactly as they were: John,
  within the hour, "I don't see those agents running."

  R12's wake cannot rescue it either, because that fires when a task completes,
  and no task can complete if nobody ever takes a turn. The switch has to ring
  the bell itself.

  Only on the way on. Switching off is the absence of a message, which is what
  letting an agent stop means.
  """
  @spec set_copy_continuous(Scope.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def set_copy_continuous(%Scope{} = scope, copy_id, continuous?) do
    with {:ok, count} <- AgentsRepository.set_copy_continuous(scope, copy_id, continuous?) do
      if continuous? do
        # Somebody is working this project now, so something has to notice when
        # its graph moves. Started here rather than at boot: a project nobody is
        # working on needs no watcher.
        GraphWatcher.ensure_watching(scope)

        # And something has to look in on the agents themselves. Same trigger,
        # same reason, and it belongs beside the watcher rather than only in the
        # boot seed — QA of story 1017 found a project with eleven running
        # agents reporting `woken=yes, running=no`, because it gained its
        # continuous agent after boot and nothing started its cadence.
        MainAgent.ensure_cadence(scope)

        # And the graph has to hold something worth a turn.
        #
        # Admission asks what the graph holds for the role at that instant, and
        # on a copy nothing has scanned there is nothing in it:
        # `personas_complete` reads a verdict `Files.Scanner` decides at
        # sync time, and it gates `stories_exist`, which gates everything after
        # it. The project chain is one line, so an unscanned copy has an empty
        # actionable set for every role no matter what is on disk — and the
        # first switch-on is exactly when somebody expects their agents to
        # start. Issue `a0780389`, story 1004.
        #
        # Asked of the harness rather than done here, because this side does
        # not have the files — on the light harness the server holds no working
        # copy at all. The manifest that comes back announces graph inputs, the
        # watcher recomputes, and `Work.consider_project/2` asks against a real
        # graph. So the admission below is for what is already computed, and
        # the rescan is what covers the copy that has none.
        request_rescan(scope, copy_id)

        Work.consider_copy(scope, copy_id, :continuous_enabled)
      end

      {:ok, count}
    end
  end

  @doc """
  Point every live agent of one working copy at its current root.

  For `HarnessProjectChannel` to call right after a join corrects
  `working_copies.root` — see `AgentsRepository.sync_working_copy_root/3` for
  why an agent's own `working_copy` snapshot needs the same correction rather
  than trusting `report_root/2` alone to fix a restore.
  """
  @spec sync_working_copy_root(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_working_copy_root(%Scope{} = scope, copy_id, root) when is_binary(root) do
    AgentsRepository.sync_working_copy_root(scope, copy_id, root)
  end

  @doc """
  Set continuous intent without starting, restarting, or stopping a process.

  Enabling requests a turn only when the existing agent is runnable. Disabling
  leaves any current turn and queued conversation content intact.
  """
  @spec set_agent_continuous(Scope.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, Agent.t(), :enabled_and_turn_requested | :enabled_without_work | :paused}
          | {:error, term()}
  def set_agent_continuous(%Scope{} = scope, agent_id, continuous?) do
    with {:ok, agent} <- AgentsRepository.set_agent_continuous(scope, agent_id, continuous?) do
      if continuous? do
        GraphWatcher.ensure_watching(scope)
        MainAgent.ensure_cadence(scope)
        # A person switching an agent on is telling it to work, as a denied
        # tap-out is: what it last declined does not hold the turn back.
        {:ok, agent} = Work.clear_decline(scope, agent)
        {:ok, agent, enabled_disposition(scope, agent)}
      else
        {:ok, agent, :paused}
      end
    end
  end

  # Whether the bell reached anything, rather than only that it was rung.
  #
  # Switching on is not one outcome: an agent with eligible work takes a turn
  # now, and an agent with none sits exactly as it did. Both used to answer
  # "the existing agent may take another turn when idle and eligible for work",
  # byte for byte, so the operator asking "why are my agents not running" — the
  # confusion this tool exists to resolve — had to make a second call to find
  # out. Measured live by QA on story 796 (`fe059aa3`): two enables, one that
  # admitted a turn and one that admitted nothing, indistinguishable from the
  # reply.
  defp enabled_disposition(scope, agent) do
    case Work.request_turn_if_runnable(scope, agent, :continuous_enabled) do
      {:ok, ref} when is_binary(ref) -> :enabled_and_turn_requested
      _not_runnable -> :enabled_without_work
    end
  end

  # A copy whose machine is not connected cannot be asked, and that is not a
  # reason to refuse the switch — the flag is still set, the agents are still
  # considered against whatever is computed, and the copy scans when its
  # harness comes back. Logged rather than swallowed so a copy that never scans
  # is findable.
  defp request_rescan(%Scope{} = scope, copy_id) do
    case Analysis.request_rescan(%Scope{scope | active_working_copy_id: copy_id}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info(
          "[Agents] switched on #{copy_id} without a rescan (#{inspect(reason)}); " <>
            "roles are considered against whatever the graph already holds"
        )

        :ok
    end
  end

  defp start_copy_agent(scope, copy_id, root, role) do
    with {:ok, provider, model} <- role_choice(scope, role) do
      start_agent(scope, %{
        provider: provider,
        model: model,
        working_copy: root,
        working_copy_id: copy_id,
        role: role
      })
    end
  end

  # Same shape as `main_choice/1`: an explicit setting for this role wins and is
  # recorded, otherwise the role's own default order decides.
  defp role_choice(scope, role) do
    case resolve_model(scope, role) do
      {:ok, {provider, model}, :set} ->
        {:ok, provider, model}

      _unset_or_nothing_connected ->
        with {:ok, provider} <- connected_provider(scope) do
          {:ok, provider, default_model_for(role, provider)}
        end
    end
  end

  defp default_model_for(role, provider) do
    Defaults.for_role(role)
    |> Enum.find_value(fn {candidate, model} -> candidate == provider && model end)
  end

  defp start_main_agent(scope, copy) do
    with {:ok, provider, model} <- main_choice(scope) do
      start_agent(scope, %{
        provider: provider,
        model: model,
        working_copy: copy.root,
        working_copy_id: copy.id,
        role: :main
      })
    end
  end

  # An explicit choice wins, and is recorded.
  #
  # This path used to skip `resolve_model/2` entirely — it passed a provider it
  # had picked itself and no model at all — so `main` was the one agent type
  # where stories 983 and 984's setting had no effect, and the `model` column
  # 983 added so that "a running agent keeps the model it started on" was
  # always NULL for the one agent a non-technical user talks to. Someone who
  # pointed `main` at a provider got a different one with nothing saying so.
  #
  # Only the *unset* case still goes through `@provider_preference`, and that
  # is deliberate rather than tidy. See the note there.
  defp main_choice(scope) do
    case resolve_model(scope, :main) do
      {:ok, {provider, model}, :set} -> {:ok, provider, model}
      _unset_or_nothing_connected -> preferred_main(scope)
    end
  end

  defp preferred_main(scope) do
    with {:ok, provider} <- connected_provider(scope) do
      {:ok, provider, default_main_model(provider)}
    end
  end

  # The model `Defaults` names for whichever provider we landed on, so the row
  # says what it is running rather than nothing. `nil` for a provider with no
  # entry, which is the same as before and no worse.
  defp default_main_model(provider) do
    Defaults.for_role(:main)
    |> Enum.find_value(fn {candidate, model} -> candidate == provider && model end)
  end

  # The first connected provider, in an order somebody chose.
  #
  # Flat-rate before metered, and that is the whole point of writing the list
  # out. `Providers.names/0` is alphabetical, so taking its head would put
  # every main agent on `anthropic` — the one that bills per token — for a user
  # who has a subscription connected and never asked to spend credits on an
  # agent that is always on.
  #
  # `:not_connected` when none of them is, which is a different problem from
  # having nowhere to run and gets a different remedy in front of the user.
  #
  # ## Why this disagrees with `Defaults` on purpose, for now
  #
  # `Defaults.for_role(:main)` leads with `anthropic`, on the argument that the
  # main agent is the one explaining a project to somebody who cannot read the
  # code. This list leads with the subscription, on the argument above. Two
  # lists that disagree is normally the bug — it was reported as one — and
  # collapsing them was deferred deliberately, because neither is right.
  #
  # The missing dimension is **where the agent runs**. A subscription
  # credential is a subscription: the providers do not license it for a server
  # running agents on somebody's behalf, so a cloud-run agent has to use an API
  # key — the user's if they have one, ours if they do not. Locally, their
  # subscription is exactly what they should be spending. So the right ordering
  # is not one list at all; it is a different answer per location, and neither
  # `Defaults` nor this list has anywhere to say that.
  #
  # Until that exists, an explicit setting wins (see `main_choice/1`) and the
  # unset case keeps behaving as it always has, so nobody's bill moves because
  # of a refactor.
  @provider_preference ["openai-codex", "zai", "anthropic", "deepinfra"]

  defp connected_provider(scope) do
    Enum.find_value(@provider_preference, {:error, :not_connected}, fn provider ->
      case Credential.fetch(scope, provider) do
        {:ok, _credential} -> {:ok, provider}
        {:error, _reason} -> nil
      end
    end)
  end

  @doc """
  Move the project's own agent to a different checkout.

  Called when the main working copy is re-designated. The agent keeps its id,
  so it keeps its conversation — the whole reason this is a move rather than a
  replacement.

  The machine is asked to run it in the new place, and best-effort for the same
  reason starting is: a copy whose harness is not connected leaves the row
  `:starting`, which is the honest state rather than a failure to re-designate.
  """
  @spec move_main_agent(Scope.t(), map()) :: {:ok, Agent.t()} | {:error, term()} | :none
  def move_main_agent(%Scope{} = scope, copy) do
    case main_agent_anywhere(scope) do
      nil ->
        :none

      %Agent{working_copy_id: id} when id == :erlang.map_get(:id, copy) ->
        :none

      %Agent{} = agent ->
        with {:ok, moved} <- relocate(scope, agent, copy) do
          move_main_copy_roster(scope, agent.working_copy_id, copy)
          {:ok, moved}
        end
    end
  end

  defp relocate(scope, agent, copy) do
    with {:ok, moved} <-
           AgentsRepository.update_agent(scope, agent, %{
             working_copy_id: copy.id,
             working_copy: copy.root
           }) do
      broadcast(scope, {:agent_started, moved})
      {:ok, moved}
    end
  end

  # Product lives where main lives (step 4c), so it moves with it.
  defp move_main_copy_roster(scope, from_id, copy) do
    others = RoleProfile.roles_where_home(:main) -- [:main]

    scope
    |> seat_holders()
    |> Enum.filter(&(&1.working_copy_id == from_id and &1.role in others))
    |> Enum.each(&relocate(scope, &1, copy))
  end

  # The project's agent wherever it currently is, which during a move is not
  # the main copy — that is the point of moving it.
  defp main_agent_anywhere(%Scope{} = scope), do: scope |> running_main_agents() |> List.first()

  @doc """
  Send an operator's message at a running agent, without waiting for the turn.

  Like `message_agent/4`, this waits only for admission. It also returns the
  conversation message so a page can display its delivery state.

  Record the message as pending and link its Offer before dispatch. Delivery
  can be announced before the transport reply arrives; both must already
  exist when that event lands. A definitive failure marks the message failed
  and its Offer undelivered. A timeout leaves delivery unconfirmed.

  `{:ok, :started}` means the agent has it. `{:ok, :queued}` means it will when
  the turn ends, and until then it can be taken back.

  `event` is what `Wake` is asked about: `:operator_message` for a person at a
  page, `:own_reply` for the outcome of a run the agent started. A hold answers
  as `Wake.to_error/1` says.
  """
  @spec dispatch_message(Scope.t(), Ecto.UUID.t(), String.t(), Wake.event()) ::
          {:ok, :started | :queued, Conversations.Message.t()} | {:error, term()}
  def dispatch_message(scope, id, text, event, timeout \\ @message_timeout_ms)

  def dispatch_message(%Scope{} = scope, id, text, event, timeout) when is_binary(text),
    do: dispatch_message(scope, id, text, event, timeout, [])

  def dispatch_message(%Scope{} = scope, id, text, event, timeout, opts) when is_binary(text) do
    ref = Ecto.UUID.generate()

    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <- wake(scope, agent, event),
         :ok <- within_turn_cap(scope, agent),
         {:ok, conversation} <- open_conversation(scope, agent),
         {:ok, message} <-
           record_sent(
             conversation,
             text,
             ref,
             :queued,
             Keyword.get(opts, :sender_id, "operator")
           ) do
      subject = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      offered = Offers.record({:ok, message}, agent, :instruction, {"message", subject})

      result =
        agent.working_copy_id
        |> Transport.dispatch_message(agent, ref, text, timeout)
        |> record_dispatch_result(message, offered)

      report_repeated_instruction(scope, agent, offered)
      result
    end
  end

  defp report_repeated_instruction(scope, agent, offered) do
    if Offers.take_instruction_attention(offered) do
      notify_main(
        scope,
        :teammate_stalled,
        "An operator repeated an instruction to agent #{agent.id}. " <>
          "Review Offer #{offered.id} and its delivery history. The message was submitted " <>
          "unchanged; it was not withheld. Pending delivery is not evidence of refusal.",
        offer: {:stalled, {"agent", agent.id}}
      )
    else
      :ok
    end
  end

  # The row and offer exist before the engine can announce delivery. A late
  # queued acknowledgement must never overwrite an earlier delivery event.
  defp record_dispatch_result({:ok, :started}, message, _offered) do
    case Conversations.pending_message_by_ref(message.delivery_ref) do
      nil -> :ok
      pending -> Conversations.set_delivery(pending, :delivered)
    end

    {:ok, :started, Repo.get!(Conversations.Message, message.id)}
  end

  defp record_dispatch_result({:ok, :queued}, message, _offered),
    do: {:ok, :queued, Repo.get!(Conversations.Message, message.id)}

  # A missing acknowledgement does not prove delivery or failure. Keep the
  # pending record so a later delivery event can establish what happened.
  defp record_dispatch_result({:error, :message_timed_out} = error, _message, _offered),
    do: error

  defp record_dispatch_result({:error, _reason} = error, message, offered) do
    Offers.undelivered(offered)
    Conversations.set_delivery(message, :failed)
    error
  end

  defp wake(scope, agent, event) do
    case Wake.allow?(scope, agent, event) do
      :ok -> :ok
      hold -> Wake.to_error(hold)
    end
  end

  @doc """
  How many turns an agent on our credential gets, and how many are left.

  `{used, cap}` for an agent we are paying for, `:uncapped` for one the visitor
  is paying for themselves. The view needs both numbers rather than a boolean:
  a limit somebody discovers by hitting it is a worse experience than one they
  could see coming.
  """
  @spec turn_allowance(Scope.t(), Agent.t()) ::
          {non_neg_integer(), pos_integer()} | :uncapped
  def turn_allowance(%Scope{} = scope, %Agent{} = agent) do
    # `provider`, not `engine`. The engine is `:alloy` -- what runs -- and the
    # provider is whose subscription it spends. Asking Credential about the
    # engine returns `:none` for every agent, which means the cap compiles,
    # every credential test passes, and it never once binds.
    case Credential.source(scope, agent.provider) do
      :platform -> {turns_used(scope, agent), turn_cap()}
      _ -> :uncapped
    end
  end

  @doc "Turns an agent on our credential gets before it stops answering."
  @spec turn_cap() :: pos_integer()
  def turn_cap do
    :code_my_spec
    |> Application.get_env(Credential, [])
    |> Keyword.get(:platform_turn_cap, @default_turn_cap)
  end

  # The cap exists because we are paying, so it is asked here rather than at
  # start: the visitor may connect their own provider mid-conversation, and
  # from that moment they are paying and the cap has no business applying.
  #
  # Refused at dispatch and nowhere else, because dispatch is the one door a
  # turn comes through. Capping at start would only stop the eleventh
  # conversation, not the eleventh turn of the first one.
  defp within_turn_cap(scope, agent) do
    case turn_allowance(scope, agent) do
      :uncapped -> :ok
      {used, cap} when used < cap -> :ok
      {_used, cap} -> {:error, {:turn_cap_reached, cap}}
    end
  end

  # What the visitor has said, not what the agent has answered. A turn is
  # something they spend; counting the agent's replies would charge them for a
  # model that answered twice.
  defp turns_used(scope, agent) do
    case open_conversation(scope, agent) do
      {:ok, conversation} -> Conversations.count_messages(conversation, :operator)
      _ -> 0
    end
  end

  # Started or queued, on the row. The difference is the only thing the sender
  # can still act on, so it is not something the view infers from a timestamp.
  defp record_sent(conversation, text, ref, disposition, sender_id \\ "operator") do
    Conversations.add_message(conversation, :operator, text, sender_id, [],
      delivery: delivery_of(disposition),
      delivery_ref: ref
    )
  end

  defp delivery_of(:started), do: :delivered
  defp delivery_of(:queued), do: :pending

  @doc """
  Take back a message the agent has not picked up yet.

  Asked of the machine first and recorded second, for the same reason as
  sending: the agent's process is the only thing that knows whether the turn
  ended a moment ago, and a withdrawal that only cleared the record would leave
  the operator believing the agent will not see something it is about to act
  on.

  `{:error, :already_delivered}` is the honest answer to a click that lost the
  race — which is most of them, because people click when a turn is about to
  end.
  """
  @spec withdraw_message(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Conversations.Message.t()} | {:error, term()}
  def withdraw_message(%Scope{} = scope, id, ref) when is_binary(ref) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <-
           agent.working_copy_id
           |> Transport.impl().withdraw_message(agent, ref, @message_timeout_ms)
           |> taken_back(),
         %Conversations.Message{} = message <- Conversations.pending_message_by_ref(ref) do
      Conversations.set_delivery(message, :withdrawn)
    else
      # The machine took it back and the row is already gone or already
      # settled. Nothing to correct, and nothing worth failing over.
      nil -> {:error, :not_pending}
      error -> error
    end
  end

  # A ref the harness never queued, typically one a restart dropped, will
  # never be delivered (5150cd98).
  defp taken_back({:error, :never_received}), do: :ok
  defp taken_back(result), do: result

  @doc """
  Write one step an agent took to the conversation it belongs to.

  Written on arrival rather than accumulated until the turn completes. A turn
  that fails has already left everything it did behind it, which is the whole
  point of watching one — an agent going wrong is exactly the turn that does
  not finish cleanly.

  Here rather than in the channel because the channel is the wire, not the
  decision. A spex driving "the machine reported a step" has to drive this, and
  a private function inside a channel handler cannot be driven at all.
  """
  @spec record_turn_event(Scope.t(), Ecto.UUID.t(), map(), keyword()) :: :ok
  def record_turn_event(scope, agent_id, event, opts \\ [])

  # A turn ending is not a step, so nothing is written to the transcript for it.
  # It is the moment the orchestrator gets to speak — the internal equivalent of
  # an external agent's Stop hook firing, which is the one thing this runtime
  # never had. Story 1043.
  #
  # A turn ending starts no analysis (John, 2026-10-04): the decision below
  # reads the problems runs already persisted. `opts` reaches
  # `StopDecision.deliver/3` for callers that drive this path directly.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "turn_ended"}, opts) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, agent} ->
        # The turn is over, so nothing is in flight. Cleared before the decision
        # rather than after: `deliver/3` runs the whole stop menu — graph and
        # problems — and an agent read during it would show a turn that ended
        # as still running.
        # Read before the clear: `Work.record_decline/3` needs it to tell a turn
        # that closed a task from one that did nothing, and the next line is
        # what destroys it.
        turn_started_at = agent.turn_started_at

        {:ok, agent} =
          AgentsRepository.update_agent(
            scope,
            agent,
            Map.merge(%{turn_started_at: nil}, refusal_outlived(agent, turn_started_at))
          )

        broadcast(scope, {:agent_turn, agent})

        # Before the stop menu, because `deliver/3` is what produces the
        # observation that fires `Work.consider_project/2` — recording the
        # decline afterwards would lose the race with the wake it is meant to
        # damp.
        {:ok, agent} = Work.record_decline(scope, agent, turn_started_at)

        # Settled before the stop menu, which may make new offers of its own.
        :ok = Offers.settle_turn(agent)
        tell_main_held_back(scope, agent)

        StopDecision.deliver(scope, agent, opts)

      _ ->
        :ok
    end
  end

  # A turn beginning, which nothing used to record.
  #
  # Written to the row rather than only the transcript, because the question it
  # answers is about *now* — is this agent mid-response — and a transcript
  # answers it only by the absence of something later, which is not a thing you
  # can query. Story 1054, criterion 3297.
  #
  # Still written to the transcript as well: the step is part of what the agent
  # did, and the row is the current state of it. Two different questions.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "turn_started"} = event, _opts) do
    # A queued turn keeps the run's start. The harness announces every start but
    # only the run's end, so overwriting here dated the run from its last turn and
    # `Work.record_decline/3` missed a task an earlier turn closed — the coder was
    # damped for ten minutes as having refused work (35e80d6d).
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         {:ok, agent} <-
           AgentsRepository.update_agent(scope, agent, %{
             turn_started_at: agent.turn_started_at || DateTime.utc_now(),
             work_request_id: nil,
             work_requested_at: nil
           }),
         _ = broadcast(scope, {:agent_turn, agent}),
         {:ok, conversation} <- open_conversation(scope, agent) do
      :ok = Offers.observe_instruction_turn(agent)
      write_turn_event(conversation, agent, event)
    else
      _ -> :ok
    end
  end

  # A turn cut off at the step limit, recorded as something done *to* the agent.
  #
  # Not as the agent's own words — it did not say this — and not as a step,
  # because a step is work and this is the absence of it. It goes to the agent
  # as a message, which is the one channel an agent actually reads.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "turn_cut_off"} = event, _opts) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, agent} ->
        # Sent, because the agent is the one that has to do something
        # differently next turn. Recorded as an orchestrator action it reached
        # the person watching and never the agent, which for "you ran out of
        # steps" means the same over-long turn again.
        send_off_channel(agent, event["text"] || "")

      _ ->
        :ok
    end
  end

  # A process that died, as the harness saw it go (2999a0cb).
  #
  # Before this a crash left the row `:running` until the next report reaped it,
  # `list_agent_work` then dropped it, and the reaped-agent restart runs only
  # when a harness joins — so a continuous agent stayed dead until a person
  # noticed.
  #
  # Said *to* the agent, as an operator line, not as a step: a step is written
  # as the agent speaking, and `RestartRepository` reads the agent speaking as
  # a restart that worked — so an agent dying on every turn would never reach
  # the three-strike refusal and would be restarted forever.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "agent_died"} = event, _opts) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, agent} -> account_for_death(scope, agent, event["text"])
      _ -> :ok
    end
  end

  # A failed turn that was neither a provider refusal nor a timeout (8e9a1d83).
  #
  # Its text used to be written as a step, which reads as the agent speaking,
  # and nothing offered the work again: a metric_flow agent's whole reply to a
  # request for a help page was "Claude Code returned tool_use without any tool
  # calls", the next turn moved on, and the request was gone. Six times from
  # 09-23 to 10-01.
  #
  # Now it is said to the agent, with the request it failed on, once. A turn
  # that fails on the re-offer is recorded and left: a failure that repeats on
  # every turn would otherwise buy a turn per failure, forever.
  def record_turn_event(
        %Scope{} = scope,
        agent_id,
        %{"kind" => "turn_failed", "text" => text} = event,
        _opts
      )
      when is_binary(text) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         {:ok, conversation} <- open_conversation(scope, agent) do
      # A refusal and a timeout each have a reader that finds this line on the
      # transcript (`ProviderRefusal`, `TurnTimeout`), so they stay there.
      if ProviderRefusal.read(text, DateTime.utc_now()) || TurnTimeout.exec(text) do
        record_refusal(scope, agent, event)
        write_turn_event(conversation, agent, event)
      else
        reoffer_failed_turn(conversation, agent, text)
      end
    else
      _ -> :ok
    end
  end

  def record_turn_event(%Scope{} = scope, agent_id, event, _opts) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         {:ok, conversation} <- open_conversation(scope, agent) do
      record_edit(agent, event)
      record_refusal(scope, agent, event)
      write_turn_event(conversation, agent, event)
    else
      # An agent that is not ours, or a step for one nobody can find. Dropped
      # rather than written somewhere plausible: a transcript under the wrong
      # agent is worse than a missing one, because it reads as that agent's
      # work.
      _ -> :ok
    end
  end

  # The cause, on the agent's own thread. Restarting it is its harness's
  # `Engine.Keeper`; telling main, when the Keeper gives up, is
  # `process_ended/3`'s.
  defp account_for_death(scope, agent, cause) do
    Logger.warning("[Agents] #{agent.role} agent #{agent.id} died: #{cause}")

    with {:ok, conversation} <- open_conversation(scope, agent) do
      Conversations.add_message(conversation, :operator, death_notice(cause), "operator")
    end

    :ok
  end

  @doc """
  An agent's process came up (`agent_up`, from its copy's harness): a start, a
  restore, or its Keeper restarting it after a crash.

  A process that has just come up is admissible again, and nothing else is going
  to say so. `Work.consider_project/2` is edge-triggered — a turn ending, a
  graph change, a harness joining — and an agent coming up is none of those. So
  an agent came back holding work and sat there: measured 2026-09-23, coding
  b01a95bb was resumed at 02:34:29 holding `story_promoted` on story 950 and
  took zero turns in eleven minutes.

  Here rather than straight after the start, because a turn goes only to an
  agent that is present, and at the start it is not yet.

  Two bells, because an agent that came up is in one of two states and they
  need opposite things. One holding the task the restart interrupted is told to
  carry on with it (`Work.resume_held_task/2`, scoped to the agent that came up).
  A harness reconnect separately sweeps the whole copy. One holding nothing is offered
  work if it is admissible (`Work.request_turn_if_runnable/4`). Each decides
  admissibility itself, so neither starts a turn for an agent that should not
  have one.
  """
  @spec came_up(Scope.t(), Ecto.UUID.t()) :: :ok
  def came_up(%Scope{} = scope, agent_id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id) do
      Work.resume_held_task(scope, agent.id)
      Work.request_turn_if_runnable(scope, agent, :restarted)
    end

    :ok
  end

  @doc """
  An agent's process ended (`agent_down`, from its copy's harness), with
  `reason` as the harness saw it.

  The harness supervises its agents: a crash is restarted there, by the agent's
  `Engine.Keeper`, and reaches the server as a down and an up that move
  presence and nothing else. The one down acted on here is the Keeper giving up
  on a crash loop (`"gave_up: …"`) — the agent is gone for good, and main is
  told, unless the agent was already off or retired. Mere absence — a harness
  restarting, a channel dropping — sends no down and so triggers nothing.
  """
  @spec process_ended(Scope.t(), Ecto.UUID.t(), String.t() | nil) :: :ok
  def process_ended(%Scope{} = scope, agent_id, "gave_up: " <> reason) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         true <- on_duty?(agent) do
      Logger.warning(
        "[Agents] #{agent.role} agent #{agent.id}'s harness gave up on it: #{reason}"
      )

      tell_main_teammate_died(
        scope,
        agent,
        "its process kept crashing (last: #{reason}) and its harness stopped restarting " <>
          "it after three restarts in ten minutes — a crash loop costs money on every lap. " <>
          "Find the cause, then restart_agent it"
      )
    else
      _ -> :ok
    end
  end

  def process_ended(%Scope{}, _agent_id, _reason), do: :ok

  # Step 4b (a31f1cd6): main is told when a teammate dies or is reaped, and is
  # woken for it past its own open question (John). Main's own death has nobody
  # to tell.
  defp tell_main_teammate_died(_scope, %Agent{role: :main}, _reason), do: :ok

  defp tell_main_teammate_died(scope, %Agent{} = agent, reason) do
    notify_main(
      scope,
      :teammate_died,
      "Teammate down: #{teammate(agent)} — #{reason}. Check it with " <>
        "list_agent_work, and restart_agent if it does not come back."
    )
  end

  # The agents one sweep reaped, as one message: a reconnect can reap a whole
  # copy at once, and a message each floods main. A sweep that reaped main too
  # says nothing; it hears about them through its restart.
  defp tell_main_reaped(_scope, []), do: :ok

  defp tell_main_reaped(scope, reaped) do
    if Enum.any?(reaped, &(&1.role == :main)) do
      :ok
    else
      notify_main(
        scope,
        :teammate_died,
        "Teammates down — reaped, their machine no longer reports them running:\n" <>
          Enum.map_join(reaped, "\n", &"  - #{teammate(&1)}") <>
          "\nCheck them with list_agent_work, and restart_agent any that do not come back."
      )
    end
  end

  defp teammate(%Agent{} = agent),
    do:
      "the #{agent.role} agent #{agent.id} on working copy #{agent.working_copy_id} " <>
        "(#{agent.working_copy})"

  @failed_turn "Your last turn failed: "

  defp reoffer_failed_turn(conversation, agent, failure) do
    request = Conversations.last_request_text(conversation)

    if is_binary(request) and String.starts_with?(request, @failed_turn) do
      Conversations.add_message(
        conversation,
        :operator,
        @failed_turn <> failure <> "\n\nIt failed again on the retry, so it was not re-sent.",
        "operator"
      )
    else
      send_off_channel(
        agent,
        failed_turn_notice(failure, request),
        {:retry, {"failed_turn", nil}}
      )
    end

    :ok
  end

  defp failed_turn_notice(failure, nil),
    do: @failed_turn <> failure <> "\n\nPick up where the thread leaves off."

  defp failed_turn_notice(failure, request) do
    """
    #{@failed_turn}#{failure}

    Nothing from it was carried out. The request was:

    #{request}

    Pick it back up.\
    """
  end

  # This runs in the harness channel, and sending to an agent is a call into
  # that same channel, which the transport refuses rather than deadlock — the
  # message was recorded and never delivered (once, 2026-10-01 12:14Z).
  defp send_off_channel(agent, text, offer \\ nil) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        send_to_agent(agent.id, text, :own_reply, offer: offer)
      end)

    :ok
  end

  defp death_notice(cause) do
    """
    Your process died at #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}: #{cause}

    The turn in flight was discarded and not recorded. Carry on from the turns \
    above; if you are unsure whether something landed, check rather than redo it.
    """
  end

  # A failed turn the provider refused, kept on the row as state (044599cc).
  # The transcript still gets the text; this is what `check_in` and `Work` read.
  defp record_refusal(scope, agent, %{"kind" => "turn_failed", "text" => text}) do
    now = DateTime.utc_now()

    case ProviderRefusal.read(text, now) do
      nil ->
        :ok

      refusal ->
        AgentsRepository.update_agent(scope, agent, Map.put(refusal, :provider_refused_at, now))
        wake_at_retry(scope, agent, refusal.provider_retry_at)
    end
  end

  defp record_refusal(_scope, _agent, _event), do: :ok

  # The held turn end runs at the retry time; with none named, an operator
  # restarts it, as before.
  defp wake_at_retry(_scope, _agent, nil), do: :ok
  defp wake_at_retry(scope, agent, retry_at), do: RefusalWake.schedule(scope, agent.id, retry_at)

  # A turn that ended without being refused clears the last refusal. A failed
  # turn also ends, so one refused *during* this turn stands.
  defp refusal_outlived(%{provider_refused_at: %DateTime{} = refused_at}, %DateTime{} = started) do
    if DateTime.compare(refused_at, started) == :lt,
      do: %{provider_refusal: nil, provider_refused_at: nil, provider_retry_at: nil},
      else: %{}
  end

  defp refusal_outlived(_agent, _turn_started_at), do: %{}

  # A compaction is not a step either. It is what the agent will resume from,
  # and it goes in its own table: a row in the transcript would have to be
  # skipped by every renderer, every preview and every `role` clause, and the
  # one that forgot would show a user a summary of their own conversation as
  # though the agent had said it.
  defp write_turn_event(conversation, _agent, %{"kind" => "compacted"} = event) do
    case Conversations.record_checkpoint(conversation, event["messages"] || [],
           turn: event["turn"]
         ) do
      {:ok, _checkpoint} ->
        :ok

      {:error, _changeset} ->
        # A checkpoint that will not save costs a longer resume, and nothing
        # else: the transcript is untouched and the agent is still running on
        # the summary it just made.
        Logger.info("[Agents] a compaction checkpoint for #{conversation.id} was not saved")
        :ok
    end
  end

  # A message the agent has just picked up is not a step of a turn — it is the
  # end of the operator's ability to take it back, and the only thing to record
  # is that.
  defp write_turn_event(conversation, agent, %{"kind" => "message_delivered", "ref" => ref})
       when is_binary(ref) do
    case Conversations.pending_message_by_ref(ref) do
      %{conversation_id: conversation_id} = message when conversation_id == conversation.id ->
        with {:ok, _} <- Conversations.set_delivery(message, :delivered) do
          CodeMySpec.Agents.CompletionHandoffs.delivered(message.id, agent)
        end

      _ ->
        :ok
    end
  end

  # A tool call is a tool call, not prose.
  #
  # `Conversations.add_tool_call/5` is what `Chat.Runner` and the sprite
  # recorder already write, and `chat_components` renders that `tool_calls`
  # array as call blocks. Internal agents went through `add_agent_message/4`
  # instead, so their calls arrived as ordinary chat messages carrying the tool
  # name as prose and nothing else — no arguments, no pairing, and the
  # `tool_calls` column unused. Issue `2d5b2d4d`.
  defp write_turn_event(conversation, agent, %{"kind" => "tool_start", "tool" => tool})
       when is_map(tool) do
    Conversations.add_tool_call(
      conversation,
      tool["id"],
      tool["name"],
      tool["input"] || %{},
      to_string(agent.role || :main)
    )

    :ok
  end

  # The end of a call is worth its own row only when it failed.
  #
  # `tool_end` carries the error and no result text, so a success has nothing to
  # record that the call itself did not already say — and writing one anyway is
  # what put every call in the transcript twice.
  defp write_turn_event(conversation, agent, %{"kind" => "tool_end", "tool" => tool})
       when is_map(tool) do
    case tool["error"] do
      error when is_binary(error) and error != "" ->
        Conversations.add_tool_result(
          conversation,
          tool["id"],
          tool["name"],
          error,
          failed?: true,
          agent_role: to_string(agent.role || :main)
        )

      _ ->
        :ok
    end

    :ok
  end

  # A step that said nothing is not a step.
  #
  # `parts_for("")` answers `[]`, so a textless event became a message whose
  # whole content was an empty list. They arrive constantly — a turn produces
  # dozens — and each one is a row, a broadcast, and a line in the transcript
  # that renders as the agent having spoken and said nothing.
  #
  # The cost was not storage. Measured 2026-09-08: a coding agent showed 99
  # empty messages against 0 substantive ones, and I read that as "the model is
  # returning nothing" and spent most of a day inside the provider — through
  # Codex, through a credential rotation, through Alloy's response parsing —
  # looking for a fault that was never there. The transcript was reporting
  # bookkeeping as speech.
  #
  # `announce_outcome/2` in `CmsHarness.Agents.Engine` is where a turn's *text*
  # is reported, and it has its own clause for a turn that finished with nothing
  # to say. This is the step channel, and a step with no text has nothing to
  # tell anybody.
  defp write_turn_event(_conversation, _agent, event)
       when not is_map_key(event, "text") do
    :ok
  end

  defp write_turn_event(conversation, agent, %{"text" => text} = event)
       when is_binary(text) do
    if String.trim(text) == "" do
      :ok
    else
      write_step(conversation, agent, event)
    end
  end

  # `%{"text" => nil}` is the shape that got through the first pass at this.
  # `is_binary/1` on the clause above sends it here, `parts_for(nil)` answers
  # `[]`, and the empty row is back — 45 of them on one agent in ten minutes,
  # after the fix that was supposed to have ended them.
  #
  # There is no fourth kind of step. Either an event carries text worth showing
  # or it does not, and everything reaching here does not.
  defp write_turn_event(_conversation, _agent, _event), do: :ok

  defp write_step(conversation, agent, event) do
    Conversations.add_agent_message(
      conversation,
      # `to_string`, because `role` became an `Ecto.Enum` in story 983 and
      # `agent_role` on a message is a string column. Without it the insert
      # fails and the step never reaches the page — which reads as an agent
      # that went quiet rather than as a type error.
      to_string(agent.role || :main),
      turn_event_kind(event),
      turn_event_text(event)
    )

    :ok
  end

  # What this agent wrote, as it writes it.
  #
  # `block_changed` narrows a source to the files the stopping agent touched,
  # and it learned that only from PostToolUse — which an agent under Alloy never
  # fires. Its edit set was therefore empty forever, so either every finding on
  # the tree was its own (unusable: a product agent inherited 160 credo findings
  # it had never seen) or none were (unusable: it was never told about the file
  # it had just broken). Neither is a policy question; both came from not
  # knowing what it had edited.
  #
  # Recorded here rather than in the harness because the harness has no
  # database, and on the tool *call* rather than on its result: a write that
  # failed still changed the file often enough that treating it as untouched is
  # the more expensive mistake.
  #
  # Only `write` and `edit`. `read`, `bash` and the script tools name paths too
  # — `bash` names a command — and recording those would make an agent
  # answerable for every file it has ever looked at.
  @writing_tools ~w(write edit)

  defp record_edit(%Agent{id: agent_id}, %{"tool" => %{"name" => name, "path" => path}})
       when name in @writing_tools and is_binary(path) and path != "" do
    FileEdits.track_agent_edit(agent_id, path)
  end

  defp record_edit(_agent, _event), do: :ok

  # The kinds a conversation already renders. An event this server does not
  # know is still worth keeping — it is something the agent did — so it lands
  # as a message rather than being discarded for not matching a list.
  defp turn_event_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp turn_event_kind(_event), do: "step"

  defp turn_event_text(%{"text" => text}) when is_binary(text), do: text
  defp turn_event_text(event), do: inspect(event)

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

    listed = AgentsRepository.list_reported_running(scope)

    running =
      listed
      |> Enum.map(&reap_if_absent(scope, &1, MapSet.member?(alive, &1.id)))
      |> Enum.filter(&(&1.status in [:starting, :running]))

    :ok = tell_main_reaped(scope, Enum.reject(listed, &MapSet.member?(alive, &1.id)))

    # A report is the only moment the server learns an agent went away, so it is
    # the only moment a page watching one can find out. Without this the row
    # keeps claiming an agent is working until somebody reloads, which is the
    # stale-row failure the reconcile exists to prevent, moved to the browser.
    broadcast(scope, {:agents_reported, running})

    {:ok, running}
  end

  @running_afresh %{
    status: :running,
    turn_started_at: nil,
    work_request_id: nil,
    work_requested_at: nil,
    stopped_reason: nil
  }

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
  # `to_string/1` on the stored side, because `agents.role` is an `Ecto.Enum`
  # and `role/1` reads a string off the wire. `:main == "main"` is false, so
  # this `find` never matched and every report took the `upsert(nil, ...)`
  # branch and inserted a fresh row. Measured 2026-09-20 before the fix: 31
  # main-role rows on one working copy, 17 qa, 12 coding — an agent per report
  # rather than an agent per lane. It is also where the "unexplained extra
  # main-role agent" (`47a63331`) came from, and it fed `held?/3`, which scans
  # every agent on a copy and so let long-dead duplicates withhold work.
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
    |> Enum.find(&(&1.working_copy_id == working_copy_id and to_string(&1.role) == role))
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
      AgentsRepository.update_agent(
        scope,
        agent,
        Map.merge(@running_afresh, %{
          engine: engine(report),
          os_pid: recorded_group_or_reported(agent, report)
        })
      )

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
  # it can be talked to at all. Defaulting every report to `:alloy` made a Claude
  # Code agent claim presence it does not have — caught by story 1019's criterion
  # 2830, which exists to keep those two facts apart.
  defp engine(%{"engine" => "claude_code"}), do: :claude_code
  defp engine(_report), do: :alloy

  # A harness that names no lane is running one, and "main" is what that one is
  # called. Falling back keeps every report written before roles existed landing
  # on the row it always did, rather than forking a duplicate the first time
  # this ships.
  defp role(%{"role" => role}) when is_binary(role) and role != "", do: role
  defp role(_report), do: "main"

  # An adopted Alloy lane gets the same transcript one we started gets.
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
  defp ensure_conversation(%Scope{} = scope, %Agent{engine: :alloy} = agent) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
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
    {:ok, stopped} = record_stopped(scope, agent, :reaped)
    stopped
  end

  @doc """
  Turn one agent off, and only that one: record who and why, then end its
  process.

  Off is the only deliberate stop (39af5611). It is intent, recorded before the
  process is asked to end, so an agent whose machine cannot be reached is still
  off: `Transport` delivers nothing to it and nothing restarts it until
  `turn_on_agent/2`. `by:` names who turned it off; `reason:` is optional.

  Stopping is only useful if it stops the right one: a stop that reaps the tree,
  or kills by name and catches a sibling, looks identical from the caller's side
  and is worse than having no stop at all.
  """
  @spec turn_off_agent(Scope.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Agent.t()} | {:error, term()}
  def turn_off_agent(%Scope{} = scope, id, opts \\ []) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <- refuse_retired(agent),
         {:ok, off} <- record_off(scope, agent, opts),
         :ok <- end_process(scope, off),
         {:ok, stopped} <- record_stopped(scope, off, :stopped) do
      broadcast(scope, {:agent_stopped, stopped})
      {:ok, stopped}
    end
  end

  # An agent already off keeps the record of who turned it off first.
  defp record_off(_scope, %Agent{off_at: %DateTime{}} = agent, _opts), do: {:ok, agent}

  defp record_off(scope, agent, opts) do
    AgentsRepository.update_agent(scope, agent, %{
      off_at: DateTime.utc_now(),
      off_by: trimmed(Keyword.get(opts, :by)) || "someone",
      off_reason: trimmed(Keyword.get(opts, :reason))
    })
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
  # The machine is always asked. An agent not present afterwards has no process
  # to end — one we asked for and no machine confirmed, or one already gone — so
  # a machine that could not be reached about it is not a failure: cancelling it
  # has to work. Present means a process is still running, and that answer
  # stands (`Agents.Presence`).
  #
  # This used to key on `os_pid` being nil. An agent is a supervised process now
  # and never has a group id, so that clause matched every stop: the row went to
  # `:stopped` and nothing was ever asked to end anything. The defect this story
  # exists for, reintroduced by deleting the field its guard happened to read.
  defp end_process(_scope, %Agent{} = agent) do
    result = Transport.impl().stop_agent(agent.working_copy_id, agent, @stop_timeout_ms)
    if present?(agent.project_id, agent), do: stopped?(result, agent), else: :ok
  end

  # An agent the machine is not running is stopped — asking again is how a
  # stop becomes idempotent. A machine that could not be *reached* is not, and
  # collapsing the two is what makes a row say stopped over something still
  # running.
  defp stopped?(:ok, _agent), do: :ok
  defp stopped?({:error, :not_running}, _agent), do: :ok

  # Unreachable is not always temporary. `Transport.Harness.unreachable/3`
  # assumes the process "may well still be running" on a machine we cannot
  # currently talk to — right when the working copy is still a real row, wrong
  # when it is not. A copy that no longer resolves at all (offboarded, or never
  # persisted past a scratch path) has nowhere left to hold a process, so there
  # is nothing left for this refusal to protect. Issue `8b591eba`: four agents
  # on a deleted `/tmp` checkout, unstoppable and still claiming their role
  # forever because every stop read the same as "machine is briefly down".
  defp stopped?({:error, :harness_not_connected} = error, agent) do
    case WorkingCopies.fetch(agent.working_copy_id) do
      {:error, :not_found} -> :ok
      {:error, :invalid_id} -> :ok
      {:ok, _} -> error
    end
  end

  defp stopped?({:error, _reason} = error, _agent), do: error

  # Only after something confirmed the process is gone. `os_pid` and
  # `os_boot_id` are cleared here rather than before, because until the process
  # is actually gone they are the only way to reach it again.
  # Stopping clears what only a live process could have meant.
  #
  # `turn_started_at` and `work_request_id` both say "something is happening
  # right now" — a turn in flight, a turn reserved and about to be dispatched —
  # and neither can be true of an agent with no process behind it. Left set,
  # they are worse than stale: `Work.runnable_state?/1` requires both to be nil,
  # so a reaped agent that comes back is permanently un-admittable, and nothing
  # would ever clear them because clearing them is what this function is for.
  #
  # The agent's *tasks* are deliberately not touched. A claim is a statement
  # about work, not about a process, and cancelling somebody's attempt because
  # their machine went away is a decision rather than a cleanup — `held?/3`
  # going on withholding a node claimed by a stopped agent is a real problem
  # (`68436370`) and a different one.
  #
  # 73d0d505: `reason` is the one thing this function's two callers actually
  # disagree about. `reap_if_absent/3` passes `:reaped` — nothing confirms
  # this was on purpose, a report simply stopped mentioning the agent.
  # `turn_off_agent/3` passes `:stopped` — something explicitly asked for this.
  # Both used to write an identical row, which is why nothing could ever
  # tell a role that went unstaffed by a restart from one a person meant to
  # leave stopped.
  defp record_stopped(scope, agent, reason) when reason in [:reaped, :stopped] do
    AgentsRepository.update_agent(scope, agent, %{
      status: :stopped,
      stopped_reason: reason,
      os_pid: nil,
      os_boot_id: nil,
      turn_started_at: nil,
      work_request_id: nil,
      work_requested_at: nil
    })
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

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
    AgentsRepository.update_agent(scope, agent, @running_afresh)
  end

  @doc """
  Which provider and model an agent type launches on, and why.

  Their setting when there is one and it still names a provider they hold, and
  `Defaults.resolve/2` against what they do hold otherwise. Public because the
  settings screen shows what a type *would* do before anybody chooses.

  ## A setting can outlive its credential

  Disconnecting a provider does not delete the rows naming it — deriving this
  instead of cleaning up means there is one place the answer comes from, and no
  window in which a row and the integrations table disagree. Read against what
  is connected right now, a stale row falls back on its own; cleaned up on
  disconnect, it would only be right if every path that removes a credential
  remembered to.

  Falling back rather than refusing, because the person already said what they
  want when there is a choice, and being asked again is being asked about
  something that has not changed.
  """
  @spec resolve_model(Scope.t(), atom()) ::
          {:ok, {String.t(), String.t() | nil}, :set | :default} | {:error, :no_provider}
  def resolve_model(%Scope{} = scope, role) do
    connected = connected_providers(scope)

    scope
    |> AgentsRepository.model_setting(role)
    |> honour_setting(role, connected)
  end

  defp honour_setting(%ModelSetting{provider: provider, model: model}, role, connected) do
    if provider in connected,
      do: {:ok, {provider, model}, :set},
      else: resolved_default(role, connected)
  end

  defp honour_setting(nil, role, connected), do: resolved_default(role, connected)

  defp resolved_default(role, connected) do
    with {:ok, choice} <- Defaults.resolve(role, connected) do
      {:ok, choice, :default}
    end
  end

  @doc "The agent types there are."
  @spec roles() :: [atom()]
  defdelegate roles(), to: Agent

  @doc "Every provider that can be chosen, connected or not."
  @spec provider_names() :: [String.t()]
  defdelegate provider_names(), to: Providers, as: :names

  @doc """
  Every provider this account can actually launch on.

  Asked of `Credential.fetch/2` rather than of the integrations table, so it
  answers the same question the launcher will ask a moment later. A provider
  listed here and refused at launch is the mismatch this exists to prevent.
  """
  @spec connected_providers(Scope.t()) :: [String.t()]
  def connected_providers(%Scope{} = scope) do
    Enum.filter(Providers.names(), &match?({:ok, _}, Credential.fetch(scope, &1)))
  end

  @doc "What each type runs on today, for every type. The settings screen reads this."
  @spec model_settings(Scope.t()) :: [
          %{role: atom(), provider: String.t() | nil, model: String.t() | nil, source: atom()}
        ]
  def model_settings(%Scope{} = scope) do
    Enum.map(Agent.roles(), fn role ->
      case resolve_model(scope, role) do
        {:ok, {provider, model}, source} ->
          %{role: role, provider: provider, model: model, source: source}

        {:error, :no_provider} ->
          %{role: role, provider: nil, model: nil, source: :none}
      end
    end)
  end

  @doc "Point an agent type at a provider and model."
  @spec put_model_setting(Scope.t(), atom(), String.t(), String.t() | nil) ::
          {:ok, ModelSetting.t()} | {:error, Ecto.Changeset.t() | :unknown_provider}
  def put_model_setting(%Scope{} = scope, role, provider, model) do
    # Refused here rather than at launch. A screen that stores a provider the
    # account cannot authenticate produces an agent that fails on its first
    # model call, minutes later, in a log nobody is reading — which is the
    # failure the credential ordering above exists to prevent, arriving through
    # the front door instead.
    if provider in connected_providers(scope),
      do: AgentsRepository.put_model_setting(scope, role, provider, model),
      else: {:error, :unknown_provider}
  end

  @doc """
  Let a type resolve from the defaults again.

  The counterpart to `put_model_setting/4`, and the thing whose absence made
  issue c6f5acce expensive: the settings form posts all four types at once, an
  untouched select posts the default's own value, so one Save converted every
  type from "whatever is sensible" to "this exact model, chosen deliberately" —
  and there was no way back.

  `ModelSetting`'s moduledoc argues against writing a default row at account
  creation, because it would freeze whatever the defaults were that day. Writing
  one on the first Save has the same effect; this is how it is undone.
  """
  @spec clear_model_setting(Scope.t(), atom()) :: :ok
  defdelegate clear_model_setting(scope, role), to: AgentsRepository

  # The type an agent is being started as. Refused rather than defaulted when it
  # names one that does not exist: `Agent.role` is an enum, and a caller asking
  # for a type nobody defined is a caller with the wrong idea about what exists.
  defp role_of(attrs) do
    case Map.get(attrs, :role, :main) do
      role when is_atom(role) ->
        known_role(role, role)

      role when is_binary(role) ->
        role |> Utils.safe_to_existing_atom(:__unknown__) |> known_role(role)
    end
  end

  # `asked` is carried separately from the atom, because the atom may be the
  # sentinel `Utils.safe_to_existing_atom/2` returns for a name that does not
  # exist — and a refusal naming `:__unknown__` tells the caller a word it
  # never sent.
  defp known_role(role, asked) do
    if role in Agent.roles(),
      do: {:ok, role},
      else: {:error, {:unknown_role, asked, Agent.roles()}}
  end

  # An explicit provider still wins — a caller that names one is asking for it,
  # and story 983 is about what happens when nobody does.
  defp provider_for(scope, role, attrs) do
    case Map.get(attrs, :provider) do
      nil ->
        with {:ok, {provider, model}, _source} <- resolve_model(scope, role) do
          {:ok, provider, model}
        end

      provider ->
        {:ok, provider, Map.get(attrs, :model)}
    end
  end

  # Computed at start, from the role and from what this agent's machine said it
  # could do.
  #
  # The machine half cannot come from a list here: a browser is an MCP server on
  # somebody's box, its tools are whatever that box's vibium reports, and a copy
  # written down here would drift the first time vibium ships one. So the
  # harness reports names on join and this reads them back.
  #
  # Only for the types that browse. A product agent shaping stories has no use
  # for a click, and handing it twenty-nine ways to make one is the catalogue
  # this story is about, one layer over.
  defp tools_for(%Scope{} = scope, attrs) do
    role = Map.fetch!(attrs, :role)

    case RoleProfile.tools(role) do
      # Everything, and not written down as a list on the row — see
      # `ToolSets.for_role/1`. A machine's tools need no adding to "all of them".
      :all -> nil
      granted -> granted ++ machine_tools(scope, attrs, role)
    end
  end

  defp machine_tools(scope, attrs, role) do
    with true <- RoleProfile.browses?(role),
         id when is_binary(id) <-
           Map.get(attrs, :working_copy_id) || scope.active_working_copy_id,
         {:ok, %{machine_tools: names}} when is_list(names) <- WorkingCopies.fetch(id) do
      names
    else
      _ -> []
    end
  end

  defp base_attrs(%Scope{} = scope, attrs) do
    %{
      engine: Map.get(attrs, :engine, :alloy),
      provider: Map.fetch!(attrs, :provider),
      # A record of what it launched with. Enforcement reads `tools_of/2`, so a
      # list passed here would be ignored and is not accepted.
      tools: tools_for(scope, attrs),
      model: Map.get(attrs, :model),
      working_copy: Map.get(attrs, :working_copy) || scope.cwd,
      role: Map.fetch!(attrs, :role),
      working_copy_id: Map.get(attrs, :working_copy_id) || scope.active_working_copy_id,
      status: :starting
    }
  end

  defp broadcast(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(scope), message)
  end

  defp topic(%Scope{active_project_id: project_id}), do: "agents:#{project_id}"
end
