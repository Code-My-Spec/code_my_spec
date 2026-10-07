defmodule CodeMySpec.Repo.Migrations.CompletionsWaitForMainAcknowledgement do
  use Ecto.Migration

  def change do
    create table(:completion_handoffs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:working_copy_id, references(:working_copies, type: :binary_id), null: false)
      add(:owner_agent_id, :binary_id, null: false)
      add(:assigned_by_agent_id, :binary_id, null: false)
      add(:task_id, :string, null: false)
      add(:identity, :string, null: false)
      add(:artifact_paths, {:array, :string}, null: false)
      add(:reviewed_base, :string, null: false)
      add(:reviewed_diff, :text, null: false)
      add(:purpose, :text, null: false)
      add(:authorship, :string, default: "unknown", null: false)
      add(:next_action, :text, null: false)
      add(:artifact_sha, :string)
      add(:parent_commit, :string)
      add(:parent_gitlink, :string)
      add(:verification, :text)
      add(:status, :string, default: "assigned", null: false)
      add(:delivery_state, :string, default: "pending", null: false)
      add(:delivery_error, :text)
      add(:completed_at, :utc_datetime_usec)
      add(:acknowledged_at, :utc_datetime_usec)
      add(:acknowledged_by_agent_id, :binary_id)
      add(:acknowledgement, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:completion_handoffs, [:project_id, :identity]))
    create(index(:completion_handoffs, [:project_id, :status]))
  end
end
