defmodule CodeMySpec.Sessions.Session do
  @moduledoc """
  DB-backed schema representing a Claude Code session.

  One session per Claude conversation. Tasks (units of work tied to requirements)
  are tracked as `embeds_many` within the session record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Sessions.SessionType
  alias CodeMySpec.Sessions.Subagent
  alias CodeMySpec.Sessions.Task
  alias CodeMySpec.Users.User
  alias CodeMySpec.Utils.MapAccess

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          type: SessionType.t() | nil,
          status: atom() | nil,
          external_conversation_id: String.t() | nil,
          component_module_name: String.t() | nil,
          state: map() | nil,
          continuous: boolean() | nil,
          last_eval_feedback_hash: String.t() | nil,
          eval_feedback_count: integer() | nil,
          git_rewrite_at: DateTime.t() | nil,
          tasks: [Task.t()],
          subagents: [Subagent.t()],
          project_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          user_id: integer() | nil,
          component_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "sessions" do
    field :type, SessionType

    field :status, Ecto.Enum,
      values: [:active, :complete, :failed, :cancelled],
      default: :active

    field :external_conversation_id, :string
    field :component_module_name, :string
    field :state, :map, default: %{}
    field :continuous, :boolean, default: false
    field :last_eval_feedback_hash, :string
    field :eval_feedback_count, :integer, default: 0

    # When this session last ran a Bash command that can move `HEAD` or
    # rewrite the worktree without going through Write/Edit (rebase, pull,
    # merge, checkout, reset, cherry-pick, stash pop/apply). Read by
    # `Validation.narrow_to_attributed/4` — see f8af8bf2.
    field :git_rewrite_at, :utc_datetime_usec

    embeds_many :tasks, Task, on_replace: :delete
    embeds_many :subagents, Subagent, on_replace: :delete

    # Which working copy this session is running in. Nil outside a harness.
    field :working_copy_id, :binary_id

    belongs_to :project, Project, type: :binary_id
    belongs_to :account, Account, type: :binary_id
    belongs_to :user, User
    belongs_to :component, Component, type: :binary_id

    # Self-referential parent session (legacy, kept for compatibility)
    belongs_to :parent_session, __MODULE__,
      foreign_key: :session_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a session."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session \\ %__MODULE__{}, attrs) do
    session
    |> cast(attrs, [
      :type,
      :status,
      :external_conversation_id,
      :working_copy_id,
      :component_module_name,
      :state,
      :continuous,
      :last_eval_feedback_hash,
      :eval_feedback_count,
      :git_rewrite_at,
      :project_id,
      :account_id,
      :user_id,
      :component_id,
      :session_id
    ])
    |> cast_embed(:tasks, with: &Task.changeset/2)
    |> cast_embed(:subagents, with: &Subagent.changeset/2)
    |> validate_required([:status])
  end

  @doc "Changeset scoped to a user scope — sets project_id, account_id."
  @spec scoped_changeset(t(), map(), map()) :: Ecto.Changeset.t()
  def scoped_changeset(session \\ %__MODULE__{}, attrs, scope) do
    session
    |> changeset(attrs)
    |> put_change(:project_id, scope.active_project_id)
    |> put_change(:account_id, scope.active_account_id)
    |> maybe_put_user_id(scope)
    |> validate_required([:project_id])
  end

  defp maybe_put_user_id(changeset, scope) do
    case scope do
      %{user_id: uid} when is_integer(uid) and uid > 0 ->
        put_change(changeset, :user_id, uid)

      _ ->
        changeset
    end
  end

  @doc "Add a task to the session's embedded tasks list."
  @spec add_task(t(), map()) :: Ecto.Changeset.t()
  def add_task(%__MODULE__{} = session, task_attrs) do
    task_attrs = Map.put_new(task_attrs, :id, Ecto.UUID.generate())
    existing = session.tasks || []

    session
    |> change()
    |> put_embed(:tasks, existing ++ [task_attrs])
  end

  @doc "Update a specific task within the session by task ID."
  @spec update_task(t(), String.t(), map()) :: Ecto.Changeset.t()
  def update_task(%__MODULE__{} = session, task_id, updates) do
    updated_tasks =
      Enum.map(session.tasks || [], fn task ->
        if task.id == task_id do
          Map.merge(task, Map.new(updates))
        else
          task
        end
      end)

    session
    |> change()
    |> put_embed(:tasks, updated_tasks)
  end

  @doc "Find the currently active task (first with status :active)."
  @spec active_task(t()) :: Task.t() | nil
  def active_task(%__MODULE__{tasks: tasks}) do
    Enum.find(tasks || [], &(&1.status == :active))
  end

  @doc "Find a task by its ID."
  @spec find_task(t(), String.t()) :: Task.t() | nil
  def find_task(%__MODULE__{tasks: tasks}, task_id) do
    Enum.find(tasks || [], &(&1.id == task_id))
  end

  @doc "Find a task by its assigned agent ID."
  @spec find_task_by_agent(t(), String.t()) :: Task.t() | nil
  def find_task_by_agent(%__MODULE__{tasks: tasks}, agent_id) do
    Enum.find(tasks || [], &(&1.agent_id == agent_id))
  end

  @doc """
  Register (or refresh) a sub-agent on the session.

  Matches by `agent_id`. If an entry with the same `agent_id` exists, its
  `last_heartbeat_at` is advanced to the new value (the "re-register to
  outlive TTL" path from Rule 2). Otherwise appends a fresh registration.
  """
  @spec register_subagent(t(), map()) :: Ecto.Changeset.t()
  def register_subagent(%__MODULE__{} = session, attrs) do
    agent_id = MapAccess.get(attrs, :agent_id)
    existing = session.subagents || []

    updated =
      case Enum.find_index(existing, &(&1.agent_id == agent_id)) do
        nil ->
          existing ++ [Map.put_new(attrs, :id, Ecto.UUID.generate())]

        idx ->
          List.update_at(existing, idx, fn current ->
            current
            |> Map.from_struct()
            |> Map.merge(attrs)
          end)
      end

    session
    |> change()
    |> put_embed(:subagents, updated)
  end

  @doc """
  Refresh a registered sub-agent's evidence-of-life.

  Only refreshes; never registers. A tool call from an `agent_id` this session
  has no registration for is not evidence that a sub-agent started — it is
  evidence that something else is using that id — and inventing a registration
  from it would make the roster unfalsifiable.
  """
  @spec touch_subagent(t(), String.t()) :: Ecto.Changeset.t()
  def touch_subagent(%__MODULE__{} = session, agent_id) do
    existing = session.subagents || []

    updated =
      case Enum.find_index(existing, &(&1.agent_id == agent_id)) do
        nil ->
          existing

        idx ->
          List.update_at(existing, idx, fn current ->
            current
            |> Map.from_struct()
            |> Map.put(:last_heartbeat_at, DateTime.utc_now())
          end)
      end

    session
    |> change()
    |> put_embed(:subagents, updated)
  end

  @doc "Unregister a sub-agent by `agent_id`."
  @spec unregister_subagent(t(), String.t()) :: Ecto.Changeset.t()
  def unregister_subagent(%__MODULE__{} = session, agent_id) do
    remaining = Enum.reject(session.subagents || [], &(&1.agent_id == agent_id))

    session
    |> change()
    |> put_embed(:subagents, remaining)
  end

  @doc """
  Returns the currently-active sub-agents — those whose `last_heartbeat_at`
  is within `ttl_minutes` of the current time. TTL-expired entries are
  filtered out (lazy prune; the DB row is not mutated).
  """
  @spec active_subagents(t(), pos_integer()) :: [Subagent.t()]
  def active_subagents(%__MODULE__{subagents: subagents}, ttl_minutes)
      when is_integer(ttl_minutes) and ttl_minutes > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_minutes * 60, :second)

    (subagents || [])
    |> Enum.filter(&within_ttl?(&1, cutoff))
  end

  defp within_ttl?(%{last_heartbeat_at: nil}, _cutoff), do: false

  defp within_ttl?(%{last_heartbeat_at: at}, cutoff) do
    DateTime.compare(at, cutoff) != :lt
  end
end
