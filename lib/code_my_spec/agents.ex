defmodule CodeMySpec.Agents do
  @moduledoc """
  The agents CodeMySpec has started, and the credential each one runs on.

  Server-side half of running an agent: which agents exist, on which working
  copy, role and provider, and the record a conversation attaches to.
  `CmsHarness.Agents` is the other half — the OS process on the device —
  reached over the harness channel. State and ordering live here; execution
  happens on the box.

  `start_agent/2` resolves the credential before anything else and refuses
  without a usable one: `:not_connected` (connect a provider) and
  `:reconnect_required` (reconnect one already connected) are kept distinct.

  An agent is recorded `:starting` and only reads as running when its process
  is present; its turns arrive in `Conversations` through
  `AgentHarness.relay_up/2`.

  See knowledge/agents, "Starting and restarting".
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
      CodeMySpec.PromotionQueue.Waits,
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
      CodeMySpec.Problems,
      CodeMySpec.Questions
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
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Agents.Main, as: MainAgent
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

  # How long we wait for a turn before answering `:still_working`; the agent is
  # not interrupted. Well under the code-mode sandbox's 30s wall clock, which
  # every `message_agent` call runs inside.
  # See knowledge/agents, "Timeouts".
  @message_timeout_ms 15_000

  @stop_timeout_ms 10_000

  # Roughly a conversation, not a session. Configurable: a commercial number.
  @default_turn_cap 10

  # Long enough for a cold start on a loaded box, short enough that a machine
  # that is never going to answer does not hold the caller.
  @start_timeout_ms 15_000

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
  defdelegate unassign_story(scope, story_id, opts \\ []), to: Assignment
  defdelegate assign_epic(scope, epic_id, copy_id), to: Assignment
  defdelegate notify_story_team_free(scope, copy_id, story), to: Assignment, as: :notify_team_free
  defdelegate claim_story(scope, agent, story_id), to: Assignment, as: :claim

  defdelegate assign_issue_to_working_copy(scope, issue_id, working_copy_id, opts \\ []),
    to: IssueAssignment,
    as: :assign

  defdelegate prioritize_issue(scope, working_copy_id, issue_id),
    to: IssueAssignment,
    as: :prioritize

  defdelegate assigned_issues(scope, working_copy_id), to: IssueAssignment, as: :bag

  defdelegate free_issue_team(scope, issue), to: IssueAssignment, as: :free
  defdelegate providers(), to: Providers, as: :names

  @doc """
  Mark the agent's open promotion task as awaiting the queue.

  Called by the MCP `promote` tool once `PromotionQueue` has answered `:queued`.
  Resolves the agent here so the tool needs no
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
      |> Enum.filter(&own_or_unattributed?(&1, story_id, component_id))
      |> Enum.map(&Map.from_struct/1)
    end)
  end

  # The component fallback takes only tasks with no story_id of their own: a
  # component shared by several stories would otherwise pull each sibling's
  # tasks into every other's cycle time.
  defp own_or_unattributed?(task, story_id, component_id) do
    task.story_id == story_id or
      (is_nil(task.story_id) and not is_nil(component_id) and task.component_id == component_id)
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
  Every app restart on a working copy no agent currently holds a story on —
  the project-level case.
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

  Derived on each call rather than read off the row, so a grant added to a role
  reaches agents already running.
  """
  @spec tools_of(Scope.t(), Agent.t()) :: [String.t()] | nil
  def tools_of(%Scope{} = scope, %Agent{} = agent),
    do: tools_for(scope, %{role: agent.role, working_copy_id: agent.working_copy_id})

  @doc """
  Starts an agent on a working copy, on the provider the caller named.

  The provider is an argument rather than ambient state, so two callers wanting
  different subscriptions never spend the wrong one.

  A stopped agent on the same copy and role that still holds unfinished tasks
  is restarted in place instead of a new row being created.
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
      # Credential and history ride on the struct, never stored on the row.
      # Hydrated after the conversation is opened: that is what the history is
      # read from.
      with {:ok, agent} <-
             launch(scope, LaunchRequest.hydrate(scope, %{agent | credential: credential})) do
        watch_over(scope, agent)
        broadcast(scope, {:agent_started, agent})
        {:ok, agent}
      end
    end
  end

  # A stopped agent still holding work is resumed, not replaced: task ownership
  # is which row's list a task sits in, and moving tasks would mint new ids and
  # orphan their blockers. Only for a holder, so a role can still get a fresh
  # start.
  # See knowledge/agents, "Starting and restarting".
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
  calling.

    * No working copy named, and the agent has one in the scope's project — the
      agent's copy, with its environment (`WorkingCopies.put_scope/2`), exactly
      as an `X-Harness-Id` would have set it.
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
  is alive on a harness, tracked by the channel of the copy it runs in.
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
  # would staff a role somebody turned off.
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

  The only way back from off. Start, restart and message never do
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

  Not off. Off keeps the seat and can be turned back on; retired is
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

  # Open tasks would keep their requirements claimed against the seat's next
  # agent. Closed as cancelled on the retired row, which keeps their history.
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

  # `machine_tools: []` is a machine that answered with nothing, and an agent
  # started there fails every call; refused. `nil` is a copy that has not joined
  # yet (provisioning staffs copies early) and is allowed.
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
  Clear what a restart left behind on each agent's row.

  Called when a harness asks what it should be running, which is the only
  moment this side sees a restart at all — the application going down is not an
  event the server observes.

  The conversation as recorded is what an agent resumes with. A stopped agent
  comes back stopped and is told nothing. One caught mid-turn comes back
  holding every call it made and every result it got, and carries on
  (`Mailbox.carry_on/2`) before anything queued for it is delivered.

  `turn_started_at` is cleared for the mid-turn case, as `restart_agent/2`
  clears it, so no reader reports a turn from a process that no longer exists.
  A turn handed to the old process and never started is abandoned.
  """
  @spec account_for_interrupted_turns(Scope.t(), [Agent.t()]) :: :ok
  def account_for_interrupted_turns(%Scope{} = scope, agents) when is_list(agents) do
    Enum.each(agents, &account_for_interrupted_turn(scope, &1))
  end

  # A turn handed to the harness that just died can never start; left open it
  # would fence the agent out of the join's one sweep.
  defp account_for_interrupted_turn(_scope, %Agent{turn_started_at: nil} = agent),
    do: Offers.abandon_turns(agent.id)

  defp account_for_interrupted_turn(scope, %Agent{} = agent) do
    AgentsRepository.update_agent(scope, agent, %{turn_started_at: nil})
    {:ok, _} = Mailbox.carry_on(scope, agent.id)
    :ok
  end

  # Starting a role that wakes on the cadence (main) starts the cadence and
  # clears a stand-down: it says the project is back at work. `resume/1` comes
  # first so the timer that comes up will deliver.
  # See knowledge/agents, "The cadence".
  defp watch_over(scope, %Agent{role: role}) do
    if RoleProfile.wakes_on?(role, :cadence) do
      MainAgent.resume(scope)
      MainAgent.ensure_cadence(scope)
    end

    :ok
  end

  @doc """
  Restart one agent's process in place — same id, same conversation.

  Not `start_agent/2` again: a new row is a new, empty thread. This re-runs
  only the launch half — fetch a credential, hydrate the existing history, ask
  the machine to run it — and recomputes the tool list, so a tool added since
  the agent started reaches it.

  The live process is stopped first (`halt_for_restart/1`), so a restart reaches
  an agent hung mid-turn rather than handing back the running process. A turn
  that was open carries on from the conversation as recorded
  (`Mailbox.carry_on/2`), before anything queued.

  A machine that could not be asked refuses the restart rather than reporting
  one it did not perform; "already not running" is a satisfied stop.

  See knowledge/agents, "Starting and restarting".
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
             # The turn the restart cut; nothing else would ever clear it.
             turn_started_at: nil,
             # A row that starts cleanly must not read as stopped for an old reason.
             stopped_reason: nil,
             tools: tools_of(scope, agent)
           }),
         :ok <- carry_on_if_mid_turn(scope, agent) do
      with {:ok, agent} <-
             launch(scope, LaunchRequest.hydrate(scope, %{starting | credential: credential})) do
        broadcast(scope, {:agent_started, agent})

        # Whether it takes a turn is `came_up/2`'s, once its process is up and
        # present: asked now, it is not present yet and would be held.

        {:ok, agent}
      end
    end
  end

  # Before the launch request is hydrated, so the carry-on is waiting in the
  # mailbox rather than in the history the agent comes back holding.
  defp carry_on_if_mid_turn(_scope, %Agent{turn_started_at: nil}), do: :ok

  defp carry_on_if_mid_turn(scope, agent) do
    {:ok, _} = Mailbox.carry_on(scope, agent.id)
    :ok
  end

  # Ask the machine to end it, whatever the row or Presence says, and fail on any
  # answer but stopped or `:not_running`. Not `end_process/2`, which ignores a
  # failed ask for an agent that is not present: a restart that launches beside
  # a surviving process collides and leaves the row stuck at `:starting`.
  defp halt_for_restart(%Agent{} = agent) do
    agent.working_copy_id
    |> Transport.impl().stop_agent(agent, @stop_timeout_ms)
    |> stopped?(agent)
  end

  @doc """
  Whether anything is actually connected for this agent's working copy right
  now — read from the live channel registry, never from `agent.status`, which
  nothing rewrites when a harness restart or a crashed machine takes the
  process.

  Not a per-agent liveness check: a connected copy can still have lost one
  agent's process. That is `present?/2`. If nothing is connected, no agent on
  the copy can be alive.
  """
  @spec working_copy_connected?(Agent.t()) :: boolean()
  def working_copy_connected?(%Agent{working_copy_id: id}) do
    match?({:ok, _pid, _instance}, HarnessRegistry.executor_holder(id))
  end

  # One agent per role per checkout. The main copy holds only the roles that
  # live there (`RoleProfile.lives_on_main_copy?/1`: main and product), one
  # each. `restart_agent/2` does not pass through here, so an agent is never
  # refused for counting as itself.
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
  # against it: callers routinely name no checkout (the MCP tool drops nil
  # keys), and the guard must judge the copy the agent will run on.
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

  # An id names a checkout unambiguously, so the root is derived from it. An id
  # this project does not own is refused rather than defaulted — unlike an
  # unknown root, which may be a checkout that has not joined yet.
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

  # The id comes from the named root, not the caller. Falls back to the
  # caller's own copy only when the root names nothing recognised (a checkout
  # that has never joined has no row), and says so (`warn_substitution/2`).
  defp id_for(%Scope{} = scope, root) do
    case WorkingCopies.by_root(scope, root) do
      %{id: id} ->
        id

      nil ->
        warn_substitution(scope, root)
        scope.active_working_copy_id
    end
  end

  # The stop decision and analyzer alerts are computed from this id, so an
  # agent recorded against the wrong copy is told about the wrong tree. The
  # substitution stands (relocating the agent would be worse) and is announced.
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

  # By id or by root: callers name a checkout both ways.
  defp names?(attrs, copy) do
    id = MapAccess.get(attrs, :working_copy_id)
    root = MapAccess.get(attrs, :working_copy)

    id == copy.id or (is_binary(root) and root != "" and Path.expand(root) == copy.root)
  end

  # One agent per role on the main copy, by id alone: root does not matter
  # there, the copy is the project's. A retired agent's seat is free even while
  # its stranded process runs.
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

  # Ask the machine to bring it up, and record what it reports. Best-effort: an
  # offline machine leaves the row `:starting` (asked for, unconfirmed) rather
  # than making the agent unstartable.
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

  # Answers `{:ok, agent}` at `:starting` on purpose: a row is intent, and the
  # machine reconciles to rows afterwards (`agents_to_restore`). Copies are
  # staffed before they join the harness, so refusing here would break staffing.
  defp keep_starting(agent, reason) do
    Logger.info(
      "[Agents] agent #{agent.id} was not started on its machine (#{inspect(reason)}); " <>
        "it stays :starting, which is what the page shows as asked-for and unconfirmed"
    )

    {:ok, agent}
  end

  # Opened as part of starting, so an agent is watchable before it speaks.
  # Keyed on the agent, not the working copy: a copy runs several agents, and a
  # per-copy key interleaved their turns into one transcript.
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

  Scopeless, and it is the only listing that is: someone debugging a stuck
  agent does not yet know which project it belongs to.

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

  The counterpart to `message_any_agent/3`. Off, like every deliberate stop.
  Behind the dev-only router scope that is compiled out of production.

  The project comes off the agent's row rather than from the caller, so the
  repository's `:cross_project` guard still applies.
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

  `restart_agent/2`, not a start: same row, same transcript. Account and
  project both come off the agent's row — the account is what the credential
  lookup needs.
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

  # Operator delivery waits for durable admission, not for the model's turn.
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

  Clears `continuous`, so the next stop does not wake an agent that was given
  permission to leave.
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

  The other half of `ask_user` for an agent we run: an agent waiting on a
  person is stopped and has nothing to poll `check_answer` with.

  No scope: the id comes off a row this application wrote from the asking
  connection (`question_requests.agent_id`, `permission_requests.agent_id`), so
  there is no tenant decision left to make.

  The message enters the durable mailbox and is recorded on the transcript
  before dispatch, whether or not delivery succeeds or `Wake` holds it.
  Admission returns without waiting for the model's reply. Failure is returned,
  never raised: this runs inside the person's answer submission.

  `event` is what `Wake` is asked about — `:own_reply` for the answer to
  something it asked of us, `:question_answered` for its question's answer.

  Options: `:timeout`, `:async`, and `:offer` — `{kind, subject}` to record the
  message as an offer (`Offers`).
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
             {:ok, {message, offered, admission}} <-
               record_admission(agent, conversation, text, ref, event, opts[:offer]) do
          agent
          |> dispatch_admitted(admission, timeout, message, offered, opts)
          |> dispatch_disposition()
        end
    end
  end

  defp dispatch_disposition({:ok, disposition, _message}), do: {:ok, disposition}
  defp dispatch_disposition(error), do: error

  defp dispatch_admitted(agent, :ok, timeout, message, offered, async: true) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      deliver_recorded(agent, :ok, timeout)
      |> record_dispatch_result(message, offered)
    end)

    {:ok, :queued, message}
  end

  defp dispatch_admitted(agent, admission, timeout, message, offered, opts) do
    if Keyword.get(opts, :async, false) and admission == :ok do
      dispatch_admitted(agent, admission, timeout, message, offered, async: true)
    else
      deliver_recorded(agent, admission, timeout)
      |> record_dispatch_result(message, offered)
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

  The on-duty `main` agent whose working copy is the project's main copy.
  `nil` when the project has no main working copy, or nothing on duty there;
  `ensure_main_agent/1` reports the two apart.
  """
  @spec main_agent(Scope.t()) :: Agent.t() | nil
  def main_agent(%Scope{} = scope) do
    case WorkingCopies.main(scope) do
      nil -> nil
      copy -> scope |> running_main_agents() |> Enum.find(&(&1.working_copy_id == copy.id))
    end
  end

  # Work an agent ignored to the end of its kind's ladder, or refused, is held
  # back from it and main is told once (`:offer_held_back`, which `Wake` lets
  # through to any main), so it can reassign, cancel or answer. Read as
  # "terminal rung, not yet reported" and stamped reported.
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

  # 43cdc022: an instruction's delivery failing settles its offer
  # `:undelivered`, same as a decline settles `:declined` -- but a decline is
  # already named to main (above) and a failed delivery was not, so an agent
  # that never saw the instruction and one that saw and ignored it read the
  # same from main's side. Named with the agent, the text and the failure
  # time; `mark_reported` makes this idempotent across the two call sites.
  defp tell_main_undelivered_instructions(scope, agent) do
    agent.id
    |> Offers.unreported_undelivered_instructions()
    |> Enum.sort_by(& &1.id)
    |> Enum.each(fn offer ->
      notify_main(
        scope,
        :teammate_stalled,
        "An operator instruction to the #{agent.role} agent #{agent.id} was never delivered " <>
          "(failed at #{offer.outcome_at}): #{instruction_offer_text(offer)}",
        offer: {:stalled, {"agent", agent.id}}
      )

      :ok = Offers.mark_reported(offer)
    end)
  end

  defp instruction_offer_text(%{messages: [%{message: %Conversations.Message{} = message} | _]}),
    do: Conversations.Message.text(message)

  defp instruction_offer_text(_offer), do: "(message text unavailable)"

  # A released task is named as this agent's task, so main can cancel or
  # reassign it rather than only reading its id.
  defp held_back_subject(_agent, %CodeMySpec.Agents.Offer{kind: :unblocked, subject_key: id}),
    do: "task `#{id}` on this agent"

  defp held_back_subject(_agent, %CodeMySpec.Agents.Offer{subject_type: "questions"}),
    do: "pending questions offered to this agent"

  defp held_back_subject(_agent, %CodeMySpec.Agents.Offer{subject_type: type, subject_key: nil}),
    do: "#{type} offered to this agent"

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
  An agent declining an offer, with its reason: `offer_id`, or its newest open
  offer when nil. The offer settles as declined, the work is held back from
  this agent, and main is told now (`:offer_held_back`), naming the reason.
  The offer is stamped reported, so the turn-end escalation
  (`tell_main_held_back/2`) does not repeat it.
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

      # This is the one report; the turn-end escalation skips reported offers.
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
      %Agent{} = main ->
        notify(scope, main, event, text, opts[:offer], opts[:instruction_offer])

      nil ->
        if opts[:instruction_offer],
          do: Offers.instruction_notice(opts[:instruction_offer], {:error, :main_unavailable})

        :ok
    end
  end

  @doc "Record a provisioning failure for its project's agent, including during startup."
  def notify_provisioning_failure(%Scope{} = scope, agent_id, text) when is_binary(text) do
    with {:ok, %Agent{role: :main} = agent} <- AgentsRepository.fetch_agent(scope, agent_id) do
      notify(scope, agent, :provisioning_failed, text, nil, nil)
    end
  end

  @doc """
  Tell `agent_id` that a promotion it queued landed. Authoritative, and must
  reach the agent eventually even if it is briefly unreachable right now.

  1d65a84e: every other delivery path here (`dispatch_message/4,5,6`, and
  `notify/6`'s own `admit_if_allowed/4`) holds, and silently drops, a
  message its agent cannot currently be woken for -- the one path a landed
  outcome was lost on, leaving the agent's `promote_issue`/`story_promoted`
  task stuck open with nothing to act on. This skips that gate and admits
  the message to the durable mailbox unconditionally first; an immediate
  delivery attempt is still made, best-effort, but a failed one leaves the
  entry queued for the agent's next pump (startup, reconnect, or
  `Mailbox.reconcile_pending/0`) rather than losing it.
  """
  @spec notify_landed(Scope.t(), Ecto.UUID.t() | nil, String.t()) :: :ok
  def notify_landed(_scope, nil, _text), do: :ok

  def notify_landed(%Scope{} = scope, agent_id, text) when is_binary(text) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         {:ok, conversation} <- open_conversation(scope, agent) do
      ref = Ecto.UUID.generate()

      {:ok, {message, offered}} =
        Repo.transaction(fn ->
          {:ok, message} = record_sent(conversation, text, ref, :queued, "promotion-notice")
          offered = record_offer({:ok, message}, agent, nil)
          Mailbox.admit(agent, message, :own_reply)
          {message, offered}
        end)

      Conversations.broadcast_new_message(conversation, message)
      Mailbox.publish(message)

      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        deliver_recorded(agent, :ok, @message_timeout_ms)
        |> record_dispatch_result(message, offered)
      end)

      :ok
    else
      _ -> :ok
    end
  end

  defp notify(scope, main, event, text, offer, instruction_offer) do
    ref = Ecto.UUID.generate()

    with {:ok, conversation} <- open_conversation(scope, main),
         {:ok, {message, offered, admission}} <-
           record_admission(main, conversation, text, ref, event, offer) do
      # The notice's own delivery decides whether main was told, not this send.
      if instruction_offer, do: Offers.instruction_notice(instruction_offer, {:ok, message})

      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        deliver_recorded(main, admission, @message_timeout_ms)
        |> record_dispatch_result(message, offered)
      end)
    else
      error ->
        if instruction_offer,
          do: Offers.instruction_notice(instruction_offer, {:error, error})
    end

    :ok
  end

  @doc """
  The project's on-duty `main` agents (not off, not retired), newest first,
  wherever they run. The one source every "find the main agent" reads.
  """
  @spec running_main_agents(Scope.t()) :: [Agent.t()]
  defdelegate running_main_agents(scope), to: AgentsRepository, as: :list_running_main

  @doc """
  The project's own agent, started if it does not exist yet.

  Opening a project asks for its agent, and asking is enough: a non-technical
  user should never have to supply a provider, checkout or role.

  The two failures are kept apart because their remedies differ.
  `:no_main_working_copy` means run `mix cms.new`, or designate one of the
  checkouts you have. `:not_connected` means connect a provider.

  Starting is best-effort underneath: a machine that is offline leaves the
  agent `:starting` (asked for, unconfirmed) rather than an error.
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
  # project shows it off rather than starting another.
  defp main_or_start(_scope, _copy, %Agent{} = off), do: {:ok, off}

  # Main comes up with the rest of the main copy's roster beside it (product).
  # Only when main itself is started, so opening a project whose main is
  # running starts nothing. Best-effort; an off product is left alone.
  defp main_or_start(scope, copy, nil) do
    with {:ok, main} <- start_main_agent(scope, copy) do
      ensure_copy_agents(scope, copy, RoleProfile.roles_where_home(:main) -- [:main])
      {:ok, main}
    end
  end

  @doc """
  The agents a working copy does its work with, started if they are not there
  yet.

  The roster belongs to the **copy**, not to the epic it was given, so this is
  idempotent by role: a copy that already has a coding agent gets no second
  one when it is given more work.

  The default roster is the copy's home roles (`home_roles/1`): coding and QA
  on a feature copy, main and product on the main copy.

  Best-effort per role, not all-or-nothing: the caller gets the agents
  started, the roles that failed with why, and the roles left off.
  """
  @spec ensure_copy_agents(Scope.t(), map()) ::
          %{started: [Agent.t()], failed: [{atom(), term()}], off: [Agent.t()]}
  def ensure_copy_agents(scope, copy, roles \\ nil)

  def ensure_copy_agents(%Scope{} = scope, %{id: copy_id, root: root} = copy, nil)
      when is_binary(copy_id) and is_binary(root) and root != "",
      do: ensure_copy_agents(scope, copy, home_roles(copy))

  def ensure_copy_agents(%Scope{} = scope, %{id: copy_id, root: root}, roles)
      when is_binary(copy_id) and is_binary(root) and root != "" do
    on_copy =
      scope |> AgentsRepository.list_agents() |> Enum.filter(&(&1.working_copy_id == copy_id))

    agents = Enum.reject(on_copy, &Agent.retired?/1)

    # A role somebody turned off is left alone and reported, not a failure; a
    # retired seat is empty and gets filled -- except main's (criterion 2213):
    # firing hires no replacement, so main's seat stays empty until a person
    # starts one directly.
    off = Enum.filter(agents, &(Agent.off?(&1) and &1.role in roles))
    off_roles = MapSet.new(off, & &1.role)

    # A role with an agent on duty is filled, whether or not its process is up
    # this moment: one being restored is not a vacancy to start a second into.
    filled = agents |> Enum.filter(&on_duty?/1) |> MapSet.new(& &1.role)

    filled =
      if Enum.any?(on_copy, &(&1.role == :main and Agent.retired?(&1))),
        do: MapSet.put(filled, :main),
        else: filled

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

  # A row with no root is not a checkout; staffing it would produce agents that
  # cannot run and a copy that looks staffed.
  def ensure_copy_agents(%Scope{}, _copy, _roles),
    do: %{started: [], failed: [{:copy, :no_checkout}], off: []}

  @doc """
  The roles a feature copy is staffed with when nobody says otherwise.

  Coding and QA — the two that build something. Main and product are the
  project's and live on the main copy.
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

  An off agent holds its seat; a retired one does not. Pass every
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

  For operator routes with no session. It has to run in the server's VM: the
  channel registry lives there, so staffing from a separate BEAM (a `mix run`
  script) writes rows that never reach a harness.

  The provider comes from the account owner's model settings, since the caller
  has no session.

  `roles` overrides the copy's home roles — e.g. one role on each of several
  copies.
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

  Switching on takes the first turn, as `set_copy_continuous/3` does.
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

  # The earliest member — the account's creator: the only stable answer when
  # several members have different model settings.
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

  Per copy, the unit somebody decides about; each agent keeps its own column so
  one role can later be stopped without the others. Stopped agents are left
  alone.

  Switching on also ensures the graph watcher and the main agent's cadence,
  asks the copy's harness to rescan, and offers the copy's agents a turn —
  nothing polls, so setting the flag alone would leave idle agents idle.
  Switching off sends nothing.
  """
  @spec set_copy_continuous(Scope.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def set_copy_continuous(%Scope{} = scope, copy_id, continuous?) do
    with {:ok, count} <- AgentsRepository.set_copy_continuous(scope, copy_id, continuous?) do
      if continuous? do
        # Started on demand rather than at boot: a project nobody works on needs
        # neither a watcher nor a cadence.
        GraphWatcher.ensure_watching(scope)
        MainAgent.ensure_cadence(scope)

        # An unscanned copy has an empty actionable set for every role (the
        # project chain gates on scan-time verdicts), and only the harness has
        # the files.
        # See knowledge/agents, "Continuous mode".
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

  # Whether the switch admitted a turn or found no work, so the operator can
  # tell the two apart from the reply.
  defp enabled_disposition(scope, agent) do
    case Work.request_turn_if_runnable(scope, agent, :continuous_enabled) do
      {:ok, ref} when is_binary(ref) -> :enabled_and_turn_requested
      _not_runnable -> :enabled_without_work
    end
  end

  # A copy whose machine is not connected cannot be asked; the switch still
  # stands and the copy scans when its harness returns. Logged so a copy that
  # never scans is findable.
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

  # An explicit setting wins, and its model is recorded on the row. Only the
  # unset case goes through `@provider_preference`.
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

  # The model `Defaults` names for the chosen provider, so the row says what it
  # runs; `nil` for a provider with no entry.
  defp default_main_model(provider) do
    Defaults.for_role(:main)
    |> Enum.find_value(fn {candidate, model} -> candidate == provider && model end)
  end

  # The first connected provider: flat-rate before metered, so an always-on
  # main agent does not bill per token by default. Disagrees with
  # `Defaults.for_role(:main)` on purpose for now.
  # See knowledge/agents, "Providers and models".
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

  Best-effort, as starting is: a copy whose harness is not connected leaves the
  row `:starting`. Product moves with it.
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

  # Product lives where main lives, so it moves with it.
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

  def dispatch_message(%Scope{} = scope, id, text, event, opts)
      when is_binary(text) and is_list(opts),
      do: dispatch_message(scope, id, text, event, @message_timeout_ms, opts)

  def dispatch_message(%Scope{} = scope, id, text, event, timeout) when is_binary(text),
    do: dispatch_message(scope, id, text, event, timeout, [])

  def dispatch_message(%Scope{} = scope, id, text, event, timeout, opts) when is_binary(text) do
    ref = Ecto.UUID.generate()
    subject = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <- wake(scope, agent, event),
         :ok <- within_turn_cap(scope, agent),
         {:ok, conversation} <- open_conversation(scope, agent),
         {:ok, {message, offered, admission}} <-
           record_admission(
             agent,
             conversation,
             text,
             ref,
             event,
             {:instruction, {"message", subject}},
             Keyword.get(opts, :sender_id, "operator"),
             Keyword.take(opts, [:send_now])
           ) do
      if Keyword.get(opts, :send_now), do: interrupt_if_busy(scope, agent.id)

      result =
        deliver_recorded(agent, admission, timeout)
        |> record_dispatch_result(message, offered)

      report_repeated_instruction(scope, agent, offered)
      result
    end
  end

  defp report_repeated_instruction(scope, agent, offered) do
    Offers.take_instruction_attention(offered, fn ->
      notify_main(
        scope,
        :teammate_stalled,
        "An operator repeated an instruction to agent #{agent.id}. " <>
          "Review Offer #{offered.id} and its delivery history. The message was submitted " <>
          "unchanged; it was not withheld. Pending delivery is not evidence of refusal.",
        offer: {:stalled, {"agent", agent.id}},
        instruction_offer: offered
      )
    end)

    :ok
  end

  # Commit message, offer and mailbox identity together, before any transport
  # work or acknowledgement. Held notifications remain visible as failed offers.
  defp record_admission(
         agent,
         conversation,
         text,
         ref,
         event,
         offer,
         sender_id \\ "operator",
         admit_opts \\ []
       ) do
    result =
      Repo.transaction(fn ->
        case record_sent(conversation, text, ref, :queued, sender_id) do
          {:ok, message} ->
            offered = record_offer({:ok, message}, agent, offer)

            {message, admission} = admit_if_allowed(agent, message, event, offered, admit_opts)

            {message, offered, admission}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {message, _, _}} ->
        Conversations.broadcast_new_message(conversation, message)
        Mailbox.publish(message)

      _ ->
        :ok
    end

    result
  end

  defp admit_if_allowed(agent, message, event, offered, admit_opts) do
    case Wake.allow_admission?(agent_scope(agent), agent, event) do
      :ok ->
        Mailbox.admit(agent, message, event, admit_opts)
        {message, :ok}

      hold ->
        :ok = Offers.undelivered(offered)
        {:ok, message} = Conversations.set_delivery(message, :failed, broadcast: false)
        {message, Wake.to_error(hold)}
    end
  end

  defp pump_mailbox(scope, agent_id) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn -> Mailbox.pump(scope, agent_id) end)

    :ok
  end

  defp deliver_recorded(agent, :ok, timeout),
    do: Mailbox.pump(agent_scope(agent), agent.id, timeout)

  defp deliver_recorded(_agent, error, _timeout), do: error

  defp record_dispatch_result({:ok, disposition}, message, _offered)
       when disposition in [:started, :queued] do
    current = Repo.get!(Conversations.Message, message.id)
    disposition = if current.delivery == :delivered, do: :started, else: :queued
    {:ok, disposition, current}
  end

  # A missing acknowledgement does not prove delivery or failure. Keep the
  # pending record so a later delivery event can establish what happened.
  defp record_dispatch_result({:error, :message_timed_out} = error, _message, _offered),
    do: error

  defp record_dispatch_result({:error, _reason} = error, message, offered) do
    case Repo.get_by(Mailbox.Entry, message_id: message.id) do
      nil ->
        Offers.undelivered(offered)
        Conversations.set_delivery(message, :failed)

      _admitted ->
        :ok
    end

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
  is paying for themselves — both numbers, so a limit can be seen coming.
  """
  @spec turn_allowance(Scope.t(), Agent.t()) ::
          {non_neg_integer(), pos_integer()} | :uncapped
  def turn_allowance(%Scope{} = scope, %Agent{} = agent) do
    # `provider` (whose subscription it spends), not the engine: asking about
    # the engine answers `:none` for every agent and the cap never binds.
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

  # Asked at dispatch, the one door a turn comes through, and per turn: the
  # visitor may connect their own provider mid-conversation and stop being capped.
  defp within_turn_cap(scope, agent) do
    case turn_allowance(scope, agent) do
      :uncapped -> :ok
      {used, cap} when used < cap -> :ok
      {_used, cap} -> {:error, {:turn_cap_reached, cap}}
    end
  end

  # What the visitor has said, not what the agent has answered.
  defp turns_used(scope, agent) do
    case open_conversation(scope, agent) do
      {:ok, conversation} -> Conversations.count_messages(conversation, :operator)
      _ -> 0
    end
  end

  # Started or queued, on the row, so the view need not infer it.
  defp record_sent(conversation, text, ref, disposition, sender_id) do
    Conversations.add_message(conversation, :operator, text, sender_id, [],
      delivery: delivery_of(disposition),
      delivery_ref: ref,
      broadcast: false
    )
  end

  defp delivery_of(:started), do: :delivered
  defp delivery_of(:queued), do: :pending

  @doc """
  Take back a message the agent has not picked up yet.

  Withdrawal and consumption lock the same database mailbox entry. A queued or
  claimed message can be withdrawn; a consumed message is already delivered.
  Historical messages without mailbox ownership cannot change delivery state.
  """
  @spec withdraw_message(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Conversations.Message.t()} | {:error, term()}
  def withdraw_message(%Scope{} = scope, id, ref) when is_binary(ref),
    do: Mailbox.withdraw(scope, id, ref)

  @doc """
  Send a message that is waiting for the turn to end now: it goes to the front
  of the queue, and a busy agent's turn is stopped so it is the next one. The
  agent keeps what it did up to its last completed tool call. A message the
  agent has already taken is refused as delivered.
  """
  @spec send_now(Scope.t(), Ecto.UUID.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def send_now(%Scope{} = scope, id, ref) when is_binary(ref) do
    with {:ok, _} = sent <- Mailbox.send_now(scope, id, ref) do
      interrupt_if_busy(scope, id)
      sent
    end
  end

  # Mid-turn is the row's `turn_started_at`. Idle, the message already starts
  # the next turn and there is nothing to stop.
  defp interrupt_if_busy(scope, id) do
    case AgentsRepository.fetch_agent(scope, id) do
      {:ok, %Agent{turn_started_at: %DateTime{}} = agent} ->
        Transport.interrupt_turn(agent.working_copy_id, agent)

      _idle_or_gone ->
        :ok
    end
  end

  @doc """
  Write one step an agent took to the conversation it belongs to.

  Written on arrival rather than at turn end, so a turn that fails has
  already left everything it did behind it. Here rather than in the channel so
  a spex can drive it.
  """
  @spec record_turn_event(Scope.t(), Ecto.UUID.t(), map(), keyword()) :: :ok
  def record_turn_event(scope, agent_id, event, opts \\ [])

  def record_turn_event(
        %Scope{} = scope,
        agent_id,
        %{"kind" => "mailbox_ready", "generation" => generation} = event,
        _opts
      ) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         true <- agent.working_copy_id == scope.active_working_copy_id,
         {:ok, _} <- Mailbox.ready(scope, agent_id, generation, event["ref"]) do
      broadcast_unreferenced_ready(scope, agent_id, agent, event)

      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        Mailbox.pump(scope, agent_id)
      end)
    end

    :ok
  end

  # A turn ending is not a step; nothing is written to the transcript. It is
  # the internal equivalent of a Stop hook: the orchestrator's moment to speak.
  # It starts no analysis — the decision reads problems runs already persisted.
  # `opts` reaches `StopDecision.deliver/3`.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "turn_ended"} = event, opts) do
    if current_terminal_event?(scope, agent_id, event),
      do: record_terminal_event(scope, agent_id, opts),
      else: :ok
  end

  # A turn beginning: on the row (`turn_started_at`, queryable "mid-response
  # now") and on the transcript (what the agent did).
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "turn_started"} = event, _opts) do
    # A duplicate start keeps the first timestamp: `Work.record_decline/3`
    # compares task completions against it.
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         {:ok, agent} <-
           AgentsRepository.update_agent(scope, agent, %{
             turn_started_at: agent.turn_started_at || DateTime.utc_now()
           }),
         _ = broadcast(scope, {:agent_turn, agent}),
         {:ok, conversation} <- open_conversation(scope, agent) do
      :ok = Offers.observe_instruction_turn(agent)
      tell_main_undelivered_instructions(scope, agent)
      write_turn_event(conversation, agent, event)
    else
      _ -> :ok
    end
  end

  # A turn cut off at the step limit: sent to the agent as a message (something
  # done *to* it, and the one channel it reads), never written as a step.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "turn_cut_off"} = event, _opts) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, agent} ->
        send_off_channel(agent, event["text"] || "")

      _ ->
        :ok
    end
  end

  # A process that died, as the harness saw it go. Said *to* the agent as an
  # operator line, never as a step: `RestartRepository` reads the agent
  # speaking as a restart that worked, which would defeat the restart limit.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "agent_died"} = event, _opts) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, agent} -> account_for_death(scope, agent, event["text"])
      _ -> :ok
    end
  end

  # A failed turn that was neither a provider refusal nor a timeout: said to
  # the agent with the request it failed on, once. A failure on the re-offer is
  # recorded and left, so a repeating failure cannot buy a turn per failure.
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
      # Not ours, or not found: dropped. A transcript under the wrong agent
      # reads as that agent's work.
      _ -> :ok
    end
  end

  defp broadcast_unreferenced_ready(scope, agent_id, agent, event) do
    if is_nil(event["ref"]) and not is_nil(agent.turn_started_at) do
      with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent_id),
           do: broadcast(scope, {:agent_turn, current})
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

  `Work.consider_project/2` is edge-triggered and an agent coming up is not
  one of its edges, so this is what makes it admissible again. Here rather
  than after the start, because a turn goes only to an agent that is present.

  An agent holding the task a restart interrupted is told to carry on
  (`Work.resume_held_task/2`, this agent only; a harness reconnect sweeps the
  copy separately). One holding nothing is offered work
  (`Work.request_turn_if_runnable/4`). Each decides admissibility itself.
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

  # Main is told when a teammate dies or is reaped, and `Wake` lets that
  # through past main's own open question. Main's own death has nobody to tell.
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

    # Trimmed: a re-sent notice with a leading space must not read as a new request.
    if is_binary(request) and String.starts_with?(String.trim_leading(request), @failed_turn) do
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

    What it did before it failed is above, and may have taken effect; check \
    before redoing any of it. The request was:

    #{request}

    Pick it back up.\
    """
  end

  # This runs in the harness channel, and sending to an agent is a call into
  # that same channel, which the transport refuses rather than deadlock.
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

  # A failed turn the provider refused, kept on the row as state. The
  # transcript still gets the text; the row is what `check_in` and `Work` read.
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

  defp current_terminal_event?(scope, agent_id, %{"generation" => generation, "ref" => ref})
       when is_binary(generation) and is_binary(ref) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, %{mailbox_generation: ^generation}} ->
        case Mailbox.finish(scope, agent_id, ref, generation) do
          {:ok, _} -> true
          # A coalescible work signal has no mailbox payload.
          {:error, :not_found} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp current_terminal_event?(_scope, _agent_id, _event), do: false

  defp record_terminal_event(scope, agent_id, opts) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, agent} ->
        # Cleared before the stop menu, so nothing read during it shows the
        # turn as running. Read first: `Work.record_decline/3` needs it.
        turn_started_at = agent.turn_started_at

        {:ok, agent} =
          AgentsRepository.update_agent(
            scope,
            agent,
            Map.merge(%{turn_started_at: nil}, refusal_outlived(agent, turn_started_at))
          )

        broadcast(scope, {:agent_turn, agent})

        # Before the stop menu, whose observation fires
        # `Work.consider_project/2`: afterwards would lose the race with the
        # wake it damps.
        {:ok, agent} = Work.record_decline(scope, agent, turn_started_at)

        # Settled before the stop menu, which may make new offers of its own.
        :ok = Offers.settle_turn(agent)
        tell_main_held_back(scope, agent)
        tell_main_undelivered_instructions(scope, agent)

        if Mailbox.pending?(agent.id) do
          pump_mailbox(scope, agent.id)
        else
          StopDecision.deliver(scope, agent, opts)
        end

      _ ->
        :ok
    end
  end

  # A compaction is not a step: it is what the agent resumes from, kept in its
  # own table so no renderer can show it as something the agent said.
  defp write_turn_event(conversation, _agent, %{"kind" => "compacted"} = event) do
    case Conversations.record_checkpoint(conversation, event["messages"] || [],
           turn: event["turn"]
         ) do
      {:ok, _checkpoint} ->
        :ok

      {:error, _changeset} ->
        # Costs only a longer resume; the transcript is untouched.
        Logger.info("[Agents] a compaction checkpoint for #{conversation.id} was not saved")
        :ok
    end
  end

  # A tool call is recorded as a call (`tool_calls`), not prose, so it renders
  # as a call block with its arguments and pairs with its result.
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

  # What every call returned, paired to it, failed or not. This is the
  # conversation a restart resumes from, and an agent that knows it made calls
  # and not what they returned cannot carry its turn on.
  defp write_turn_event(conversation, agent, %{"kind" => "tool_end", "tool" => tool})
       when is_map(tool) do
    failed? = is_binary(tool["error"]) and tool["error"] != ""

    Conversations.add_tool_result(
      conversation,
      tool["id"],
      tool["name"],
      tool["result"] || tool["error"] || "",
      failed?: failed?,
      agent_role: to_string(agent.role || :main)
    )

    :ok
  end

  # A step that said nothing is not a step: textless events arrive by the dozen
  # per turn, and empty rows read as an agent speaking and saying nothing.
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

  # Includes `%{"text" => nil}`: nothing reaching here carries text worth showing.
  defp write_turn_event(_conversation, _agent, _event), do: :ok

  defp write_step(conversation, agent, event) do
    Conversations.add_agent_message(
      conversation,
      # `role` is an `Ecto.Enum`; `agent_role` on a message is a string column.
      to_string(agent.role || :main),
      turn_event_kind(event),
      turn_event_text(event)
    )

    :ok
  end

  # What this agent wrote, as it writes it: a stop's in-process validators read
  # the files the stopping agent touched, and an agent under Alloy fires no
  # PostToolUse. Recorded on the call, not the result (a failed write often
  # still changed the file). Only `write` and `edit`: recording reads would
  # count every file it looked at as changed.
  @writing_tools ~w(write edit)

  defp record_edit(%Agent{id: agent_id}, %{"tool" => %{"name" => name, "path" => path}})
       when name in @writing_tools and is_binary(path) and path != "" do
    FileEdits.track_agent_edit(agent_id, path)
  end

  defp record_edit(_agent, _event), do: :ok

  # An unknown kind is still something the agent did, so it lands as a message.
  defp turn_event_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp turn_event_kind(_event), do: "step"

  defp turn_event_text(%{"text" => text}) when is_binary(text), do: text
  defp turn_event_text(event), do: inspect(event)

  @doc """
  Record what a harness reports it is actually running.

  The device's set is the authority: it is a projection of Presence on the
  lane topics, so an agent whose process died is absent without anybody having
  to notice. Reported agents with no row are adopted; listed agents the report
  omits are reaped (`stopped_reason: :reaped`) and main is told.
  """
  @spec record_reported(Scope.t(), [map()]) :: {:ok, [Agent.t()]}
  def record_reported(%Scope{} = scope, reported) when is_list(reported) do
    adopted = reported |> Enum.map(&adopt(scope, &1)) |> Enum.reject(&is_nil/1)
    Enum.each(adopted, &ensure_conversation(scope, &1))
    alive = MapSet.new(adopted, & &1.id)

    # Logged on both sides: a report never sent and one that reconciled to
    # nothing look identical from either side alone.
    Logger.info("[Agents] harness reported #{length(reported)} agent(s)")

    listed = AgentsRepository.list_reported_running(scope)

    running =
      listed
      |> Enum.map(&reap_if_absent(scope, &1, MapSet.member?(alive, &1.id)))
      |> Enum.filter(&(&1.status in [:starting, :running]))

    :ok = tell_main_reaped(scope, Enum.reject(listed, &MapSet.member?(alive, &1.id)))

    # A report is the only moment the server learns an agent went away, so
    # watching pages hear it now rather than on reload.
    broadcast(scope, {:agents_reported, running})

    {:ok, running}
  end

  @running_afresh %{
    status: :running,
    turn_started_at: nil,
    stopped_reason: nil
  }

  # A reported agent the server has no row for is adopted: the harness is the
  # authority on what runs, including lanes we did not start.
  #
  # Keyed on the working copy's id (the device says which it holds; reported
  # paths drift) and the role, compared as strings — `agents.role` is an
  # `Ecto.Enum` and the wire carries a string. A mismatch here inserts a new row
  # per report, and duplicates on a copy withhold work (`Work.withheld?/3`).
  defp adopt(%Scope{} = scope, report) when is_map(report) do
    adopt(scope, reported_copy_id(report), report)
  end

  # Both names, new one first: the wire's compatibility window.
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

  # A report naming no working copy is refused rather than guessed at.
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
    :ok = abandon_turns(agent)

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

  # A recorded process group id (with its boot id) wins over the single pid a
  # lane reports about itself; otherwise the report's pid is kept.
  defp recorded_group_or_reported(%Agent{os_pid: pid, os_boot_id: boot}, _report)
       when is_integer(pid) and is_binary(boot),
       do: pid

  defp recorded_group_or_reported(%Agent{} = agent, report),
    do: report["os_pid"] || agent.os_pid

  # The engine decides whether an agent has presence and can be talked to, so a
  # Claude Code report must not default to `:alloy`.
  defp engine(%{"engine" => "claude_code"}), do: :claude_code
  defp engine(_report), do: :alloy

  # A report naming no role is the copy's one lane, called "main".
  defp role(%{"role" => role}) when is_binary(role) and role != "", do: role
  defp role(_report), do: "main"

  # An adopted Alloy lane gets a transcript at once, as one we started does,
  # keyed on the agent.
  defp ensure_conversation(%Scope{} = scope, %Agent{engine: :alloy} = agent) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
    )
  end

  # A Claude Code agent gets none: there is no lane to route a reply to.
  defp ensure_conversation(_scope, _agent), do: :ok

  defp reap_if_absent(_scope, %Agent{} = agent, true), do: agent

  # Absent from a report the machine actually sent: the harness reports its own
  # registry, so the report is the check. No report is not a report of absence.
  defp reap_if_absent(scope, %Agent{} = agent, false) do
    {:ok, stopped} = record_stopped(scope, agent, :reaped)
    stopped
  end

  @doc """
  Turn one agent off, and only that one: record who and why, then end its
  process.

  Off is the only deliberate stop. It is intent, recorded before the process
  is asked to end, so an agent whose machine cannot be reached is still off:
  `Transport` delivers nothing to it and nothing restarts it until
  `turn_on_agent/2`. `by:` names who turned it off; `reason:` is optional.
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

  # The machine is always asked. An agent not present has no process to end, so
  # an unreachable machine does not fail the stop; a present agent's answer
  # stands.
  # See knowledge/agents, "Stopping".
  defp end_process(_scope, %Agent{} = agent) do
    result = Transport.impl().stop_agent(agent.working_copy_id, agent, @stop_timeout_ms)
    if present?(agent.project_id, agent), do: stopped?(result, agent), else: :ok
  end

  # Not running is stopped (idempotent); unreachable is not.
  defp stopped?(:ok, _agent), do: :ok
  defp stopped?({:error, :not_running}, _agent), do: :ok

  # Unreachable on a copy that no longer resolves (offboarded, scratch path) is
  # stopped: there is nowhere left to hold a process, and refusing would leave
  # the agent unstoppable and holding its seat.
  defp stopped?({:error, :harness_not_connected} = error, agent) do
    case WorkingCopies.fetch(agent.working_copy_id) do
      {:error, :not_found} -> :ok
      {:error, :invalid_id} -> :ok
      {:ok, _} -> error
    end
  end

  defp stopped?({:error, _reason} = error, _agent), do: error

  # Only after something confirmed the process is gone: until then `os_pid` and
  # `os_boot_id` are the way to reach it. Clears `turn_started_at` and abandons
  # turn requests, or a returning agent would be unadmittable. Tasks are not
  # touched — a claim is about work, not a process. `reason` tells a reap
  # (`:reaped`, a report stopped mentioning it) from a deliberate stop.
  defp record_stopped(scope, agent, reason) when reason in [:reaped, :stopped] do
    AgentsRepository.update_agent(scope, agent, %{
      status: :stopped,
      stopped_reason: reason,
      os_pid: nil,
      os_boot_id: nil,
      turn_started_at: nil
    })
    |> tap(fn _ -> abandon_turns(agent) end)
  end

  # The process the turn went to is gone, so nothing it was handed can still
  # start or finish there (`Offers.abandon_turns/2`).
  defp abandon_turns(%Agent{id: id, turn_started_at: started}),
    do: Offers.abandon_turns(id, not is_nil(started))

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  @doc """
  Records what the device reported back about an agent it was asked to start.

  The machine confirms the id it was asked to run, and that is the whole
  report: the id resolves through the harness's registry for exactly as long as
  the agent is alive. `:running` here means a machine said so.
  """
  @spec record_started(Scope.t(), Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, :cross_project | Ecto.Changeset.t()}
  def record_started(%Scope{} = scope, %Agent{} = agent, %{agent_id: _id}) do
    :ok = abandon_turns(agent)
    AgentsRepository.update_agent(scope, agent, @running_afresh)
  end

  @doc """
  Which provider and model an agent type launches on, and why.

  Their setting when there is one and it still names a provider they hold, and
  `Defaults.resolve/2` against what they do hold otherwise. Public because the
  settings screen shows what a type *would* do before anybody chooses.

  A setting naming a provider no longer connected falls back to the defaults
  rather than refusing; disconnecting does not delete settings, so the answer
  is always derived from what is connected now.
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
  answers the same question the launcher will ask.
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
    # Refused here: a stored provider the account cannot authenticate yields an
    # agent that fails on its first model call.
    if provider in connected_providers(scope),
      do: AgentsRepository.put_model_setting(scope, role, provider, model),
      else: {:error, :unknown_provider}
  end

  @doc """
  Let a type resolve from the defaults again.

  The counterpart to `put_model_setting/4`. The settings form posts every type
  at once, so one Save pins every type; this is how a pin is undone.
  """
  @spec clear_model_setting(Scope.t(), atom()) :: :ok
  defdelegate clear_model_setting(scope, role), to: AgentsRepository

  # The type an agent is being started as; an unknown one is refused, not defaulted.
  defp role_of(attrs) do
    case Map.get(attrs, :role, :main) do
      role when is_atom(role) ->
        known_role(role, role)

      role when is_binary(role) ->
        role |> Utils.safe_to_existing_atom(:__unknown__) |> known_role(role)
    end
  end

  # `asked` is carried so a refusal names what the caller sent, not the
  # `:__unknown__` sentinel.
  defp known_role(role, asked) do
    if role in Agent.roles(),
      do: {:ok, role},
      else: {:error, {:unknown_role, asked, Agent.roles()}}
  end

  # An explicit provider wins; otherwise `resolve_model/2` decides.
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

  # The role's grants, plus — for roles that browse — the tool names the copy's
  # machine reported on join (its browser's tools are whatever that box serves).
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
