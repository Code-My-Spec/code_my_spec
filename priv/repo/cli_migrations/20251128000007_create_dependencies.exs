defmodule CodeMySpec.Repo.Migrations.CreateDependencies do
  use Ecto.Migration

  def change do
    create table(:dependencies) do
      add :source_component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:dependencies, [:source_component_id])
    create index(:dependencies, [:target_component_id])
    create unique_index(:dependencies, [:source_component_id, :target_component_id])
  end
end
