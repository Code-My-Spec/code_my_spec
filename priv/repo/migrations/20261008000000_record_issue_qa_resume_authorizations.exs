defmodule CodeMySpec.Repo.Migrations.RecordIssueQaResumeAuthorizations do
  use Ecto.Migration

  def change do
    create table(:issue_qa_resumes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id), null: false)
      add(:issue_id, references(:issues, type: :binary_id), null: false)
      add(:attempt_id, references(:issue_qa_attempts, type: :binary_id), null: false)
      add(:working_copy_id, references(:working_copies, type: :binary_id), null: false)
      add(:coding_agent_id, references(:agents, type: :binary_id), null: false)
      add(:coding_task_id, :string, null: false)
      add(:authorized_by_agent_id, references(:agents, type: :binary_id), null: false)
      add(:candidate_sha, :string, null: false)
      add(:reason, :text, null: false)
      add(:authorized_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:issue_qa_resumes, [:attempt_id]))
    create(index(:issue_qa_resumes, [:project_id, :issue_id]))
  end
end
