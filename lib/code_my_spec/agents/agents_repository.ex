defmodule CodeMySpec.Agents.AgentsRepository do
  @moduledoc """
  Queries over the agents CodeMySpec started, scoped to the active project.

  Every read is project-scoped. An agent names a working copy and a credential,
  and both are tenant property — on a shared host the whole point of the record
  is that one tenant's agent is not reachable from another's.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.ModelSetting
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @spec list_agents(Scope.t()) :: [Agent.t()]
  def list_agents(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  def list_agents(%Scope{}), do: []

  @doc """
  Every agent row on this machine, ignoring scope.

  The only listing here that does. `list_agents/1` answers what one project's
  operator may see; this answers what is running on this machine, which is what
  a person debugging a stuck agent needs before they know whose it is.

  Reached from `/dev/agents` only, and that route is compiled out of a release.
  """
  @spec list_every_agent(keyword()) :: [Agent.t()]
  def list_every_agent(opts \\ []) do
    Agent
    |> then(fn q ->
      case Keyword.get(opts, :project_id) do
        id when is_binary(id) and id != "" -> where(q, [a], a.project_id == ^id)
        _ -> q
      end
    end)
    |> then(fn q ->
      if Keyword.get(opts, :include_stopped, false),
        do: q,
        else: where(q, [a], a.status != :stopped)
    end)
    |> order_by([a], asc: a.role)
    |> Repo.all()
  end

  @doc """
  Set continuous mode on every live agent of one working copy.

  `update_all` rather than a changeset each: this is a mode being switched, not
  a revision of what any agent is, and three rows moving together is the act
  somebody performed. `updated_at` by hand because `update_all` does not touch
  timestamps.

  Stopped agents are excluded. A mode on a process that is gone records an
  intention nothing can act on, and the row would read as a running loop the
  next time somebody looked.
  """
  @spec set_copy_continuous(Scope.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, :no_project}
  def set_copy_continuous(%Scope{active_project_id: project_id}, copy_id, continuous?)
      when is_binary(project_id) and is_binary(copy_id) and is_boolean(continuous?) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Agent
      |> where(
        [a],
        a.working_copy_id == ^copy_id and a.project_id == ^project_id and a.status != :stopped
      )
      |> Repo.update_all(set: [continuous: continuous?, updated_at: now])

    {:ok, count}
  end

  def set_copy_continuous(%Scope{}, _copy_id, _continuous?), do: {:error, :no_project}

  @doc """
  A scope per project that has at least one agent in the loop.

  For `GraphWatcher.watch_active_projects/0` at boot. Scopeless because there is
  no caller to scope it to — this runs before anybody has asked for anything,
  and "which projects are being worked" is a fact about the whole install.

  Carries only what a graph computation needs: the project and its account. No
  user, because no user asked.
  """
  @spec continuous_project_scopes() :: [Scope.t()]
  def continuous_project_scopes do
    from(a in Agent,
      where: a.continuous == true and not is_nil(a.project_id),
      distinct: a.project_id,
      select: a.project_id
    )
    |> Repo.all()
    |> Enum.map(&Repo.get(CodeMySpec.Projects.Project, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn project ->
      %Scope{
        active_project: project,
        active_project_id: project.id,
        active_account_id: project.account_id
      }
    end)
  end

  @doc """
  Set continuous mode on one agent.

  The grain a person actually watches. `set_copy_continuous/3` moves a whole
  checkout, which is the right unit for staffing an epic, and the wrong one when
  somebody is looking at a single agent's conversation and wants *that* one to
  carry on — John: *"when I open the agent conversation for the agent, I should
  get a play button that lets me start the agent."*

  It is also the grain R6 already works at: a coding agent goes home when coding
  work runs out while product keeps going, so the roles were always allowed to
  differ and only the control was per copy.
  """
  @spec set_agent_continuous(Scope.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, Agent.t()} | {:error, term()}
  def set_agent_continuous(%Scope{} = scope, agent_id, continuous?)
      when is_binary(agent_id) and is_boolean(continuous?) do
    case fetch_agent(scope, agent_id) do
      {:ok, agent} -> update_agent(scope, agent, %{continuous: continuous?})
      error -> error
    end
  end

  @doc """
  The agents this project believes are running.

  Separate from `list_agents/1` because "what is running" and "what has ever
  run" are different questions and the first is the one an operator asks.
  """
  @spec list_running(Scope.t()) :: [Agent.t()]
  def list_running(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id and a.status in [:starting, :running])
    |> order_by([a], asc: a.working_copy, asc: a.role)
    |> Repo.all()
  end

  def list_running(%Scope{}), do: []

  @doc """
  Every agent a team-status display should show a row for.

  Display only — `list_running/1` stays the one answer to "is this actually
  running" (`main_agent/1`'s occupancy check, an orchestrator asking what it
  can assign work to). This is a different question: "what belongs in this
  slot right now", and a slot does not go empty the instant its agent stops.

  Everything running or starting, plus — for a `(working_copy_id, role)` with
  nothing running — its single most recently stopped agent. Bounded by
  construction to one row per slot: a slot's stopped agent is superseded the
  moment a new one starts there, so this never accumulates the way `stopping
  == deleting` would have to be false to answer John's report that the team
  panel loses a row — and everything it ever ran — the instant its one agent
  is stopped from its own conversation page.
  """
  @spec list_for_team_status(Scope.t()) :: [Agent.t()]
  def list_for_team_status(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    running =
      Agent
      |> where([a], a.project_id == ^project_id and a.status in [:starting, :running])
      |> Repo.all()

    filled_slots = MapSet.new(running, &{&1.working_copy_id, &1.role})

    latest_stopped_per_empty_slot =
      from(a in Agent,
        where: a.project_id == ^project_id and a.status == :stopped,
        distinct: [a.working_copy_id, a.role],
        order_by: [asc: a.working_copy_id, asc: a.role, desc: a.updated_at]
      )
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(filled_slots, {&1.working_copy_id, &1.role}))

    (running ++ latest_stopped_per_empty_slot)
    |> Enum.sort_by(&{&1.working_copy, &1.role})
  end

  def list_for_team_status(%Scope{}), do: []

  @spec fetch_agent(Scope.t(), Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def fetch_agent(%Scope{active_project_id: project_id}, id)
      when is_binary(project_id) and is_binary(id) do
    Agent
    |> where([a], a.project_id == ^project_id and a.id == ^id)
    |> Repo.one()
    |> wrap_agent()
  end

  def fetch_agent(%Scope{}, _id), do: {:error, :not_found}

  defp wrap_agent(nil), do: {:error, :not_found}
  defp wrap_agent(%Agent{} = agent), do: {:ok, agent}

  @spec create_agent(Scope.t(), map()) ::
          {:ok, Agent.t()}
          | {:error, :missing_active_project | :cross_project_working_copy | Ecto.Changeset.t()}
  def create_agent(%Scope{active_project_id: nil}, _attrs), do: {:error, :missing_active_project}

  def create_agent(%Scope{} = scope, attrs) do
    with :ok <- validate_own_working_copy(scope, attrs) do
      attrs =
        attrs
        |> Map.put(:project_id, scope.active_project_id)
        |> Map.put(:account_id, scope.active_account_id)

      %Agent{}
      |> Agent.changeset(attrs)
      |> Repo.insert()
    end
  end

  # `foreign_key_constraint(:working_copy_id)` on the changeset only proves the
  # id exists *somewhere* in working_copies — it says nothing about whose
  # project that row belongs to. `Agents.start_agent/2` already refuses an id
  # this project does not own before it gets here, but this is the only writer
  # of an agent row and that invariant deserves to hold for whatever calls it
  # next, not just the one call path that happens to check today. Issue
  # c0facd8e.
  defp validate_own_working_copy(%Scope{active_project_id: project_id}, attrs) do
    case Map.get(attrs, :working_copy_id) do
      id when is_binary(id) and id != "" ->
        case WorkingCopies.fetch(id) do
          {:ok, %{project_id: ^project_id}} -> :ok
          {:ok, %{}} -> {:error, :cross_project_working_copy}
          {:error, _} -> :ok
        end

      _ ->
        :ok
    end
  end

  @spec update_agent(Scope.t(), Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, :cross_project | Ecto.Changeset.t()}
  def update_agent(
        %Scope{active_project_id: project_id},
        %Agent{project_id: project_id} = agent,
        attrs
      ) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  def update_agent(%Scope{}, %Agent{}, _attrs), do: {:error, :cross_project}

  @doc """
  This person's setting for one agent type, or nil.

  User-scoped rather than project- or account-scoped, unlike everything above
  it. The row names a provider, and the credential for that provider lives on
  `integrations`, which is keyed by user — so an account-level answer is only
  true for whichever member connected the provider. Not project-scoped either:
  someone with twenty projects should not answer this twenty times.
  """
  @spec model_setting(Scope.t(), atom()) :: ModelSetting.t() | nil
  def model_setting(%Scope{user: %{id: user_id}}, role) do
    Repo.get_by(ModelSetting, user_id: user_id, role: role)
  end

  @doc "Every type this person has chosen for."
  @spec list_model_settings(Scope.t()) :: [ModelSetting.t()]
  def list_model_settings(%Scope{user: %{id: user_id}}) do
    Repo.all(from s in ModelSetting, where: s.user_id == ^user_id)
  end

  @doc "Point a type at a provider and model, replacing any previous choice."
  @spec put_model_setting(Scope.t(), atom(), String.t(), String.t() | nil) ::
          {:ok, ModelSetting.t()} | {:error, Ecto.Changeset.t()}
  def put_model_setting(%Scope{user: %{id: user_id}}, role, provider, model) do
    attrs = %{role: role, provider: provider, model: model, user_id: user_id}

    case Repo.get_by(ModelSetting, user_id: user_id, role: role) do
      nil -> %ModelSetting{}
      existing -> existing
    end
    |> ModelSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Forget a type's setting, so it resolves from the defaults again.

  The way back. Without it a row is one-way — a person who set a model once had
  no way to say "actually, whatever is sensible", and `ModelSetting`'s own
  moduledoc is about not being stuck with last year's cheap model.

  `:ok` when there was nothing to forget, because "leave it as the default" and
  "it already was" are the same instruction.
  """
  @spec clear_model_setting(Scope.t(), atom()) :: :ok
  def clear_model_setting(%Scope{user: %{id: user_id}}, role) do
    ModelSetting
    |> where([s], s.user_id == ^user_id and s.role == ^role)
    |> Repo.delete_all()

    :ok
  end
end
