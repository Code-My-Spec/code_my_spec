defmodule CodeMySpec.Agents.AgentsRepository do
  @moduledoc """
  Queries over the agents CodeMySpec started, scoped to the active project.

  Every read is project-scoped except `list_every_agent/1` and the boot-time
  scope listings: an agent names a working copy and a credential, both tenant
  property.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.ModelSetting
  alias CodeMySpec.Conversations
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

  @doc "The project's agent for a terminal session's own session id, or nil."
  @spec get_by_engine_session(Scope.t(), String.t()) :: Agent.t() | nil
  def get_by_engine_session(%Scope{active_project_id: project_id}, session_id)
      when is_binary(project_id) and is_binary(session_id) do
    Repo.get_by(Agent, project_id: project_id, engine_session_id: session_id)
  end

  def get_by_engine_session(%Scope{}, _session_id), do: nil

  @doc """
  The session id of the newest terminal agent on duty in a working copy, or nil:
  the join between a turn addressed to a copy and the conversation it belongs to.
  """
  @spec terminal_session_id_for(Ecto.UUID.t() | nil) :: String.t() | nil
  def terminal_session_id_for(nil), do: nil

  def terminal_session_id_for(working_copy_id) when is_binary(working_copy_id) do
    Agent
    |> where(
      [a],
      a.working_copy_id == ^working_copy_id and a.engine in ^Agent.terminal_engines() and
        not is_nil(a.engine_session_id) and is_nil(a.off_at) and is_nil(a.retired_at)
    )
    |> order_by([a], desc: a.inserted_at)
    |> limit(1)
    |> select([a], a.engine_session_id)
    |> Repo.one()
  end

  @recent_window_seconds 300

  @doc """
  The other terminal agents on duty in this project, touched within the last
  five minutes: who else is working here right now.
  """
  @spec concurrent_terminal_agents(Scope.t(), Agent.t()) :: [Agent.t()]
  def concurrent_terminal_agents(%Scope{active_project_id: project_id}, %Agent{id: id})
      when is_binary(project_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@recent_window_seconds, :second)

    Agent
    |> where(
      [a],
      a.project_id == ^project_id and a.engine in ^Agent.terminal_engines() and a.id != ^id and
        is_nil(a.off_at) and is_nil(a.retired_at) and a.updated_at > ^cutoff
    )
    |> Repo.all()
  end

  def concurrent_terminal_agents(_scope, _agent), do: []

  @doc """
  Every agent row on this machine, ignoring scope.

  For a person debugging a stuck agent before they know whose it is. Reached
  from `/dev/agents` only, which is compiled out of a release.
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
        else: where(q, [a], is_nil(a.off_at) and is_nil(a.retired_at))
    end)
    |> order_by([a], asc: a.role)
    |> Repo.all()
  end

  @doc """
  Set continuous mode on every live agent of one working copy.

  One `update_all` (the copy's rows move together); `updated_at` is set by hand
  because `update_all` does not touch timestamps. Off and retired agents are
  excluded: the row would read as a running loop nobody can act on.
  """
  @spec set_copy_continuous(Scope.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, :no_project}
  def set_copy_continuous(%Scope{active_project_id: project_id}, copy_id, continuous?)
      when is_binary(project_id) and is_binary(copy_id) and is_boolean(continuous?) do
    now = DateTime.utc_now()

    {count, _} =
      Agent
      |> where(
        [a],
        a.working_copy_id == ^copy_id and a.project_id == ^project_id and is_nil(a.off_at) and
          is_nil(a.retired_at)
      )
      |> Repo.update_all(set: [continuous: continuous?, updated_at: now])

    {:ok, count}
  end

  def set_copy_continuous(%Scope{}, _copy_id, _continuous?), do: {:error, :no_project}

  @doc """
  Point every live agent of one working copy at its current root.

  `working_copy` is a snapshot taken at start and sent verbatim by
  `LaunchRequest.for/2`, so it is where a restore reads the path from. When a
  rejoin corrects `working_copies.root`, this follows it; otherwise restore
  fails with `:working_copy_missing` against a checkout that is right there.
  Off and retired agents are excluded, as in `set_copy_continuous/3`.
  """
  @spec sync_working_copy_root(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_project}
  def sync_working_copy_root(%Scope{active_project_id: project_id}, copy_id, root)
      when is_binary(project_id) and is_binary(copy_id) and is_binary(root) do
    now = DateTime.utc_now()

    {count, _} =
      Agent
      |> where(
        [a],
        a.working_copy_id == ^copy_id and a.project_id == ^project_id and
          is_nil(a.off_at) and is_nil(a.retired_at) and a.working_copy != ^root
      )
      |> Repo.update_all(set: [working_copy: root, updated_at: now])

    {:ok, count}
  end

  def sync_working_copy_root(%Scope{}, _copy_id, _root), do: {:error, :no_project}

  @doc """
  A scope per project that has at least one agent in the loop.

  For `Agents.GraphWake.watch_active_projects/0` at boot, so scopeless. Each
  scope carries only the project and its account; no user asked.
  """
  @spec continuous_project_scopes() :: [Scope.t()]
  def continuous_project_scopes do
    from(a in Agent,
      where: a.continuous == true and not is_nil(a.project_id),
      distinct: true,
      select: a.project_id
    )
    |> project_scopes()
  end

  @doc """
  Projects with a `main` agent running, for the cadence to wake.

  Keyed on the agent the cadence wakes, not on continuous mode: a project with
  a `main` and no loops still needs looking in on, and one with loops and no
  `main` has nobody to deliver a digest to. On duty counts, whether or not its
  process is up this moment.
  """
  @spec main_agent_project_scopes() :: [Scope.t()]
  def main_agent_project_scopes do
    from(a in running_main(),
      where: not is_nil(a.project_id),
      distinct: true,
      select: a.project_id
    )
    |> project_scopes()
  end

  @doc """
  The project's running `main` agents, newest first.

  Every lookup of "the main agent" starts here — on the main copy, anywhere,
  or other than the asker — so they agree on what one is. By intent — on duty,
  not whether its process is up this moment — so the window while a harness
  restores its agents never reads as "no main" and starts a second one.
  Delivery to it still waits for its process (`Wake`).
  """
  @spec list_running_main(Scope.t()) :: [Agent.t()]
  def list_running_main(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    from(a in running_main(), where: a.project_id == ^project_id, order_by: [desc: a.inserted_at])
    |> Repo.all()
  end

  def list_running_main(%Scope{}), do: []

  defp running_main,
    do: from(a in Agent, where: a.role == :main and is_nil(a.off_at) and is_nil(a.retired_at))

  defp project_scopes(query) do
    query
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

  The grain a person watches from one agent's conversation;
  `set_copy_continuous/3` moves a whole checkout.
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
  The project's agents with these ids, in the order a listing shows them —
  the rows for agents `Agents.Presence` says are alive.
  """
  @spec list_by_ids(Scope.t(), [Ecto.UUID.t()]) :: [Agent.t()]
  def list_by_ids(%Scope{active_project_id: project_id}, ids)
      when is_binary(project_id) and is_list(ids) do
    Agent
    |> where([a], a.project_id == ^project_id and a.id in ^ids)
    |> order_by([a], asc: a.working_copy, asc: a.role)
    |> Repo.all()
  end

  def list_by_ids(%Scope{}, _ids), do: []

  @doc """
  The agents whose rows say they are running — the external lane report's own
  view (`Agents.record_reported/2`): an agent with no process on a harness,
  only a report, is running while reported. Alloy agents are read from
  `Agents.Presence`, not from here.
  """
  @spec list_reported_running(Scope.t()) :: [Agent.t()]
  def list_reported_running(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id and a.status in [:starting, :running])
    |> order_by([a], asc: a.working_copy, asc: a.role)
    |> Repo.all()
  end

  def list_reported_running(%Scope{}), do: []

  @doc """
  The agents meant to be running: neither off nor retired, whether or not
  their processes are up this moment.

  What to restore on a harness join and what the main agent reports as working.
  """
  @spec list_on_duty(Scope.t()) :: [Agent.t()]
  def list_on_duty(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id and is_nil(a.off_at) and is_nil(a.retired_at))
    |> order_by([a], asc: a.working_copy, asc: a.role)
    |> Repo.all()
  end

  def list_on_duty(%Scope{}), do: []

  @doc "The agent, fresh from the row, if it is off or retired; nil otherwise."
  @spec get_stood_down(Ecto.UUID.t()) :: Agent.t() | nil
  def get_stood_down(agent_id) when is_binary(agent_id) do
    Agent
    |> where([a], a.id == ^agent_id and (not is_nil(a.off_at) or not is_nil(a.retired_at)))
    |> Repo.one()
  end

  @doc """
  Every agent a team-status display should show a row for.

  Display only. This is "what belongs in this slot right now", and a slot does
  not go empty the instant its agent is turned off.

  Every agent on duty, plus — for a `(working_copy_id, role)` with nobody on
  duty — its single most recently turned-off agent, so a slot does not vanish
  from the panel when its agent is stopped. Agents without a working copy
  have no slot to preserve: only those starting or running belong here.
  Off, retired, or stopped orphan records must not appear as onboarding agents.
  """
  @spec list_for_team_status(Scope.t()) :: [Agent.t()]
  def list_for_team_status(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    running =
      Agent
      |> where([a], a.project_id == ^project_id and is_nil(a.off_at) and is_nil(a.retired_at))
      |> where([a], not is_nil(a.working_copy_id) or a.status in [:starting, :running])
      |> Repo.all()

    filled_slots = MapSet.new(running, &{&1.working_copy_id, &1.role})

    # A retired agent gave up its seat, so its slot shows empty.
    latest_stopped_per_empty_slot =
      from(a in Agent,
        where:
          a.project_id == ^project_id and not is_nil(a.off_at) and is_nil(a.retired_at) and
            not is_nil(a.working_copy_id),
        order_by: [desc: a.updated_at]
      )
      |> Repo.all()
      |> Enum.uniq_by(&{&1.working_copy_id, &1.role})
      |> Enum.reject(&MapSet.member?(filled_slots, {&1.working_copy_id, &1.role}))

    (running ++ latest_stopped_per_empty_slot)
    |> Enum.sort_by(&{&1.working_copy, &1.role})
  end

  def list_for_team_status(%Scope{}), do: []

  @doc """
  One agent on this project, or `{:error, :not_found}`.

  An id that is not a uuid (a truncated id, a sub-agent label) is not found
  rather than raising: surfaces print ids truncated, and an agent handed a
  database error concludes its tooling is broken.

  An agent conversation's id also resolves to its agent (the cockpit URL
  carries `?conversation=<id>`), within the same scope.
  """
  @spec fetch_agent(Scope.t(), Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def fetch_agent(%Scope{active_project_id: project_id} = scope, id)
      when is_binary(project_id) and is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case get_in_project(project_id, uuid) || agent_of_conversation(scope, uuid) do
          nil -> {:error, :not_found}
          %Agent{} = agent -> {:ok, agent}
        end

      :error ->
        case resolve_short_id(project_id, id) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :not_found}
        end
    end
  end

  def fetch_agent(%Scope{}, _id), do: {:error, :not_found}

  defp get_in_project(project_id, id) do
    Agent
    |> where([a], a.project_id == ^project_id and a.id == ^id)
    |> Repo.one()
  end

  # A team assignment names a teammate by the same short id this project uses
  # everywhere else (issues, commits) -- never the full UUID, which whoever
  # reads the assignment has no reason to have memorized. Ecto.UUID.cast/1
  # always refuses that, so without this every short id read as "no agent or
  # conversation with that id exists here" even when it names exactly one
  # (98d45f5c).
  #
  # Hex-only and length-bounded on purpose: a sub-agent label (`aqa-1013-...`)
  # is meant to fall through unmatched here, per this module's own moduledoc,
  # not get coerced into a prefix search it could spuriously match.
  @short_id ~r/^[0-9a-f]{4,35}$/i

  defp resolve_short_id(project_id, id) do
    if Regex.match?(@short_id, id) do
      Agent
      |> where([a], a.project_id == ^project_id)
      |> where([a], like(type(a.id, :string), ^(id <> "%")))
      |> Repo.all()
      |> case do
        [agent] -> agent
        _ -> nil
      end
    end
  end

  defp agent_of_conversation(scope, conversation_id) do
    case Conversations.get_agent_conversation_by_id(scope, conversation_id) do
      %{agent_id: agent_id} when is_binary(agent_id) ->
        get_in_project(scope.active_project_id, agent_id)

      _ ->
        nil
    end
  end

  @spec create_agent(Scope.t(), map()) ::
          {:ok, Agent.t()}
          | {:error, :missing_active_project | :cross_project_working_copy | Ecto.Changeset.t()}
  def create_agent(%Scope{active_project_id: nil}, _attrs), do: {:error, :missing_active_project}

  def create_agent(%Scope{} = scope, attrs) do
    with :ok <- validate_own_working_copy(scope, attrs) do
      # A member joining a copy takes its team's story and epic.
      attrs =
        attrs
        |> Map.put(:project_id, scope.active_project_id)
        |> Map.put(:account_id, scope.active_account_id)
        |> Assignment.inherit()

      %Agent{}
      |> Agent.changeset(attrs)
      |> Repo.insert()
    end
  end

  # The FK only proves the copy exists somewhere; this is the only writer of an
  # agent row, so the same-project invariant is held here for every caller.
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

  User-scoped, unlike everything above: the row names a provider, and that
  provider's credential lives on `integrations`, keyed by user.
  """
  @spec model_setting(Scope.t(), atom()) :: ModelSetting.t() | nil
  def model_setting(%Scope{user: %{id: user_id}}, role) do
    Repo.get_by(ModelSetting, user_id: user_id, role: role)
  end

  @doc "Every type this person has chosen for."
  @spec list_model_settings(Scope.t()) :: [ModelSetting.t()]
  def list_model_settings(%Scope{user: %{id: user_id}}) do
    Repo.all(from(s in ModelSetting, where: s.user_id == ^user_id))
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

  `:ok` when there was nothing to forget.
  """
  @spec clear_model_setting(Scope.t(), atom()) :: :ok
  def clear_model_setting(%Scope{user: %{id: user_id}}, role) do
    ModelSetting
    |> where([s], s.user_id == ^user_id and s.role == ^role)
    |> Repo.delete_all()

    :ok
  end
end
