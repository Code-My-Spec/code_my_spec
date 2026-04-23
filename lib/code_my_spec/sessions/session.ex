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
  alias CodeMySpec.Sessions.Task
  alias CodeMySpec.Users.User

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          type: SessionType.t() | nil,
          status: atom() | nil,
          external_conversation_id: String.t() | nil,
          component_module_name: String.t() | nil,
          state: map() | nil,
          continuous: boolean() | nil,
          tasks: [Task.t()],
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

    embeds_many :tasks, Task, on_replace: :delete

    belongs_to :project, Project, type: :binary_id
    belongs_to :account, Account, type: :binary_id
    belongs_to :user, User
    belongs_to :component, Component, type: :binary_id

    # Self-referential parent session (legacy, kept for compatibility)
    belongs_to :parent_session, __MODULE__,
      foreign_key: :session_id,
      type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a session."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session \\ %__MODULE__{}, attrs) do
    session
    |> cast(attrs, [
      :type,
      :status,
      :external_conversation_id,
      :component_module_name,
      :state,
      :continuous,
      :project_id,
      :account_id,
      :user_id,
      :component_id,
      :session_id
    ])
    |> cast_embed(:tasks, with: &Task.changeset/2)
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
end
