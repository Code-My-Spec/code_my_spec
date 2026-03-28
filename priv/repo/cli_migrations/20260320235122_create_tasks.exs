defmodule CodeMySpec.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :requirement_name, :string, null: false
      add :session_type, :string
      add :status, :string, null: false, default: "pending"
      add :completed_at, :utc_datetime
      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all)
      add :story_id, references(:stories, on_delete: :delete_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :requirement_id, references(:requirements, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tasks, [:component_id, :requirement_name],
      where: "component_id IS NOT NULL"
    )

    create unique_index(:tasks, [:project_id, :requirement_name],
      where: "project_id IS NOT NULL AND component_id IS NULL"
    )

    create index(:tasks, [:status])
    create index(:tasks, [:requirement_id])
    create index(:tasks, [:story_id])

    create table(:task_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :depends_on_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_dependencies, [:task_id, :depends_on_id])
    create index(:task_dependencies, [:depends_on_id])
  end
end
