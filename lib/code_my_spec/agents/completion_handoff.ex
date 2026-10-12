defmodule CodeMySpec.Agents.CompletionHandoff do
  @moduledoc "A reviewed artifact handoff whose delivery and acknowledgement are separate facts."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "completion_handoffs" do
    field(:project_id, :binary_id)
    field(:working_copy_id, :binary_id)
    field(:owner_agent_id, :binary_id)
    field(:assigned_by_agent_id, :binary_id)
    field(:task_id, :string)
    field(:identity, :string)
    field(:artifact_paths, {:array, :string})
    field(:reviewed_base, :string)
    field(:reviewed_diff, :string)
    field(:purpose, :string)
    field(:authorship, :string, default: "unknown")
    field(:next_action, :string)
    field(:artifact_sha, :string)
    field(:parent_commit, :string)
    field(:parent_gitlink, :string)
    field(:verification, :string)
    field(:status, Ecto.Enum, values: [:assigned, :completed, :acknowledged], default: :assigned)

    field(:delivery_state, Ecto.Enum,
      values: [:pending, :queued, :delivered, :failed, :unknown],
      default: :pending
    )

    field(:delivery_error, :string)
    field(:completed_at, :utc_datetime_usec)
    field(:acknowledged_at, :utc_datetime_usec)
    field(:acknowledged_by_agent_id, :binary_id)
    field(:acknowledgement, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [
      :project_id,
      :working_copy_id,
      :owner_agent_id,
      :assigned_by_agent_id,
      :task_id,
      :identity,
      :artifact_paths,
      :reviewed_base,
      :reviewed_diff,
      :purpose,
      :authorship,
      :next_action,
      :artifact_sha,
      :parent_commit,
      :parent_gitlink,
      :verification,
      :status,
      :delivery_state,
      :delivery_error,
      :completed_at,
      :acknowledged_at,
      :acknowledged_by_agent_id,
      :acknowledgement
    ])
    |> validate_required([
      :project_id,
      :working_copy_id,
      :owner_agent_id,
      :assigned_by_agent_id,
      :task_id,
      :identity,
      :artifact_paths,
      :reviewed_base,
      :reviewed_diff,
      :purpose,
      :next_action
    ])
    |> validate_length(:artifact_paths, min: 1)
    |> validate_format(:reviewed_base, ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/)
    |> validate_format(:artifact_sha, ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/)
    |> validate_format(:parent_commit, ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/)
    |> validate_format(:parent_gitlink, ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/)
    |> unique_constraint([:project_id, :identity])
  end
end
