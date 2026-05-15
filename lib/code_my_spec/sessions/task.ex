defmodule CodeMySpec.Sessions.Task do
  @moduledoc """
  Embedded schema for tasks tracked within a session.

  Each task represents a unit of work the agent is performing — tied to a
  requirement and its satisfied_by agent task module. Tasks are embedded
  in the Session record as a JSONB array.

  Lifecycle: prepared → active → completed/failed/cancelled
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Sessions.SessionType

  @statuses [:prepared, :active, :completed, :failed, :cancelled]
  @validation_types [:automatic, :manual]
  @execution_types [:main_agent, :sub_agent]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: atom() | nil,
          session_type: SessionType.t() | nil,
          validation_type: :automatic | :manual | nil,
          execution_type: :main_agent | :sub_agent | nil,
          requirement_id: integer() | nil,
          requirement_name: String.t() | nil,
          component_id: String.t() | nil,
          component_module_name: String.t() | nil,
          story_id: integer() | nil,
          project_id: String.t() | nil,
          agent_id: String.t() | nil,
          expected_files: [String.t()],
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :id, :string
    field :status, Ecto.Enum, values: @statuses, default: :prepared
    field :session_type, SessionType
    field :validation_type, Ecto.Enum, values: @validation_types, default: :automatic
    field :execution_type, Ecto.Enum, values: @execution_types, default: :main_agent
    field :requirement_id, :integer
    field :requirement_name, :string
    field :component_id, :string
    field :component_module_name, :string
    field :story_id, :integer
    field :project_id, :string
    field :agent_id, :string
    field :expected_files, {:array, :string}, default: []
    # Microsecond resolution so a task's started_at lands strictly past
    # any file's mtime that was synced moments earlier in the same
    # request. Eliminates the need for `Process.sleep(1_100)` in spex
    # that want the pipeline to short-circuit on no-file-changes.
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
  end

  @doc "Changeset for creating or updating a task."
  def changeset(task \\ %__MODULE__{}, attrs) do
    task
    |> cast(attrs, [
      :id,
      :status,
      :session_type,
      :validation_type,
      :execution_type,
      :requirement_id,
      :requirement_name,
      :component_id,
      :component_module_name,
      :story_id,
      :project_id,
      :agent_id,
      :expected_files,
      :started_at,
      :completed_at
    ])
    |> validate_required([:id, :status])
    |> put_id_if_missing()
  end

  defp put_id_if_missing(changeset) do
    case fetch_field(changeset, :id) do
      {_source, nil} -> put_change(changeset, :id, Ecto.UUID.generate())
      :error -> put_change(changeset, :id, Ecto.UUID.generate())
      _ -> changeset
    end
  end
end
