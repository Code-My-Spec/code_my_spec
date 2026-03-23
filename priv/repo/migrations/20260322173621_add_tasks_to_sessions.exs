defmodule CodeMySpec.Repo.Migrations.AddTasksToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :tasks, {:array, :map}, default: []
      add :component_module_name, :string
    end

    # Make user_id nullable — local mode has no real user record
    drop constraint(:sessions, "sessions_user_id_fkey")

    alter table(:sessions) do
      modify :user_id, :bigint, null: true, from: {:bigint, null: false}
    end

    create index(:sessions, [:project_id, :status])
    create index(:sessions, [:external_conversation_id, :status])
  end
end
