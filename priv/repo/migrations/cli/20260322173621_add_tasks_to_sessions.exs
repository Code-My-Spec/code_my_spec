defmodule CodeMySpec.Repo.Migrations.AddTasksToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :tasks, :text, default: "[]"
      add :component_module_name, :string
      add :priority, :integer
    end

    create index(:sessions, [:project_id, :status])
    create index(:sessions, [:external_conversation_id, :status])
  end
end
