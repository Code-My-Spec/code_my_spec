defmodule CodeMySpec.Repo.Migrations.CreateFiles do
  use Ecto.Migration

  def change do
    create table(:files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :text, null: false
      add :role, :string, null: false
      add :mtime, :utc_datetime
      add :size, :integer
      add :valid, :boolean
      add :validation_errors, :map

      add :component_id, references(:components, type: :binary_id, on_delete: :nilify_all)
      add :story_id, references(:stories, on_delete: :nilify_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:files, [:project_id, :path])
    create index(:files, [:component_id])
    create index(:files, [:story_id])
    create index(:files, [:role])
    create index(:files, [:valid])
  end
end
