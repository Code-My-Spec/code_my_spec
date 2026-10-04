defmodule CodeMySpec.Repo.Migrations.CreateIssueQaAttempts do
  use Ecto.Migration

  def change do
    create table(:issue_qa_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :scenarios, {:array, :map}, null: false
      add :issue_ids, {:array, :binary_id}, null: false
      add :agent_id, :string
      add :task_id, :string
      add :submitted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:issue_qa_attempts, [:issue_id])
  end
end
