defmodule CodeMySpecCli.Repo.Migrations.CreateQaAttempts do
  use Ecto.Migration

  def change do
    create table(:qa_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :scenarios, {:array, :map}, null: false
      add :issue_ids, {:array, :binary_id}, null: false
      add :agent_id, :string
      add :task_id, :string
      add :parent_attempt_id, references(:qa_attempts, type: :binary_id, on_delete: :nilify_all)
      add :submitted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:qa_attempts, [:story_id])
    create index(:qa_attempts, [:parent_attempt_id])
    create index(:qa_attempts, [:submitted_at])

    create table(:qa_invalidations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :qa_attempt_id, references(:qa_attempts, type: :binary_id, on_delete: :delete_all), null: false
      add :invalidated_by_user_id, references(:users, on_delete: :nilify_all)
      add :reason, :string, null: false
      add :invalidated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:qa_invalidations, [:qa_attempt_id])
  end
end
